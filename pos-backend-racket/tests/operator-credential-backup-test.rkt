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
  (test-case "Argon2id credential survives validated backup and offline restore"
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
             (operator-service-enroll-pin service "manager-backup" pin)))
          (lambda () (db:disconnect source-connection)))

        (create-pos-sqlite-backup! source-path backup-path)
        (check-true
         (sqlite-backup-validation-valid?
          (validate-pos-sqlite-backup backup-path)))
        (restore-pos-sqlite-database-offline!
         backup-path restored-path #:operation-id "credential-round-trip")
        ;; Publication produces a standalone SQLite snapshot; normal startup
        ;; re-establishes the production WAL policy without changing v7.
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
             1))
          (lambda () (db:disconnect restored-connection))))
      (lambda () (delete-directory/files directory)))))
