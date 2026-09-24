#lang racket

(require (prefix-in db: db)
         rackunit
         "../pos/application/authentication-service.rkt"
         "../pos/application/security-audit-service.rkt"
         "../pos/application/transaction-command.rkt"
         "../pos/application/transaction-service.rkt"
         "../pos/application/transaction-void-approval-service.rkt"
         "../pos/domain/fake-catalog.rkt"
         "../pos/domain/money.rkt"
         "../pos/domain/register-operations.rkt"
         "../pos/persistence/pos-database-migrations.rkt"
         "../pos/persistence/security-audit-store.rkt"
         "../pos/persistence/sqlite-auth-throttle.rkt"
         "../pos/persistence/sqlite-register-operations.rkt"
         "../pos/persistence/transaction-command-unit-of-work.rkt"
         "../pos/persistence/transaction-void-approval-store.rkt"
         "../pos/security/operator-session.rkt"
         "../pos/security/transaction-void-approval.rkt")

(define password-hash
  "$argon2id$v=19$m=19456,t=2,p=1$c2FsdHNhbHRzYWx0c2FsdA$aGFzaGhhc2hoYXNoaGFzaGhhc2hoYXNoaGFzaGhhc2g")
(define dummy-hash
  "$argon2id$v=19$m=19456,t=2,p=1$ZHVtbXlzYWx0ZHVtbXlzYWx0$ZHVtbXloYXNoZHVtbXloYXNoZHVtbXloYXNoZHVtbXloYXNo")
(define good-pin "80421637")
(define alice (authenticated-operator "Alice" "Alice" 'cashier))

(define (insert-operator! connection id role [active 1])
  (db:query-exec connection "INSERT INTO operators VALUES (?, ?, ?)" id id active)
  (db:query-exec connection "INSERT INTO operator_roles VALUES (?, ?)"
                 id (symbol->string role))
  (db:query-exec connection
                 "INSERT INTO operator_pin_credentials VALUES (?, ?, 1)"
                 id password-hash))

(define (call-with-services procedure)
  (define connection (db:sqlite3-connect #:database 'memory))
  (define now (box 1000))
  (dynamic-wind
    (lambda ()
      (db:query-exec connection "PRAGMA foreign_keys = ON")
      (migrate-pos-database! connection)
      (for ([operator (in-list
                       '(("Alice" cashier) ("Bob" cashier)
                         ("Sam" supervisor) ("Morgan" manager)))])
        (insert-operator! connection (first operator) (second operator)))
      (db:query-exec connection
                     "INSERT INTO register_configuration VALUES (1, 'register-1', 'Register 1')")
      (db:query-exec connection
                     "INSERT INTO cashiers VALUES ('Alice', 'Alice', 1)")
      (check-pred
       register-shift-opened?
       (open-register-shift!
        connection "Alice" (money 1000) (lambda () 1000)
        (lambda () "shift-alice")
        #:audit-append!
        (lambda (writer event)
          (append-security-audit-event!/in-transaction!
           writer event #:source-kind 'pos_core
           #:source-instance-id "audit_runtime_test"
           #:occurred-at-epoch-ms 1000)))))
    (lambda ()
      (define sessions
        (make-operator-session-store
         #:current-monotonic-ms (lambda () (unbox now))
         #:current-epoch-ms (lambda () (unbox now))))
      (define auth
        (make-authentication-service
         connection
         #:session-store sessions
         #:current-epoch-ms (lambda () (unbox now))
         #:verify-pin
         (lambda (pin hash)
           (and (string=? pin good-pin) (string=? hash password-hash)))
         #:dummy-password-hash dummy-hash))
      (define authority
        (make-transaction-void-approval-authority
         #:issuer-instance-id "instance-1"
         #:current-monotonic-ms (lambda () (unbox now))
         #:current-epoch-ms (lambda () (+ 500000 (unbox now)))))
      (define transactions
        (make-transaction-service
         connection
         #:catalog-lookup fake-catalog-lookup
         #:approval-consumer
         (lambda (approval-connection capability requester command)
           (consume-transaction-void-approval!/in-transaction!
            approval-connection capability "instance-1" requester command
            (unbox now)))
         #:current-epoch-ms (lambda () (unbox now))))
      (check-pred
       transaction-service-command-resolved?
       (transaction-service-execute-command
        transactions alice
        (start-transaction-command "cmd-start" "txn-1" 0)))
      (procedure
       connection auth sessions transactions
       (make-transaction-void-approval-service auth transactions authority)
       now))
    (lambda () (db:disconnect connection))))

(module+ test
  (test-case "required void-resolution audit failure rolls back command and grant consumption"
    (call-with-services
     (lambda (connection _auth _sessions _transactions approvals now)
       (define command
         (void-transaction-command "cmd-void-audit-fail" "txn-1" 1))
       (define granted
         (transaction-void-approval-service-request
          approvals alice command "Sam" good-pin))
       (check-pred transaction-void-approval-granted? granted)
       (define failing-transactions
         (make-transaction-service
          connection
          #:catalog-lookup fake-catalog-lookup
          #:approval-consumer
          (lambda (writer capability requester target)
            (consume-transaction-void-approval!/in-transaction!
             writer capability "instance-1" requester target (unbox now)))
          #:commit-command!
          (lambda (writer plan)
            (commit-transaction-command-outcome!
             writer plan
             #:audit-append!
             (lambda (_writer _event)
               (error 'test "simulated audit append failure"))))
          #:current-epoch-ms (lambda () (unbox now))))
       (check-pred
        transaction-service-command-persistence-failed?
        (transaction-service-execute-command
         failing-transactions alice command
         #:approval-capability
         (transaction-void-approval-token->capability
          (transaction-void-approval-granted-approval-token granted))))
       (check-equal?
        (db:query-value connection
                        "SELECT COUNT(*) FROM transaction_command_receipts WHERE command_id = 'cmd-void-audit-fail'")
        0)
       (check-equal?
        (db:query-value connection
                        "SELECT COUNT(*) FROM transaction_void_approval_grants WHERE command_id = 'cmd-void-audit-fail'")
        1)
       (check-equal?
        (db:query-value connection
                        "SELECT active_transaction_id FROM register_shifts WHERE shift_id = 'shift-alice'")
        "txn-1"))))

  (test-case "required approval.granted audit failure rolls back grant issuance"
    (call-with-services
     (lambda (connection auth _sessions transactions _approvals _now)
       (define failing
         (make-transaction-void-approval-service
          auth transactions
          (make-transaction-void-approval-authority
           #:issuer-instance-id "instance-1"
           #:current-monotonic-ms (lambda () 1000)
           #:current-epoch-ms (lambda () 501000))
          #:audit-append!
          (lambda (_writer _event)
            (error 'test "simulated audit append failure"))))
       (check-pred
        transaction-void-approval-unavailable?
        (transaction-void-approval-service-request
         failing alice
         (void-transaction-command "cmd-audit-fail" "txn-1" 1)
         "Sam" good-pin))
       (check-equal?
        (db:query-value connection
                        "SELECT COUNT(*) FROM transaction_void_approval_grants")
        0))))

  (test-case "supervisor and manager approval authenticate without replacing register session"
    (call-with-services
     (lambda (connection auth sessions _transactions approvals _now)
       (define alice-login
         (authentication-service-login auth "Alice" good-pin))
       (check-pred authentication-login-succeeded? alice-login)
       (for ([approver-id (in-list '("Sam" "Morgan"))]
             [command-id (in-list '("cmd-void-sam" "cmd-void-morgan"))])
         (define granted
           (transaction-void-approval-service-request
            approvals alice
            (void-transaction-command command-id "txn-1" 1)
            approver-id good-pin))
         (check-pred transaction-void-approval-granted? granted)
         (check-regexp-match
          #px"^gpos_a1_[0-9a-f]{64}$"
          (transaction-void-approval-granted-approval-token granted))
         (check-false
          (string-contains?
           (format "~v" granted)
           (transaction-void-approval-granted-approval-token granted))
          "structural diagnostics must not print the one-shot token")
         (check-equal?
          (operator-session-operator-id
           (operator-session-store-current sessions))
          "Alice")
         (check-equal?
          (db:query-value
           connection
           "SELECT COUNT(*) FROM transaction_void_approval_grants WHERE command_id = ?"
           command-id)
          1)))))

  (test-case "self approval and cashier approval share a generic denial"
    (call-with-services
     (lambda (connection _auth _sessions _transactions approvals _now)
       (for ([approver-id (in-list '("Alice" "Bob"))])
         (check-pred
          transaction-void-approval-not-granted?
          (transaction-void-approval-service-request
           approvals alice
           (void-transaction-command
            (string-append "cmd-void-" approver-id) "txn-1" 1)
           approver-id good-pin)))
       (check-equal?
        (db:query-value connection
                        "SELECT COUNT(*) FROM transaction_void_approval_grants")
        0)
       (check-equal?
        (db:query-value connection
                        "SELECT COUNT(*) FROM security_audit_events WHERE event_type = 'approval.not_granted'")
        2))))

  (test-case "best-effort approval rejection audit failure never grants approval"
    (call-with-services
     (lambda (connection auth _sessions transactions _approvals now)
       (define approvals
         (make-transaction-void-approval-service
          auth transactions
          (make-transaction-void-approval-authority
           #:issuer-instance-id "instance-rejection-audit"
           #:current-monotonic-ms (lambda () (unbox now))
           #:current-epoch-ms (lambda () (unbox now)))
          #:audit-source
          (make-security-audit-source
           'pos_core "audit_runtime_bad_clock" (lambda () -1))))
       (check-pred
        transaction-void-approval-not-granted?
        (transaction-void-approval-service-request
         approvals alice
         (void-transaction-command "cmd-rejection-audit-fail" "txn-1" 1)
         "Sam" "80421638"))
       (check-equal?
        (db:query-value connection
                        "SELECT COUNT(*) FROM transaction_void_approval_grants")
        0))))

  (test-case "manager operating a till still needs an independent approver"
    (call-with-services
     (lambda (connection auth sessions transactions approvals _now)
       (db:query-exec connection
                      "UPDATE operator_roles SET role = 'manager' WHERE operator_id = 'Alice'")
       (define manager-requester
         (authenticated-operator "Alice" "Alice" 'manager))
       (check-pred authentication-login-succeeded?
                   (authentication-service-login auth "Alice" good-pin))
       (define command
         (void-transaction-command "cmd-manager-own-void" "txn-1" 1))
       (check-pred transaction-void-approval-not-granted?
                   (transaction-void-approval-service-request
                    approvals manager-requester command "Alice" good-pin))
       (check-pred transaction-service-approval-required?
                   (transaction-service-execute-command
                    transactions manager-requester command))
       (define granted
         (transaction-void-approval-service-request
          approvals manager-requester command "Sam" good-pin))
       (check-pred transaction-void-approval-granted? granted)
       (check-equal?
        (operator-session-operator-id (operator-session-store-current sessions))
        "Alice")
       (check-pred
        transaction-service-command-resolved?
        (transaction-service-execute-command
         transactions manager-requester command
         #:approval-capability
         (transaction-void-approval-token->capability
          (transaction-void-approval-granted-approval-token granted))))
       (check-equal?
        (db:query-value connection
                        "SELECT operator_id FROM transaction_command_actor_attributions WHERE command_id = 'cmd-manager-own-void'")
        "Alice")
       (check-equal?
        (db:query-value connection
                        "SELECT approver_operator_id FROM transaction_command_approver_attributions WHERE command_id = 'cmd-manager-own-void'")
        "Sam"))))

  (test-case "issued capability is consumable by the exact transaction command"
    (call-with-services
     (lambda (connection _auth _sessions transactions approvals _now)
       (define command (void-transaction-command "cmd-consume" "txn-1" 1))
       (define granted
         (transaction-void-approval-service-request
          approvals alice command "Sam" good-pin))
       (check-pred transaction-void-approval-granted? granted)
       (define capability
         (transaction-void-approval-token->capability
          (transaction-void-approval-granted-approval-token granted)))
       (check-not-false capability)
       (define result
         (transaction-service-execute-command
          transactions alice command #:approval-capability capability))
       (check-pred transaction-service-command-resolved? result)
       (check-equal?
        (db:query-value
         connection
         "SELECT COUNT(*) FROM security_audit_events WHERE event_type = 'transaction.void_resolved'")
        1)
       (define stored-audit-json
         (format "~a"
                 (db:query-list connection
                                "SELECT event_json FROM security_audit_events ORDER BY sequence")))
       (for ([secret (in-list
                      (list good-pin password-hash
                            (transaction-void-approval-granted-approval-token granted)
                            "049000001234"))])
         (check-false (string-contains? stored-audit-json secret)))
       (check-pred
        transaction-service-command-resolved?
        (transaction-service-execute-command transactions alice command))
       (check-equal?
        (db:query-value
         connection
         "SELECT COUNT(*) FROM security_audit_events WHERE event_type = 'transaction.void_resolved'")
        1)
       (check-equal?
        (db:query-value
         connection
         "SELECT approver_operator_id FROM transaction_command_approver_attributions WHERE command_id = 'cmd-consume'")
        "Sam"))))

  (test-case "approved durable version conflict has one atomic resolution audit"
    (call-with-services
     (lambda (connection _auth _sessions transactions approvals _now)
       (define command
         (void-transaction-command "cmd-audited-stale-void" "txn-1" 1))
       (define granted
         (transaction-void-approval-service-request
          approvals alice command "Sam" good-pin))
       (check-pred transaction-void-approval-granted? granted)
       (check-pred
        transaction-service-command-resolved?
        (transaction-service-execute-command
         transactions alice
         (scan-barcode-command "cmd-intervening-scan" "txn-1" 1
                               "049000001234")))
       (check-pred
        transaction-service-command-resolved?
        (transaction-service-execute-command
         transactions alice command
         #:approval-capability
         (transaction-void-approval-token->capability
          (transaction-void-approval-granted-approval-token granted))))
       (check-equal?
        (db:query-value
         connection
         "SELECT outcome_kind FROM transaction_command_receipts WHERE command_id = 'cmd-audited-stale-void'")
        "version_conflict")
       (check-equal?
        (db:query-value
         connection
         "SELECT COUNT(*) FROM security_audit_events WHERE event_type = 'transaction.void_resolved'")
        1)
       (check-equal?
        (db:query-value
         connection
         "SELECT COUNT(*) FROM transaction_command_approver_attributions WHERE command_id = 'cmd-audited-stale-void'")
        1)
       (check-pred
        transaction-service-command-resolved?
        (transaction-service-execute-command transactions alice command))
       (check-equal?
        (db:query-value
         connection
         "SELECT COUNT(*) FROM security_audit_events WHERE event_type = 'transaction.void_resolved'")
        1))))

  (test-case "approval failures use normal durable throttle and success clears it"
    (call-with-services
     (lambda (connection _auth _sessions _transactions approvals now)
       (define command (void-transaction-command "cmd-throttle" "txn-1" 1))
       (check-pred
        transaction-void-approval-not-granted?
        (transaction-void-approval-service-request
         approvals alice command "Sam" "80421638"))
       (check-equal?
        (operator-login-throttle-consecutive-failures
         (load-operator-login-throttle connection "Sam"))
        1)
       (set-box! now 2000)
       (check-pred
        transaction-void-approval-granted?
        (transaction-void-approval-service-request
         approvals alice command "Sam" good-pin))
       (check-false (load-operator-login-throttle connection "Sam")))))

  (test-case "stale target is rejected before approver PIN verification"
    (call-with-services
     (lambda (connection _auth _sessions _transactions approvals _now)
       (check-pred
        transaction-void-approval-target-stale?
        (transaction-void-approval-service-request
         approvals alice
         (void-transaction-command "cmd-stale" "txn-1" 99)
         "Sam" "80421638"))
       (check-false (load-operator-login-throttle connection "Sam"))))))
