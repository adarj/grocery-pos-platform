#lang racket

(require (prefix-in db: db)
         racket/file
         rackunit
         "../pos/application/operator-service.rkt"
         "../pos/application/transaction-command.rkt"
         "../pos/domain/security-audit-event.rkt"
         "../pos/domain/transaction-void-approval.rkt"
         "../pos/persistence/security-audit-store.rkt"
         "../pos/persistence/sqlite-connection.rkt"
         "../pos/persistence/sqlite-maintenance.rkt"
         "../pos/persistence/sqlite-operators.rkt"
         "../pos/persistence/sqlite-restore.rkt"
         "../pos/persistence/transaction-void-approval-store.rkt"
         "../pos/runtime.rkt"
         "../pos/runtime-config.rkt"
         "../pos/security/operator-pin.rkt"
         "../pos/security/transaction-void-approval.rkt")

(module+ test
  (test-case "selected backup restores its credential revision and audit history"
    (define directory (make-temporary-file "credential-restore-~a" 'directory))
    (define source-path (build-path directory "source.db"))
    (define backup-path (build-path directory "revision-one.db"))
    (define restored-path (build-path directory "restored.db"))
    (define backup-audit-rows (box #f))
    (dynamic-wind
      void
      (lambda ()
        (initialize-sqlite-database! source-path)
        (define source (open-pos-sqlite-connection source-path 'read/write))
        (dynamic-wind
          void
          (lambda ()
            (db:query-exec source
                           "INSERT INTO operators VALUES ('Alice', 'Alice', 1)")
            (db:query-exec source
                           "INSERT INTO operator_roles VALUES ('Alice', 'cashier')")
            (db:query-exec
             source "INSERT INTO operator_pin_credentials VALUES ('Alice', ?, 1)"
             (hash-operator-pin "80421637"))
            (append-security-audit-event!
             source (runtime-started-event)
             #:source-kind 'pos_core
             #:source-instance-id "audit_runtime_backup_revision_one"
             #:occurred-at-epoch-ms 1000)
            (set-box!
             backup-audit-rows
             (db:query-rows source
                            "SELECT * FROM security_audit_events ORDER BY sequence")))
          (lambda () (db:disconnect source)))
        (create-pos-sqlite-backup! source-path backup-path)
        (check-true
         (sqlite-backup-validation-valid?
          (validate-pos-sqlite-backup backup-path)))
        (define changed (open-pos-sqlite-connection source-path 'read/write))
        (dynamic-wind
          void
          (lambda ()
            (check-pred operator-pin-reset-succeeded?
                        (operator-service-reset-pin
                         (make-operator-service changed)
                         "Alice" "48295173"))
            (check-equal?
             (operator-pin-record-credential-revision
              (load-operator-pin-record changed "Alice"))
             2)
            (check-equal?
             (db:query-value changed
                             "SELECT COUNT(*) FROM security_audit_events")
             2))
          (lambda () (db:disconnect changed)))
        (restore-pos-sqlite-database-offline!
         backup-path restored-path #:operation-id "credential-rollback")
        (initialize-sqlite-database! restored-path)
        (define restored (open-pos-sqlite-connection restored-path 'read/write))
        (dynamic-wind
          void
          (lambda ()
            (define credential (load-operator-pin-record restored "Alice"))
            (check-equal?
             (operator-pin-record-credential-revision credential) 1)
            (check-true
             (verify-operator-pin
              "80421637" (operator-pin-record-password-hash credential)))
            (check-false
             (verify-operator-pin
              "48295173" (operator-pin-record-password-hash credential)))
            (check-equal?
             (db:query-rows restored
                            "SELECT * FROM security_audit_events ORDER BY sequence")
             (unbox backup-audit-rows))
            (check-true
             (security-audit-ledger-valid?
              (verify-security-audit-ledger restored))))
          (lambda () (db:disconnect restored)))
        (define restarted
          (start-pos-runtime
           (pos-runtime-config "127.0.0.1" 7340 restored-path)))
        (stop-pos-runtime! restarted)
        (define after-start
          (open-pos-sqlite-connection restored-path 'read/write))
        (dynamic-wind
          void
          (lambda ()
            (define rows
              (db:query-rows after-start
                             "SELECT * FROM security_audit_events ORDER BY sequence"))
            (check-equal? (length rows) 2)
            (check-equal? (first rows) (first (unbox backup-audit-rows)))
            (check-equal?
             (db:query-list after-start
                            "SELECT event_type FROM security_audit_events ORDER BY sequence")
             '("runtime.started" "runtime.started"))
            (check-true
             (security-audit-ledger-valid?
              (verify-security-audit-ledger after-start))))
          (lambda () (db:disconnect after-start)))
        ;; The newer source remains isolated; no revision-2 credential or
        ;; reset audit row was merged into the selected restore point.
        (define displaced
          (open-pos-sqlite-connection source-path 'read/write))
        (dynamic-wind
          void
          (lambda ()
            (check-equal?
             (operator-pin-record-credential-revision
              (load-operator-pin-record displaced "Alice")) 2)
            (check-equal?
             (db:query-list displaced
                            "SELECT event_type FROM security_audit_events ORDER BY sequence")
             '("runtime.started" "operator.pin_reset")))
          (lambda () (db:disconnect displaced))))
      (lambda () (delete-directory/files directory))))

  (test-case "backup keeps durable approval evidence but cannot resurrect an unused grant"
    (define directory
      (make-temporary-file "void-approval-backup-~a" 'directory))
    (define source-path (build-path directory "source.db"))
    (define backup-path (build-path directory "backup.db"))
    (define restored-path (build-path directory "restored.db"))
    (dynamic-wind
      void
      (lambda ()
        (initialize-sqlite-database! source-path)
        (define connection (open-pos-sqlite-connection source-path 'read/write))
        (dynamic-wind
          void
          (lambda ()
            (for ([row (in-list '(("Alice" "cashier")
                                  ("Sam" "supervisor")))])
              (db:query-exec connection
                             "INSERT INTO operators VALUES (?, ?, 1)"
                             (first row) (first row))
              (db:query-exec connection
                             "INSERT INTO operator_roles VALUES (?, ?)"
                             (first row) (second row))
              (db:query-exec connection
                             "INSERT INTO operator_pin_credentials VALUES (?, '$argon2id$v=19$m=19456,t=2,p=1$c2FsdA$aGFzaA', 1)"
                             (first row)))
            (define capability
              (transaction-void-approval-token->capability
               (string-append "gpos_a1_" (make-string 64 #\a))))
            (db:call-with-transaction
             connection
             (lambda ()
               (replace-transaction-void-approval-grant!/in-transaction!
                connection
                (transaction-void-approval-grant
                 "unused-approval"
                 (transaction-void-approval-capability-token-digest capability)
                 "old-process" "Alice" 1 "Sam" 1
                 "cmd-pending" "txn-pending" 1 1
                 1000 91000 591000)
                "old-process" 1000))
             #:option 'immediate)
            (db:query-exec
             connection
             #<<SQL
INSERT INTO transaction_command_receipts
  (command_id, transaction_id, command_schema_version, command_type,
   expected_version, command_json, outcome_kind, outcome_code,
   outcome_stream_version)
VALUES ('cmd-committed', 'txn-committed', 1, 'void_transaction', 1,
        '{"schema_version":1,"command_id":"cmd-committed","transaction_id":"txn-committed","expected_version":1,"command_type":"void_transaction","payload":{}}',
        'domain_rejected', 'invalid_transaction_state', 1)
SQL
             )
            (db:query-exec
             connection
             "INSERT INTO transaction_command_actor_attributions VALUES ('cmd-committed', 'Alice')")
            (db:query-exec
             connection
             "INSERT INTO transaction_command_approver_attributions VALUES ('cmd-committed', 'committed-approval', 'Sam', 1, 1000)"))
          (lambda () (db:disconnect connection)))
        (create-pos-sqlite-backup! source-path backup-path)
        (check-true
         (sqlite-backup-validation-valid?
          (validate-pos-sqlite-backup backup-path)))
        (restore-pos-sqlite-database-offline!
         backup-path restored-path #:operation-id "approval-round-trip")
        (initialize-sqlite-database! restored-path)
        (define restored
          (open-pos-sqlite-connection restored-path 'read/write))
        (dynamic-wind
          void
          (lambda ()
            (check-equal?
             (db:query-row
              restored
              "SELECT approver_operator_id, approver_credential_revision FROM transaction_command_approver_attributions WHERE command_id = 'cmd-committed'")
             #( "Sam" 1))
            (check-equal?
             (db:query-value restored
                             "SELECT operator_id FROM transaction_command_actor_attributions WHERE command_id = 'cmd-committed'")
             "Alice")
            (check-equal?
             (db:query-value restored
                             "SELECT COUNT(*) FROM transaction_void_approval_grants WHERE command_id = 'cmd-pending'")
             1)
            (define capability
              (transaction-void-approval-token->capability
               (string-append "gpos_a1_" (make-string 64 #\a))))
            (db:call-with-transaction
             restored
             (lambda ()
               (check-pred
                transaction-void-approval-rejected?
                (consume-transaction-void-approval!/in-transaction!
                 restored capability "new-process" "Alice" 1
                 (void-transaction-command "cmd-pending" "txn-pending" 1)
                 2000)))
             #:option 'immediate))
          (lambda () (db:disconnect restored))))
      (lambda () (delete-directory/files directory)))))
