#lang racket

(require (prefix-in db: db)
         racket/file
         racket/string
         rackunit
         "../pos/domain/security-audit-event.rkt"
         "../pos/domain/transaction-event.rkt"
         "../pos/persistence/pos-database-migrations.rkt"
         "../pos/persistence/security-audit-store.rkt"
         "../pos/persistence/sqlite-connection.rkt"
         "../pos/persistence/sqlite-maintenance.rkt"
         "../pos/persistence/sqlite-restore.rkt"
         "../pos/persistence/sqlite-transaction-event-store.rkt"
         "../pos/runtime-config.rkt"
         "../pos/runtime.rkt")

(define (call-with-temporary-directory procedure)
  (define directory
    (make-temporary-file "grocery-pos-restore-~a" 'directory))
  (dynamic-wind
    void
    (lambda () (procedure directory))
    (lambda () (delete-directory/files directory))))

(define (call-with-production-connection database-path procedure)
  (define connection
    (open-pos-sqlite-connection database-path 'read/write))
  (dynamic-wind
    void
    (lambda () (procedure connection))
    (lambda ()
      (when (db:connected? connection)
        (db:disconnect connection)))))

(define (create-current-database-with-fact! database-path transaction-id)
  (initialize-sqlite-database! database-path)
  (call-with-production-connection
   database-path
   (lambda (connection)
     (check-pred
      journal-append-succeeded?
      (append-transaction-events!
       connection
       transaction-id
       0
       (list (transaction-started transaction-id)))))))

(define (database-has-transaction? database-path transaction-id)
  (call-with-pos-sqlite-inspection-connection
   database-path
   (lambda (connection)
     (= 1
        (db:query-value
         connection
         "SELECT COUNT(*) FROM transaction_events WHERE transaction_id = ?"
         transaction-id)))))

(define (make-valid-backup! directory transaction-id)
  (define source (build-path directory (string-append transaction-id ".db")))
  (define backup
    (build-path directory (string-append transaction-id "-backup.db")))
  (create-current-database-with-fact! source transaction-id)
  (create-pos-sqlite-backup! source backup)
  backup)

(define (sidecar-path database-path suffix)
  (bytes->path (bytes-append (path->bytes database-path) suffix)))

(define (partial-restore-paths directory)
  (for/list ([entry (in-list (directory-list directory #:build? #t))]
             #:when (string-suffix? (path->string entry) ".partial"))
    entry))

(module+ test
  (test-case "offline restore preserves exact validated security audit evidence"
    (call-with-temporary-directory
     (lambda (directory)
       (define source (build-path directory "audit-source.db"))
       (define backup (build-path directory "audit-backup.db"))
       (define target (build-path directory "audit-target.db"))
       (create-current-database-with-fact! source "txn-audit-source")
       (define original-rows
         (call-with-production-connection
          source
          (lambda (connection)
            (append-security-audit-event!
             connection (runtime-started-event)
             #:source-kind 'pos_core
             #:source-instance-id "audit_runtime_restore"
             #:occurred-at-epoch-ms 1000)
            (db:query-rows
             connection
             "SELECT sequence, event_json, previous_event_hash, event_hash FROM security_audit_events ORDER BY sequence"))))
       (create-pos-sqlite-backup! source backup)
       (create-current-database-with-fact! target "txn-displaced")
       (restore-pos-sqlite-database-offline!
        backup target #:operation-id "restore-audit-evidence")
       (call-with-pos-sqlite-inspection-connection
        target
        (lambda (connection)
          (check-equal?
           (db:query-rows
            connection
            "SELECT sequence, event_json, previous_event_hash, event_hash FROM security_audit_events ORDER BY sequence")
           original-rows)
          (check-true
           (security-audit-ledger-valid?
            (verify-security-audit-ledger connection)))))
       (define restored-runtime
         (start-pos-runtime (pos-runtime-config "127.0.0.1" 7340 target)))
       (stop-pos-runtime! restored-runtime)
       (call-with-pos-sqlite-inspection-connection
        target
        (lambda (connection)
          (define rows
            (db:query-rows
             connection
             "SELECT sequence, event_json, previous_event_hash, event_hash FROM security_audit_events ORDER BY sequence"))
          (check-equal? (first rows) (first original-rows))
          (check-equal? (length rows) 2)
          (check-equal?
           (db:query-list connection
                          "SELECT event_type FROM security_audit_events ORDER BY sequence")
           '("runtime.started" "runtime.started"))
          (check-true
           (security-audit-ledger-valid?
            (verify-security-audit-ledger connection))))))))

  (test-case "offline restore replaces current DB and preserves prior durable state"
    (call-with-temporary-directory
     (lambda (directory)
       (define target (build-path directory "pos.db"))
       (create-current-database-with-fact! target "txn-displaced")
       (define backup (make-valid-backup! directory "txn-restored"))

       (define restored
         (restore-pos-sqlite-database-offline!
          backup target #:operation-id "restore-existing"))

       (check-true (database-has-transaction? target "txn-restored"))
       (check-false (database-has-transaction? target "txn-displaced"))
       (check-equal? (sqlite-restore-installed-restored-schema-version restored)
                     current-pos-database-schema-version)
       (check-equal? (file-or-directory-permissions target 'bits) #o640)

       (define evidence-directory
         (sqlite-restore-installed-recovery-directory restored))
       (check-equal? (file-or-directory-permissions evidence-directory 'bits)
                     #o700)
       (define displaced-db (build-path evidence-directory "pos.db"))
       (check-true (database-has-transaction? displaced-db "txn-displaced"))
       (check-false (database-has-transaction? displaced-db "txn-restored"))
       (check-true
        (file-exists? (build-path evidence-directory "restore-manifest.json")))

       ;; Normal startup establishes WAL on the restored standalone snapshot,
       ;; after which ordinary request-style connections accept it.
       (initialize-sqlite-database! target)
       (call-with-production-connection
        target
        (lambda (connection)
          (check-equal? (db:query-value connection "PRAGMA journal_mode")
                        "wal")
          (check-equal?
           (read-pos-database-migration-history connection)
           (sqlite-backup-validation-migration-history
            (prepared-sqlite-restore-staged-validation
             (sqlite-restore-installed-prepared restored)))))))))

  (test-case "missing DB restore preserves orphan WAL SHM and journal evidence"
    (call-with-temporary-directory
     (lambda (directory)
       (define target (build-path directory "pos.db"))
       (define backup (make-valid-backup! directory "txn-missing-target"))
       (define sidecars
         (list (cons #"-wal" #"orphan-wal-evidence")
               (cons #"-shm" #"orphan-shm-evidence")
               (cons #"-journal" #"orphan-journal-evidence")))
       (for ([sidecar (in-list sidecars)])
         (call-with-output-file
          (sidecar-path target (car sidecar))
          #:exists 'error
          (lambda (output) (write-bytes (cdr sidecar) output))))

       (define restored
         (restore-pos-sqlite-database-offline!
          backup target #:operation-id "restore-missing"))
       (check-true (database-has-transaction? target "txn-missing-target"))
       (define evidence
         (sqlite-restore-installed-recovery-directory restored))
       (check-false (file-exists? (build-path evidence "pos.db")))
       (for ([sidecar (in-list sidecars)])
         (define canonical-sidecar (sidecar-path target (car sidecar)))
         (define evidence-name
           (string-append "pos.db" (bytes->string/utf-8 (car sidecar))))
         (check-false (file-exists? canonical-sidecar))
         (check-equal? (file->bytes (build-path evidence evidence-name))
                       (cdr sidecar))))))

  (test-case "invalid selected or staged backup never touches canonical state"
    (call-with-temporary-directory
     (lambda (directory)
       (define target (build-path directory "pos.db"))
       (create-current-database-with-fact! target "txn-untouched")
       (define target-before (file->bytes target))
       (define invalid (build-path directory "invalid.db"))
       (display-to-file "not sqlite" invalid #:exists 'error)

       (check-exn
        (lambda (exception)
          (and (exn:fail:pos-restore? exception)
               (eq? (exn:fail:pos-restore-code exception) 'backup_invalid)))
        (lambda ()
          (restore-pos-sqlite-database-offline! invalid target)))
       (check-equal? (file->bytes target) target-before)
       (check-false (directory-exists? (build-path directory "recovery")))

       (define backup (make-valid-backup! directory "txn-staged-invalid"))
       (define validation-count 0)
       (check-exn
        (lambda (exception)
          (and (exn:fail:pos-restore? exception)
               (eq? (exn:fail:pos-restore-code exception) 'staging_failed)))
        (lambda ()
          (restore-pos-sqlite-database-offline!
           backup
           target
           #:validate-backup
           (lambda (path)
             (set! validation-count (add1 validation-count))
             (if (= validation-count 1)
                 (validate-pos-sqlite-backup path)
                 (error 'test "simulated staged-copy validation failure"))))))
       (check-equal? validation-count 2)
       (check-equal? (file->bytes target) target-before)
       (check-equal? (partial-restore-paths directory) '())
       (check-false (directory-exists? (build-path directory "recovery"))))))

  (test-case "canonical namespace rejects aliases and unsupported objects"
    (call-with-temporary-directory
     (lambda (directory)
       (define backup (make-valid-backup! directory "txn-safe-path"))
       (define outside (build-path directory "outside.db"))
       (display-to-file "outside" outside #:exists 'error)
       (define target-link (build-path directory "pos-link.db"))
       (make-file-or-directory-link outside target-link)
       (check-exn exn:fail:pos-restore?
                  (lambda ()
                    (restore-pos-sqlite-database-offline!
                     backup target-link)))
       (check-equal? (file->string outside) "outside")
       (check-true (link-exists? target-link))

       (define target-directory (build-path directory "pos-directory.db"))
       (make-directory target-directory)
       (check-exn exn:fail:pos-restore?
                  (lambda ()
                    (restore-pos-sqlite-database-offline!
                     backup target-directory)))

       (check-exn exn:fail:pos-restore?
                  (lambda ()
                    (restore-pos-sqlite-database-offline!
                     backup backup)))

       (define aliased-target (build-path directory "pos-aliased.db"))
       (create-current-database-with-fact! aliased-target "txn-alias")
       (define aliased-backup (build-path directory "aliased-backup.db"))
       (make-file-or-directory-link aliased-target aliased-backup)
       (check-exn exn:fail:pos-restore?
                  (lambda ()
                    (restore-pos-sqlite-database-offline!
                     aliased-backup aliased-target)))
       (check-true (database-has-transaction? aliased-target "txn-alias"))

       (define target-with-bad-sidecar
         (build-path directory "pos-bad-sidecar.db"))
       (make-directory (sidecar-path target-with-bad-sidecar #"-wal"))
       (check-exn exn:fail:pos-restore?
                  (lambda ()
                    (restore-pos-sqlite-database-offline!
                     backup target-with-bad-sidecar)))
       (check-false (file-exists? target-with-bad-sidecar))

       (define target-staging-collision
         (build-path directory "pos-collision.db"))
       (check-exn
        exn:fail:pos-restore?
        (lambda ()
          (prepare-pos-sqlite-restore!
           backup
           target-staging-collision
           #:make-staging-file!
           (lambda (_parent)
             (error 'test "simulated staging namespace collision")))))
       (check-false (file-exists? target-staging-collision)))))

  (test-case "recovery-directory collision aborts before displacement"
    (call-with-temporary-directory
     (lambda (directory)
       (define target (build-path directory "pos.db"))
       (create-current-database-with-fact! target "txn-before-collision")
       (define target-before (file->bytes target))
       (define backup (make-valid-backup! directory "txn-after-collision"))
       (define collision
         (build-path directory "recovery" "restore-collision"))
       (make-directory* collision)

       (check-exn exn:fail:pos-restore?
                  (lambda ()
                    (restore-pos-sqlite-database-offline!
                     backup target #:operation-id "restore-collision")))
       (check-equal? (file->bytes target) target-before)
       (check-true (database-has-transaction? target "txn-before-collision"))
       (check-equal? (partial-restore-paths directory) '())))))
