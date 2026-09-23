#lang racket

(require json
         racket/file
         rackunit
         "../pos/runtime.rkt"
         "../scripts/database-maintenance.rkt")

(define (call-with-cli-directory procedure)
  (define directory
    (make-temporary-file "database-maintenance-cli-~a" 'directory))
  (dynamic-wind
    void
    (lambda () (procedure directory))
    (lambda () (delete-directory/files directory))))

(define (invoke arguments)
  (define output (open-output-string))
  (define error-output (open-output-string))
  (define status
    (run-database-maintenance-cli
     arguments
     #:output-port output
     #:error-port error-output))
  (values status
          (get-output-string output)
          (get-output-string error-output)))

(define (parse-single-json-line value)
  (string->jsexpr value))

(module+ test
  (test-case "info emits stable structural JSON without database contents"
    (call-with-cli-directory
     (lambda (directory)
       (define database-path (build-path directory "pos.sqlite"))
       (initialize-sqlite-database! database-path)
       (define-values (status output error-output)
         (invoke (vector "info" (path->string database-path))))
       (check-equal? status 0)
       (check-equal? error-output "")
       (define result (parse-single-json-line output))
       (check-equal? (hash-ref result 'ok) #t)
       (check-equal? (hash-ref result 'operation) "info")
       (check-equal? (hash-ref result 'journal_mode) "wal")
       (define migrations (hash-ref result 'migrations))
       (check-equal? (hash-ref migrations 'status) "current")
       (check-equal? (hash-ref migrations 'highest_applied_version) 10)
       (check-equal? (hash-ref migrations 'current_supported_version) 10)
       (check-equal? (length (hash-ref migrations 'history)) 10)
       ;; Canonical migration names are structural metadata; table rows and
       ;; transaction payload fields are not part of diagnostic output.
       (check-false (regexp-match? #rx"event_json|command_json" output)))))

  (test-case "quick and full checks emit health JSON"
    (call-with-cli-directory
     (lambda (directory)
       (define database-path (build-path directory "pos.sqlite"))
       (initialize-sqlite-database! database-path)

       (define-values (quick-status quick-output quick-error)
         (invoke (vector "quick-check" (path->string database-path))))
       (check-equal? quick-status 0)
       (check-equal? quick-error "")
       (define quick (parse-single-json-line quick-output))
       (check-equal? (hash-ref quick 'healthy) #t)
       (check-equal? (hash-ref quick 'messages) '("ok"))

       (define-values (full-status full-output full-error)
         (invoke (vector "integrity-check" (path->string database-path))))
       (check-equal? full-status 0)
       (check-equal? full-error "")
       (define full (parse-single-json-line full-output))
       (check-equal? (hash-ref full 'healthy) #t)
       (check-equal? (hash-ref full 'messages) '("ok"))
       (check-equal? (hash-ref full 'foreign_key_violation_count) 0))))

  (test-case "backup and backup-validate publish and verify one explicit output"
    (call-with-cli-directory
     (lambda (directory)
       (define database-path (build-path directory "pos.sqlite"))
       (define backup-path (build-path directory "backup.sqlite"))
       (initialize-sqlite-database! database-path)

       (define-values (backup-status backup-output backup-error)
         (invoke (vector "backup"
                         (path->string database-path)
                         (path->string backup-path))))
       (check-equal? backup-status 0)
       (check-equal? backup-error "")
       (check-true (file-exists? backup-path))
       (define backup-result (parse-single-json-line backup-output))
       (check-equal? (hash-ref backup-result 'ok) #t)
       (check-equal? (hash-ref backup-result 'operation) "backup")
       (check-equal? (hash-ref backup-result 'published_path)
                     (path->string (path->complete-path backup-path)))

       (define-values (validate-status validate-output validate-error)
         (invoke (vector "backup-validate" (path->string backup-path))))
       (check-equal? validate-status 0)
       (check-equal? validate-error "")
       (define validation (parse-single-json-line validate-output))
       (check-equal? (hash-ref validation 'valid) #t)
       (check-equal? (hash-ref validation 'migration_status) "current")
       (check-equal? (hash-ref validation 'foreign_key_violation_count) 0))))

  (test-case "failed operations return nonzero JSON errors and never create a DB"
    (call-with-cli-directory
     (lambda (directory)
       (define missing-path (build-path directory "missing.sqlite"))
       (define-values (info-status info-output info-error)
         (invoke (vector "info" (path->string missing-path))))
       (check-equal? info-status 1)
       (check-equal? info-error "")
       (check-equal?
        (hash-ref (parse-single-json-line info-output) 'ok)
        #f)
       (check-false (file-exists? missing-path))

       (define-values (check-status check-output check-error)
         (invoke (vector "quick-check" (path->string missing-path))))
       (check-equal? check-status 1)
       (check-equal? check-output "")
       (define failure (parse-single-json-line check-error))
       (check-equal? (hash-ref failure 'ok) #f)
       (check-equal?
        (hash-ref (hash-ref failure 'error) 'code)
        "database_quick_check_failed")
       (check-false (file-exists? missing-path)))))

  (test-case "unsupported command shape returns usage"
    (define-values (status output error-output)
      (invoke (vector "backup" "only-source.sqlite")))
    (check-equal? status 2)
    (check-equal? output "")
    (check-regexp-match #rx"Usage:" error-output)))
