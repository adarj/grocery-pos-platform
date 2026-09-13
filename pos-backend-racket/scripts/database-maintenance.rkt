#lang racket

(require json
         "../pos/persistence/sqlite-maintenance.rkt")

(provide run-database-maintenance-cli)

(define usage
  (string-append
   "Usage:\n"
   "  database-maintenance.rkt info <database-path>\n"
   "  database-maintenance.rkt quick-check <database-path>\n"
   "  database-maintenance.rkt integrity-check <database-path>\n"
   "  database-maintenance.rkt backup <database-path> <output-path>\n"
   "  database-maintenance.rkt backup-validate <backup-path>\n"))

(define (write-json-line value output-port)
  (write-json value output-port)
  (newline output-port))

(define (optional-number value)
  (if (number? value) value (json-null)))

(define (optional-string value)
  (if (string? value) value (json-null)))

(define (history->jsexpr history)
  (if history
      (for/list ([row (in-list history)])
        (hasheq 'version (vector-ref row 0)
                'name (vector-ref row 1)))
      (json-null)))

(define (status->string value)
  (symbol->string value))

(define (database-info->jsexpr info)
  (hasheq
   'ok (sqlite-database-info-read-only-openable? info)
   'operation "info"
   'database_path (path->string (sqlite-database-info-path info))
   'file_exists (sqlite-database-info-file-exists? info)
   'regular_file (sqlite-database-info-regular-file? info)
   'read_only_openable (sqlite-database-info-read-only-openable? info)
   'journal_mode
   (optional-string (sqlite-database-info-journal-mode info))
   'migrations
   (hasheq
    'status
    (status->string (sqlite-database-info-migration-status info))
    'history
    (history->jsexpr (sqlite-database-info-migration-history info))
    'highest_applied_version
    (optional-number
     (sqlite-database-info-highest-applied-migration-version info))
    'current_supported_version
    (sqlite-database-info-current-supported-migration-version info)
    'schema_valid
    (sqlite-database-info-schema-valid? info))
   'storage
   (hasheq
    'page_size (optional-number (sqlite-database-info-page-size info))
    'page_count (optional-number (sqlite-database-info-page-count info))
    'freelist_count
    (optional-number (sqlite-database-info-freelist-count info))
    'main_file_size
    (optional-number (sqlite-database-info-main-file-size info))
    'wal
    (hasheq
     'exists (sqlite-database-info-wal-file-exists? info)
     'size (optional-number (sqlite-database-info-wal-file-size info)))
    'shm
    (hasheq
     'exists (sqlite-database-info-shm-file-exists? info)
     'size (optional-number (sqlite-database-info-shm-file-size info))))))

(define (quick-result->jsexpr result)
  (hasheq
   'ok (sqlite-check-result-healthy? result)
   'operation "quick-check"
   'healthy (sqlite-check-result-healthy? result)
   'messages (sqlite-check-result-messages result)))

(define (integrity-result->jsexpr result)
  (hasheq
   'ok (sqlite-integrity-result-healthy? result)
   'operation "integrity-check"
   'healthy (sqlite-integrity-result-healthy? result)
   'messages (sqlite-integrity-result-messages result)
   'foreign_key_violation_count
   (length (sqlite-integrity-result-foreign-key-violations result))))

(define (backup-validation-failed-checks validation)
  (define failures '())
  (unless (and (sqlite-backup-validation-file-size validation)
               (positive? (sqlite-backup-validation-file-size validation)))
    (set! failures (append failures '("regular_nonempty_file"))))
  (define integrity
    (sqlite-backup-validation-integrity-result validation))
  (unless (and integrity
               (sqlite-integrity-result-healthy? integrity))
    (set! failures (append failures '("integrity_or_foreign_keys"))))
  (unless (eq? (sqlite-backup-validation-migration-status validation)
               'current)
    (set! failures (append failures '("current_migration_history"))))
  (unless (sqlite-backup-validation-schema-valid? validation)
    (set! failures (append failures '("pos_schema_validation"))))
  failures)

(define (backup-validation->jsexpr validation)
  (define integrity
    (sqlite-backup-validation-integrity-result validation))
  (hasheq
   'ok (sqlite-backup-validation-valid? validation)
   'operation "backup-validate"
   'valid (sqlite-backup-validation-valid? validation)
   'file_size
   (optional-number (sqlite-backup-validation-file-size validation))
   'integrity_messages
   (if integrity
       (sqlite-integrity-result-messages integrity)
       (json-null))
   'foreign_key_violation_count
   (if integrity
       (length (sqlite-integrity-result-foreign-key-violations integrity))
       (json-null))
   'migration_status
   (status->string (sqlite-backup-validation-migration-status validation))
   'migration_history
   (history->jsexpr (sqlite-backup-validation-migration-history validation))
   'schema_valid
   (sqlite-backup-validation-schema-valid? validation)
   'failed_checks
   (backup-validation-failed-checks validation)))

(define (write-operation-failure code message error-port)
  (write-json-line
   (hasheq
    'ok #f
    'error (hasheq 'code code 'message message))
   error-port)
  1)

(define (run-checked-operation code message error-port procedure)
  (with-handlers
      ([exn:fail?
        (lambda (_exception)
          ;; The CLI contract is deliberately stable and does not serialize
          ;; arbitrary exception internals or database contents.
          (write-operation-failure code message error-port))])
    (procedure)))

(define (run-database-maintenance-cli
         arguments
         #:output-port [output-port (current-output-port)]
         #:error-port [error-port (current-error-port)])
  (unless (vector? arguments)
    (raise-argument-error 'run-database-maintenance-cli "vector?" arguments))
  (unless (output-port? output-port)
    (raise-argument-error
     'run-database-maintenance-cli "output-port?" output-port))
  (unless (output-port? error-port)
    (raise-argument-error
     'run-database-maintenance-cli "output-port?" error-port))

  (match (vector->list arguments)
    [(list "info" database-path)
     (run-checked-operation
      "database_info_failed"
      "Database inspection failed."
      error-port
      (lambda ()
        (define info (inspect-pos-sqlite-database database-path))
        (write-json-line (database-info->jsexpr info) output-port)
        (if (sqlite-database-info-read-only-openable? info) 0 1)))]
    [(list "quick-check" database-path)
     (run-checked-operation
      "database_quick_check_failed"
      "Database quick check could not be completed."
      error-port
      (lambda ()
        (define result
          (quick-check-pos-sqlite-database database-path))
        (write-json-line (quick-result->jsexpr result) output-port)
        (if (sqlite-check-result-healthy? result) 0 1)))]
    [(list "integrity-check" database-path)
     (run-checked-operation
      "database_integrity_check_failed"
      "Database integrity check could not be completed."
      error-port
      (lambda ()
        (define result
          (integrity-check-pos-sqlite-database database-path))
        (write-json-line (integrity-result->jsexpr result) output-port)
        (if (sqlite-integrity-result-healthy? result) 0 1)))]
    [(list "backup" database-path output-path)
     (run-checked-operation
      "database_backup_failed"
      "Database backup was not published."
      error-port
      (lambda ()
        (define created
          (create-pos-sqlite-backup! database-path output-path))
        (write-json-line
         (hasheq
          'ok #t
          'operation "backup"
          'published_path
          (path->string (sqlite-backup-created-path created)))
         output-port)
        0))]
    [(list "backup-validate" backup-path)
     (run-checked-operation
      "database_backup_validation_failed"
      "Backup validation could not be completed."
      error-port
      (lambda ()
        (define validation
          (validate-pos-sqlite-backup backup-path))
        (write-json-line
         (backup-validation->jsexpr validation)
         output-port)
        (if (sqlite-backup-validation-valid? validation) 0 1)))]
    [_
     (display usage error-port)
     2]))

(module+ main
  (exit
   (run-database-maintenance-cli
    (current-command-line-arguments))))
