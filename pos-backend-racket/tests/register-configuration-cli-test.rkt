#lang racket

(require (prefix-in db: db)
         racket/file
         rackunit
         "../scripts/register-configuration.rkt")

(define valid-configuration-json
  #<<JSON
{
  "schema_version": 1,
  "register": {
    "register_id": "register-front-01",
    "display_name": "Front Register 1"
  },
  "cashiers": [
    {
      "cashier_id": "cashier-alice",
      "display_name": "Alice",
      "active": true
    }
  ]
}
JSON
  )

(define (call-with-cli-files procedure)
  (define directory
    (make-temporary-file "register-configuration-cli-~a" 'directory))
  (define configuration-path (build-path directory "register.json"))
  (define invalid-path (build-path directory "invalid.json"))
  (define database-path (build-path directory "pos.db"))
  (dynamic-wind
    void
    (lambda ()
      (display-to-file
       valid-configuration-json configuration-path #:exists 'truncate)
      (display-to-file "{not-json" invalid-path #:exists 'truncate)
      (procedure configuration-path invalid-path database-path))
    (lambda () (delete-directory/files directory))))

(define (invoke arguments)
  (define output (open-output-string))
  (define error-output (open-output-string))
  (define status
    (run-register-configuration-cli
     arguments
     #:output-port output
     #:error-port error-output))
  (values status
          (get-output-string output)
          (get-output-string error-output)))

(module+ test
  (test-case "validate reports a concise summary without creating a database"
    (call-with-cli-files
     (lambda (configuration-path _invalid-path database-path)
       (define-values (status output error-output)
         (invoke
          (vector "validate" (path->string configuration-path))))
       (check-equal? status 0)
       (check-regexp-match #rx"register=register-front-01" output)
       (check-regexp-match #rx"cashiers=1" output)
       (check-regexp-match #rx"active=1" output)
       (check-regexp-match #rx"inactive=0" output)
       (check-equal? error-output "")
       (check-false (file-exists? database-path)))))

  (test-case "invalid validation reports a stable safe reason"
    (call-with-cli-files
     (lambda (_configuration-path invalid-path _database-path)
       (define-values (status output error-output)
         (invoke (vector "validate" (path->string invalid-path))))
       (check-equal? status 1)
       (check-equal? output "")
       (check-regexp-match #rx"malformed-json" error-output)
       (check-false (regexp-match? #rx"context\\.\\.\\." error-output)))))

  (test-case "activate migrates and writes only the explicit database"
    (call-with-cli-files
     (lambda (configuration-path _invalid-path database-path)
       (define-values (status output error-output)
         (invoke
          (vector "activate"
                  (path->string configuration-path)
                  (path->string database-path))))
       (check-equal? status 0)
       (check-regexp-match #rx"activated" output)
       (check-equal? error-output "")
       (check-true (file-exists? database-path))
       (define connection
         (db:sqlite3-connect #:database database-path #:mode 'read/write))
       (dynamic-wind
         void
         (lambda ()
           (check-equal?
            (db:query-value connection "PRAGMA journal_mode")
            "wal")
           (check-equal?
            (db:query-row
             connection
             "SELECT register_id, display_name FROM register_configuration")
            #("register-front-01" "Front Register 1"))
           (check-equal?
            (db:query-row
             connection
             "SELECT cashier_id, display_name, active FROM cashiers")
            #("cashier-alice" "Alice" 1)))
         (lambda () (db:disconnect connection))))))

  (test-case "invalid activation leaves an existing database unchanged"
    (call-with-cli-files
     (lambda (configuration-path invalid-path database-path)
       (define-values (first-status _first-output _first-error)
         (invoke
          (vector "activate"
                  (path->string configuration-path)
                  (path->string database-path))))
       (check-equal? first-status 0)
       (define bytes-before (file->bytes database-path))
       (define-values (status output error-output)
         (invoke
          (vector "activate"
                  (path->string invalid-path)
                  (path->string database-path))))
       (check-equal? status 1)
       (check-equal? output "")
       (check-regexp-match #rx"malformed-json" error-output)
       (check-equal? (file->bytes database-path) bytes-before))))

  (test-case "unsupported argument shape returns usage"
    (define-values (status output error-output)
      (invoke (vector "activate" "only-a-configuration-file")))
    (check-equal? status 2)
    (check-equal? output "")
    (check-regexp-match #rx"Usage:" error-output)))
