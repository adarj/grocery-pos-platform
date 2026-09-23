#lang racket

(require (prefix-in db: db)
         racket/file
         rackunit
         "../pos/application/authentication-service.rkt"
         "../pos/application/transaction-command-receipt.rkt"
         "../pos/application/transaction-command.rkt"
         "../pos/application/transaction-service.rkt"
         "../pos/domain/fake-catalog.rkt"
         "../pos/domain/money.rkt"
         "../pos/domain/register-operations.rkt"
         "../pos/domain/transaction-command-actor-attribution.rkt"
         "../pos/domain/transaction-void-approval.rkt"
         "../pos/domain/transaction-event.rkt"
         "../pos/persistence/pos-database-migrations.rkt"
         "../pos/persistence/sqlite-connection.rkt"
         "../pos/persistence/sqlite-register-operations.rkt"
         "../pos/persistence/sqlite-transaction-event-store.rkt"
         "../pos/persistence/transaction-command-actor-attribution-store.rkt"
         "../pos/persistence/transaction-command-unit-of-work.rkt"
         "../pos/persistence/transaction-void-approval-store.rkt"
         "../pos/security/transaction-void-approval.rkt")

(define alice (authenticated-operator "Alice" "Alice" 'cashier))
(define alice-as-manager (authenticated-operator "Alice" "Alice" 'manager))
(define bob (authenticated-operator "Bob" "Bob" 'cashier))
(define sam (authenticated-operator "Sam" "Sam" 'supervisor))
(define morgan (authenticated-operator "Morgan" "Morgan" 'manager))
(define approval-token
  (string-append "gpos_a1_" (make-string 64 #\a)))
(define approval-capability
  (transaction-void-approval-token->capability approval-token))

(define (insert-approval! connection command)
  (db:call-with-transaction
   connection
   (lambda ()
     (replace-transaction-void-approval-grant!/in-transaction!
      connection
      (transaction-void-approval-grant
       "approval-test"
       (transaction-void-approval-capability-token-digest approval-capability)
       "instance-test"
       "Alice"
       "Sam"
       1
       (transaction-command-command-id command)
       (transaction-command-transaction-id command)
       1
       (transaction-command-expected-version command)
       1000
       91000
       591000)
      "instance-test"
      1000))
   #:option 'immediate))

(define (call-with-service proc
                           #:commit-command!
                           [commit-command! commit-transaction-command-outcome!]
                           #:database-path [database-path #f]
                           #:approval-now [approval-now (lambda () 2000)])
  (define connection
    (if database-path
        (open-pos-sqlite-connection database-path 'create)
        (db:sqlite3-connect #:database 'memory)))
  (dynamic-wind
    (lambda ()
      (db:query-exec connection "PRAGMA foreign_keys = ON")
      (migrate-pos-database! connection)
      (db:query-exec
       connection
       "INSERT INTO register_configuration VALUES (1, 'register-1', 'Register 1')")
      (db:query-exec
       connection
       "INSERT INTO cashiers VALUES ('Alice', 'Alice', 1), ('Bob', 'Bob', 1), ('Sam', 'Sam', 1), ('Morgan', 'Morgan', 1)")
      (for ([operator (in-list '("Alice" "Bob" "Sam" "Morgan"))]
            [role (in-list '("cashier" "cashier" "supervisor" "manager"))])
        (db:query-exec connection "INSERT INTO operators VALUES (?, ?, 1)"
                       operator operator)
        (db:query-exec connection "INSERT INTO operator_roles VALUES (?, ?)"
                       operator role)
        (db:query-exec
         connection
         "INSERT INTO operator_pin_credentials VALUES (?, '$argon2id$v=19$m=19456,t=2,p=1$c2FsdA$aGFzaA', 1)"
         operator))
      (check-pred
       register-shift-opened?
       (open-register-shift!
        connection "Alice" (money 1000) (lambda () 1000)
        (lambda () "shift-alice"))))
    (lambda ()
      (proc connection
            (make-transaction-service
             connection
             #:catalog-lookup fake-catalog-lookup
             #:commit-command! commit-command!
             #:approval-consumer
             (lambda (approval-connection capability requester command)
               (consume-transaction-void-approval!/in-transaction!
                approval-connection capability "instance-test" requester
                command (approval-now)))
             #:current-epoch-ms (lambda () 2000))))
    (lambda () (db:disconnect connection))))

(define (resolved? result)
  (transaction-service-command-resolved? result))

(module+ test
  (test-case "fresh commands require the active shift owner for every role"
    (call-with-service
     (lambda (connection service)
       (define start
         (start-transaction-command "cmd-alice-start" "txn-alice" 0))
       (check-true (resolved? (transaction-service-execute-command service alice start)))
       (for ([principal (in-list (list bob sam morgan))]
             [command-id (in-list '("cmd-bob" "cmd-sam" "cmd-morgan"))])
         (check-pred
          transaction-service-authorization-denied?
          (transaction-service-execute-command
           service principal
           (scan-barcode-command command-id "txn-alice" 1 "049000001234"))))
       (check-equal?
        (db:query-value
         connection
         "SELECT COUNT(*) FROM transaction_command_receipts WHERE command_id IN ('cmd-bob', 'cmd-sam', 'cmd-morgan')")
        0))))

  (test-case "reads use durable ownership while supervisor and manager have read-any"
    (call-with-service
     (lambda (_connection service)
       (check-true
        (resolved?
         (transaction-service-execute-command
          service alice
          (start-transaction-command "cmd-read-start" "txn-read" 0))))
       (check-pred transaction-service-success?
                   (transaction-service-load-transaction service alice "txn-read"))
       (check-pred transaction-service-not-found?
                   (transaction-service-load-transaction service bob "txn-read"))
       (check-pred transaction-service-success?
                   (transaction-service-load-transaction service sam "txn-read"))
       (check-pred transaction-service-success?
                   (transaction-service-load-transaction service morgan "txn-read")))))

  (test-case "a contextless historical transaction has no provable cashier owner"
    (call-with-service
     (lambda (connection service)
       (check-pred
        journal-append-succeeded?
        (append-transaction-events!
         connection
         "txn-historical"
         0
         (list (transaction-started "txn-historical"))))
       (check-pred
        transaction-service-not-found?
        (transaction-service-load-transaction service alice "txn-historical"))
       (check-pred
        transaction-service-success?
        (transaction-service-load-transaction service sam "txn-historical"))
       (check-pred
        transaction-service-success?
        (transaction-service-load-transaction service morgan "txn-historical")))))

  (test-case "fresh whole-sale void requires scoped approval and retry does not"
    (call-with-service
     (lambda (connection service)
       (check-true
        (resolved?
         (transaction-service-execute-command
          service
          alice
          (start-transaction-command "cmd-own-void-start" "txn-own-void" 0))))
       (define command
         (void-transaction-command "cmd-own-void" "txn-own-void" 1))
       (check-pred
        transaction-service-approval-required?
        (transaction-service-execute-command service alice command))
       (check-equal?
        (db:query-value
         connection
         "SELECT COUNT(*) FROM transaction_command_receipts WHERE command_id = 'cmd-own-void'")
        0)
       (insert-approval! connection command)
       (check-true
        (resolved?
         (transaction-service-execute-command
          service alice command #:approval-capability approval-capability)))
       ;; The consumed capability is intentionally unnecessary for an exact
       ;; same-requester durable retry.
       (check-true
        (resolved?
         (transaction-service-execute-command service alice command)))
       (check-equal?
        (db:query-value
         connection
         "SELECT outcome_code FROM transaction_command_receipts WHERE command_id = 'cmd-own-void'")
        "accepted")
       (check-equal?
        (db:query-value
         connection
         "SELECT approver_operator_id FROM transaction_command_approver_attributions WHERE command_id = 'cmd-own-void'")
        "Sam"))))

  (test-case "approval expiry and security revocation are checked after the writer wait"
    (for ([scenario (in-list
                     '(expired approver-disabled approver-demoted
                               approver-revision requester-disabled))])
      (define directory (make-temporary-file "void-writer-race-~a" 'directory))
      (define database-path (build-path directory "pos.db"))
      (define monotonic-now (box 2000))
      (define reached-commit (make-channel))
      (dynamic-wind
        void
        (lambda ()
          (call-with-service
           (lambda (connection service)
             (check-pred
              transaction-service-command-resolved?
              (transaction-service-execute-command
               service alice
               (start-transaction-command "cmd-wait-start" "txn-wait" 0)))
             (define command
               (void-transaction-command "cmd-wait-void" "txn-wait" 1))
             (insert-approval! connection command)
             (define blocker
               (open-pos-sqlite-connection database-path 'read/write))
             (dynamic-wind
               void
               (lambda ()
                 (define result (box #f))
                 (define worker #f)
                 (db:call-with-transaction
                  blocker
                  (lambda ()
                    ;; The worker reaches the canonical Unit of Work while
                    ;; this other connection owns the SQLite writer slot.
                    (set! worker
                          (thread
                           (lambda ()
                             (set-box!
                              result
                              (with-handlers ([exn:fail? values])
                                (transaction-service-execute-command
                                 service alice command
                                 #:approval-capability approval-capability))))))
                    (channel-get reached-commit)
                    (check-false (sync/timeout 0 worker))
                    (case scenario
                      [(expired) (set-box! monotonic-now 91000)]
                      [(approver-disabled)
                       (db:query-exec blocker
                                      "UPDATE operators SET active = 0 WHERE operator_id = 'Sam'")]
                      [(approver-demoted)
                       (db:query-exec blocker
                                      "UPDATE operator_roles SET role = 'cashier' WHERE operator_id = 'Sam'")]
                      [(approver-revision)
                       (db:query-exec blocker
                                      "UPDATE operator_pin_credentials SET credential_revision = 2 WHERE operator_id = 'Sam'")]
                      [(requester-disabled)
                       (db:query-exec blocker
                                      "UPDATE operators SET active = 0 WHERE operator_id = 'Alice'")]))
                  #:option 'immediate)
                 (check-not-false (sync/timeout 5 worker))
                 (check-pred transaction-service-approval-required?
                             (unbox result))
                 (for ([table (in-list
                               '("transaction_command_receipts"
                                 "transaction_command_actor_attributions"
                                 "transaction_command_approver_attributions"))])
                   (check-equal?
                    (db:query-value connection
                                    (format "SELECT COUNT(*) FROM ~a WHERE command_id = 'cmd-wait-void'" table))
                    0))
                 (check-equal?
                  (db:query-value connection
                                  "SELECT COUNT(*) FROM transaction_events WHERE transaction_id = 'txn-wait'")
                  1)
                 (check-equal?
                  (db:query-value connection
                                  "SELECT active_transaction_id FROM register_shifts WHERE shift_id = 'shift-alice'")
                  "txn-wait")
                 (check-equal?
                  (db:query-value connection
                                  "SELECT COUNT(*) FROM transaction_void_approval_grants WHERE command_id = 'cmd-wait-void'")
                  1))
               (lambda () (db:disconnect blocker))))
           #:database-path database-path
           #:approval-now (lambda () (unbox monotonic-now))
           #:commit-command!
           (lambda (connection plan)
             (when (void-transaction-command?
                    (transaction-command-commit-plan-command plan))
               (channel-put reached-commit #t))
             (commit-transaction-command-outcome! connection plan))))
        (lambda () (delete-directory/files directory)))))

  (test-case "approver evidence failure rolls back event receipt actor and grant consumption"
    (call-with-service
     (lambda (connection service)
       (check-true
        (resolved?
         (transaction-service-execute-command
          service alice (start-transaction-command "cmd-fail-start" "txn-fail" 0))))
       (define command (void-transaction-command "cmd-fail-void" "txn-fail" 1))
       (insert-approval! connection command)
       (check-exn
        exn:fail?
        (lambda ()
          (transaction-service-execute-command
           service alice command #:approval-capability approval-capability)))
       (check-equal?
        (db:query-value connection
                        "SELECT COUNT(*) FROM transaction_command_receipts WHERE command_id = 'cmd-fail-void'")
        0)
       (check-equal?
        (db:query-value connection
                        "SELECT COUNT(*) FROM transaction_command_actor_attributions WHERE command_id = 'cmd-fail-void'")
        0)
       (check-equal?
        (db:query-value connection
                        "SELECT COUNT(*) FROM transaction_command_approver_attributions WHERE command_id = 'cmd-fail-void'")
        0)
       (check-equal?
        (db:query-value connection
                        "SELECT COUNT(*) FROM transaction_void_approval_grants WHERE command_id = 'cmd-fail-void'")
        1)
       (check-equal?
        (db:query-value connection
                        "SELECT COUNT(*) FROM transaction_events WHERE transaction_id = 'txn-fail'")
        1)
       (check-equal?
        (db:query-value connection
                        "SELECT active_transaction_id FROM register_shifts WHERE shift_id = 'shift-alice'")
        "txn-fail"))
     #:commit-command!
     (lambda (connection plan)
       (commit-transaction-command-outcome!
        connection plan
        #:insert-approver-attribution!
        (lambda (_connection _attribution)
          (error 'test "simulated approver evidence insertion failure"))))))

  (test-case "approved stale void durably consumes grant and attributes rejection"
    (call-with-service
     (lambda (connection service)
       (check-true
        (resolved?
         (transaction-service-execute-command
          service alice (start-transaction-command "cmd-stale-start" "txn-stale" 0))))
       (define command (void-transaction-command "cmd-stale-void" "txn-stale" 0))
       (insert-approval! connection command)
       (define result
         (transaction-service-execute-command
          service alice command #:approval-capability approval-capability))
       (check-true (resolved? result))
       (check-equal?
        (transaction-command-receipt-outcome-kind
         (transaction-service-command-resolved-receipt result))
        'version-conflict)
       (check-equal?
        (db:query-value connection
                        "SELECT COUNT(*) FROM transaction_void_approval_grants WHERE command_id = 'cmd-stale-void'")
        0)
       (check-equal?
        (db:query-value connection
                        "SELECT approver_operator_id FROM transaction_command_approver_attributions WHERE command_id = 'cmd-stale-void'")
        "Sam")
       (check-true
        (resolved? (transaction-service-execute-command service alice command))))))

  (test-case "attributed retry is same-operator across role change and opaque cross-operator"
    (call-with-service
     (lambda (connection service)
       (define command
         (start-transaction-command "cmd-recover" "txn-recover" 0))
       (check-true (resolved? (transaction-service-execute-command service alice command)))
       (check-true
        (resolved?
         (transaction-service-execute-command service alice-as-manager command)))
       (check-pred
        transaction-service-authorization-denied?
        (transaction-service-execute-command service bob command))
       (check-pred
        transaction-service-authorization-denied?
        (transaction-service-execute-command
         service bob
         (start-transaction-command "cmd-recover" "different-transaction" 0)))
       (check-equal?
        (transaction-command-actor-attribution-operator-id
         (load-transaction-command-actor-attribution connection "cmd-recover"))
        "Alice"))))

  (test-case "legacy unattributed exact receipt remains recoverable without attribution"
    (call-with-service
     (lambda (connection service)
       (db:query-exec
        connection "DROP TABLE transaction_void_approval_grants")
       (db:query-exec
        connection "DROP TABLE transaction_command_approver_attributions")
       (db:query-exec
        connection "DROP TABLE transaction_command_legacy_unapproved_void_receipts")
       (db:query-exec
        connection "DELETE FROM pos_schema_migrations WHERE version = 10")
       (db:query-exec
        connection
        "DROP TABLE transaction_command_actor_attributions")
       (db:query-exec
        connection
        "DROP TABLE transaction_command_legacy_unattributed_receipts")
       (db:query-exec
        connection
        "DELETE FROM pos_schema_migrations WHERE version = 9")
       (db:query-exec
        connection
        #<<SQL
INSERT INTO operators (operator_id, display_name, active)
SELECT cashier_id, display_name, active
FROM cashiers
WHERE cashier_id NOT IN (SELECT operator_id FROM operators)
SQL
        )
       (db:query-exec
        connection
        #<<SQL
INSERT INTO operator_roles (operator_id, role)
SELECT cashier_id, 'cashier'
FROM cashiers
WHERE cashier_id NOT IN (SELECT operator_id FROM operator_roles)
SQL
        )
       (define command
         (start-transaction-command "cmd-legacy-service" "txn-legacy-service" 0))
       (db:query-exec
        connection
        #<<SQL
INSERT INTO transaction_command_receipts
  (command_id, transaction_id, command_schema_version, command_type,
   expected_version, command_json, outcome_kind, outcome_code,
   outcome_stream_version)
VALUES
  ('cmd-legacy-service', 'txn-legacy-service', 1, 'start_transaction', 0,
   '{"schema_version":1,"command_id":"cmd-legacy-service","transaction_id":"txn-legacy-service","expected_version":0,"command_type":"start_transaction","payload":{}}',
   'accepted', 'accepted', 1)
SQL
        )
       (migrate-pos-database! connection)
       (check-true
        (resolved?
         (transaction-service-execute-command service bob command)))
       (check-false
        (load-transaction-command-actor-attribution
         connection "cmd-legacy-service"))
       (check-equal?
        (db:query-value
         connection
         "SELECT COUNT(*) FROM transaction_command_legacy_unattributed_receipts WHERE command_id = 'cmd-legacy-service'")
        1))))

  (test-case "missing actor on a modern receipt never falls back to legacy recovery"
    (call-with-service
     (lambda (connection service)
       (define command
         (start-transaction-command "cmd-modern-missing" "txn-modern-missing" 0))
       (check-true
        (resolved?
         (transaction-service-execute-command service alice command)))
       (db:query-exec
        connection
        "DELETE FROM transaction_command_actor_attributions WHERE command_id = 'cmd-modern-missing'")
       (check-pred
        transaction-service-authorization-denied?
        (transaction-service-execute-command service alice command))
       (check-pred
        transaction-service-authorization-denied?
        (transaction-service-execute-command service bob command))
       (check-pred
        transaction-service-authorization-denied?
        (transaction-service-execute-command
         service bob
         (start-transaction-command
          "cmd-modern-missing" "txn-secret-different" 0)))
       (check-equal?
        (db:query-value
         connection
         "SELECT COUNT(*) FROM transaction_command_legacy_unattributed_receipts WHERE command_id = 'cmd-modern-missing'")
        0)))))
