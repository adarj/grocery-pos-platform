#lang racket

(require (prefix-in db: db)
         racket/file
         rackunit
         "../pos/application/operator-service.rkt"
         "../pos/persistence/sqlite-connection.rkt"
         "../pos/persistence/sqlite-maintenance.rkt"
         "../pos/persistence/sqlite-operators.rkt"
         "../pos/persistence/sqlite-restore.rkt"
         "../pos/runtime.rkt")

(module+ test
  (test-case "credential and command actor survive validated backup and restore"
    (define directory
      (make-temporary-file "operator-credential-backup-~a" 'directory))
    (define source-path (build-path directory "source.db"))
    (define backup-path (build-path directory "backup.db"))
    (define restored-path (build-path directory "restored.db"))
    (define pin "80421637")
    (dynamic-wind
      void
      (lambda ()
        (initialize-sqlite-database! source-path)
        (define source-connection
          (open-pos-sqlite-connection source-path 'read/write))
        (dynamic-wind
          void
          (lambda ()
            (define service (make-operator-service source-connection))
            (check-pred
             operator-create-succeeded?
             (operator-service-create
              service "manager-backup" "Backup Manager" 'manager))
            (check-pred
             operator-pin-enrollment-succeeded?
             (operator-service-enroll-pin service "manager-backup" pin))
            (db:query-exec
             source-connection
             #<<SQL
INSERT INTO transaction_command_receipts
  (command_id, transaction_id, command_schema_version, command_type,
   expected_version, command_json, outcome_kind, outcome_code,
   outcome_stream_version)
VALUES
  ('cmd-backup-actor', 'txn-backup-actor', 1, 'start_transaction', 0,
   '{"schema_version":1,"command_id":"cmd-backup-actor","transaction_id":"txn-backup-actor","expected_version":0,"command_type":"start_transaction","payload":{}}',
   'accepted', 'accepted', 1)
SQL
             )
            (db:query-exec
             source-connection
             "INSERT INTO transaction_command_actor_attributions VALUES ('cmd-backup-actor', 'manager-backup')"))
          (lambda () (db:disconnect source-connection)))

        (create-pos-sqlite-backup! source-path backup-path)
        (check-true
         (sqlite-backup-validation-valid?
          (validate-pos-sqlite-backup backup-path)))
        (restore-pos-sqlite-database-offline!
         backup-path restored-path #:operation-id "credential-round-trip")
        ;; Publication produces a standalone SQLite snapshot; normal startup
        ;; re-establishes the production WAL policy without changing v9.
        (initialize-sqlite-database! restored-path)
        (define restored-connection
          (open-pos-sqlite-connection restored-path 'read/write))
        (dynamic-wind
          void
          (lambda ()
            (define restored-service
              (make-operator-service restored-connection))
            (define verified
              (operator-service-verify-pin
               restored-service "manager-backup" pin))
            (check-true (operator-pin-verification-verified? verified))
            (check-equal?
             (operator-pin-verification-credential-revision verified)
             1)
            (check-equal?
             (db:query-value
              restored-connection
              "SELECT operator_id FROM transaction_command_actor_attributions WHERE command_id = 'cmd-backup-actor'")
             "manager-backup"))
          (lambda () (db:disconnect restored-connection))))
      (lambda () (delete-directory/files directory)))))
