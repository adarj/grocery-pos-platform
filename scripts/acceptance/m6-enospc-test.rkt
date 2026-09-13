#lang racket

(require (prefix-in db: db)
         json
         racket/file
         racket/string
         "../../pos-backend-racket/pos/persistence/sqlite-connection.rkt"
         "../../pos-backend-racket/pos/persistence/sqlite-maintenance.rkt"
         "../../pos-backend-racket/pos/runtime.rkt"
         "../../pos-backend-racket/pos/support/support-bundle.rkt")

(define arguments (vector->list (current-command-line-arguments)))
(unless (= (length arguments) 1)
  (raise-user-error 'm6-enospc-test "expected the private tmpfs directory"))
(define constrained-directory (path->complete-path (car arguments)))
(unless (directory-exists? constrained-directory)
  (raise-user-error 'm6-enospc-test "private tmpfs directory is missing"))

(define (ensure condition message)
  (unless condition (error 'm6-enospc-test message)))

(define (fails? procedure)
  (with-handlers ([(lambda (_value) #t) (lambda (_value) #t)])
    (procedure)
    #f))

(define (fill-filesystem! path)
  (define output (open-output-file path #:exists 'error #:mode 'binary))
  (define block (make-bytes 4096 65))
  (let loop ()
    (with-handlers
        ([(lambda (_value) #t)
          (lambda (_value)
            (with-handlers ([(lambda (_value) #t) void])
              (close-output-port output)))])
      (write-bytes block output)
      (flush-output output)
      (loop))))

(define (partial-files directory)
  (for/list ([entry (in-list (directory-list directory))]
             #:when (string-suffix? (path->string entry) ".partial"))
    entry))

(define temporary-source-directory
  (make-temporary-file "grocery-pos-m6-enospc-source-~a" 'directory))

(dynamic-wind
  void
  (lambda ()
    ;; Keep a production connection open, exhaust only the isolated tmpfs,
    ;; and require a real SQLite mutation to fail. After freeing the filler,
    ;; the same database must reopen and pass the complete validation boundary.
    (define write-database (build-path constrained-directory "write.db"))
    (initialize-sqlite-database! write-database)
    (define write-connection
      (open-pos-sqlite-connection write-database 'read/write))
    (define write-filler (build-path constrained-directory "write.fill"))
    (fill-filesystem! write-filler)
    (ensure
     (fails?
      (lambda ()
        (db:query-exec
         write-connection
         "CREATE TABLE acceptance_enospc_probe (value BLOB NOT NULL)")))
     "SQLite reported success after the private filesystem was exhausted")
    (delete-file write-filler)
    (db:disconnect write-connection)
    (call-with-pos-sqlite-inspection-connection
     write-database
     (lambda (connection)
       (ensure
        (zero?
         (db:query-value
          connection
          "SELECT COUNT(*) FROM sqlite_schema WHERE name = 'acceptance_enospc_probe'"))
        "failed SQLite write left a schema object behind")))
    (ensure
     (sqlite-integrity-result-healthy?
      (integrity-check-pos-sqlite-database write-database))
     "database failed integrity validation after ENOSPC write")
    (ensure
     (sqlite-backup-validation-valid?
      (validate-pos-sqlite-backup write-database))
     "database failed current-schema validation after ENOSPC write")

    ;; A valid source larger than the private destination cannot complete
    ;; VACUUM INTO. The unpublished candidate must be cleaned and no final name
    ;; may appear.
    (define backup-source
      (build-path temporary-source-directory "backup-source.db"))
    (initialize-sqlite-database! backup-source)
    (define backup-source-connection
      (open-pos-sqlite-connection backup-source 'read/write))
    (db:query-exec backup-source-connection
                   "CREATE TABLE acceptance_padding (value BLOB NOT NULL)")
    (db:query-exec backup-source-connection
                   "INSERT INTO acceptance_padding (value) VALUES (zeroblob(1048576))")
    (db:disconnect backup-source-connection)
    (define backup-output
      (build-path constrained-directory "must-not-publish.db"))
    (ensure
     (fails?
      (lambda ()
        (create-pos-sqlite-backup! backup-source backup-output)))
     "oversized backup unexpectedly fit in the constrained filesystem")
    (ensure (not (file-exists? backup-output))
            "failed backup published a final file")
    (ensure (null? (partial-files constrained-directory))
            "handled backup ENOSPC left a partial candidate")
    (ensure
     (sqlite-backup-validation-valid?
      (validate-pos-sqlite-backup backup-source))
     "backup source was damaged by destination ENOSPC")

    ;; Support collection uses the same unpublished/atomic publication shape.
    ;; Fill the bounded filesystem again and require the final archive name to
    ;; stay absent.
    (define support-filler
      (build-path constrained-directory "support.fill"))
    (fill-filesystem! support-filler)
    (define support-output
      (build-path constrained-directory "must-not-publish.tar.gz"))
    (ensure
     (fails?
      (lambda ()
        (collect-pos-support-bundle!
         backup-source
         support-output
         #:platform-provider (lambda () (hasheq 'os_id "fedora"))
         #:package-provider (lambda () (hasheq 'name "grocery-pos-core"))
         #:service-provider (lambda () (hasheq 'ActiveState "active"))
         #:api-provider (lambda () (hasheq))
         #:storage-provider
         (lambda (_path)
           (hasheq 'total_bytes 524288
                   'used_bytes 524288
                   'available_bytes 0
                   'usage_percent 100)))))
     "support archive unexpectedly published on a full filesystem")
    (ensure (not (file-exists? support-output))
            "failed support collection published a final archive")
    (delete-file support-filler)

    (write-json
     (hasheq 'ok #t
             'filesystem_limit_bytes 524288
             'sqlite_write "failed_explicitly"
             'database_reopened #t
             'integrity "ok"
             'backup_final_published #f
             'support_final_published #f))
    (newline))
  (lambda ()
    (when (directory-exists? temporary-source-directory)
      (delete-directory/files temporary-source-directory))))
