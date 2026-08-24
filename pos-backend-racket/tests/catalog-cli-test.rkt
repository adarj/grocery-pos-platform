#lang racket

(require (prefix-in db: db)
         racket/file
         rackunit
         "../pos/domain/catalog-item.rkt"
         "../pos/domain/money.rkt"
         "../pos/persistence/sqlite-catalog.rkt"
         "../scripts/catalog.rkt")

(define valid-catalog-json
  #<<JSON
{
  "schema_version": 1,
  "items": [
    {
      "item_id": "item-apples",
      "description": "Test Apples",
      "unit_price_minor_units": 199,
      "active": true
    }
  ],
  "barcodes": [
    {
      "barcode": "049000001234",
      "item_id": "item-apples"
    }
  ]
}
JSON
  )

(define (call-with-cli-files procedure)
  (define directory
    (make-temporary-file "catalog-cli-~a" 'directory))
  (define catalog-path (build-path directory "catalog.json"))
  (define invalid-path (build-path directory "invalid.json"))
  (define database-path (build-path directory "pos.db"))
  (dynamic-wind
    void
    (lambda ()
      (display-to-file valid-catalog-json catalog-path #:exists 'truncate)
      (display-to-file "{not-json" invalid-path #:exists 'truncate)
      (procedure catalog-path invalid-path database-path))
    (lambda () (delete-directory/files directory))))

(define (invoke arguments)
  (define output (open-output-string))
  (define error-output (open-output-string))
  (define status
    (run-catalog-cli arguments
                     #:output-port output
                     #:error-port error-output))
  (values status
          (get-output-string output)
          (get-output-string error-output)))

(module+ test
  (test-case "validate prints concise summary and performs no database work"
    (call-with-cli-files
     (lambda (catalog-path _invalid-path database-path)
       (define-values (status output error-output)
         (invoke (vector "validate" (path->string catalog-path))))

       (check-equal? status 0)
       (check-regexp-match #rx"items=1" output)
       (check-regexp-match #rx"active=1" output)
       (check-regexp-match #rx"inactive=0" output)
       (check-regexp-match #rx"barcodes=1" output)
       (check-regexp-match #rx"tax_categories=1" output)
       (check-equal? error-output "")
       (check-false (file-exists? database-path)))))

  (test-case "invalid validation reports stable reason without a stack trace"
    (call-with-cli-files
     (lambda (_catalog-path invalid-path _database-path)
       (define-values (status output error-output)
         (invoke (vector "validate" (path->string invalid-path))))

       (check-equal? status 1)
       (check-equal? output "")
       (check-regexp-match #rx"malformed-json" error-output)
       (check-false (regexp-match? #rx"context\\.\\.\\." error-output)))))

  (test-case "activate writes through normal migration to explicit database"
    (call-with-cli-files
     (lambda (catalog-path _invalid-path database-path)
       (define-values (status output error-output)
         (invoke (vector "activate"
                         (path->string catalog-path)
                         (path->string database-path))))

       (check-equal? status 0)
       (check-regexp-match #rx"activated" output)
       (check-regexp-match #rx"items=1" output)
       (check-equal? error-output "")
       (check-true (file-exists? database-path))

       (define connection
         (db:sqlite3-connect #:database database-path #:mode 'read/write))
       (dynamic-wind
         void
         (lambda ()
           (define item
             (lookup-catalog-item-by-barcode
              connection "049000001234"))
           (check-equal? (catalog-item-description item) "Test Apples")
           (check-equal? (catalog-item-unit-price item) (money 199)))
         (lambda () (db:disconnect connection))))))

  (test-case "invalid activation does not create or mutate target database"
    (call-with-cli-files
     (lambda (catalog-path invalid-path database-path)
       (define-values (initial-status _initial-output _initial-error)
         (invoke (vector "activate"
                         (path->string catalog-path)
                         (path->string database-path))))
       (check-equal? initial-status 0)
       (define bytes-before (file->bytes database-path))

       (define-values (status output error-output)
         (invoke (vector "activate"
                         (path->string invalid-path)
                         (path->string database-path))))
       (check-equal? status 1)
       (check-equal? output "")
       (check-regexp-match #rx"malformed-json" error-output)
       (check-equal? (file->bytes database-path) bytes-before))))

  (test-case "CLI rejects unsupported argument shapes"
    (define-values (status output error-output)
      (invoke (vector "activate" "only-a-catalog-file")))
    (check-equal? status 2)
    (check-equal? output "")
    (check-regexp-match #rx"Usage:" error-output)))
