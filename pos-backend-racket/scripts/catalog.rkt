#lang racket

(require (prefix-in db: db)
         racket/file
         "../pos/persistence/catalog-snapshot-codec.rkt"
         "../pos/persistence/sqlite-catalog.rkt"
         "../pos/runtime.rkt")

(provide run-catalog-cli)

(define usage
  (string-append
   "Usage:\n"
   "  catalog.rkt validate <catalog-file>\n"
   "  catalog.rkt activate <catalog-file> <database-path>\n"))

(define (print-summary output-port action summary)
  (fprintf
   output-port
   "Catalog ~a: items=~a active=~a inactive=~a barcodes=~a tax_categories=~a\n"
   action
   (catalog-snapshot-summary-item-count summary)
   (catalog-snapshot-summary-active-item-count summary)
   (catalog-snapshot-summary-inactive-item-count summary)
   (catalog-snapshot-summary-barcode-count summary)
   (catalog-snapshot-summary-tax-category-count summary)))

(define (load-snapshot catalog-file error-port)
  (define raw-bytes
    (with-handlers
        ([exn:fail?
          (lambda (exception)
            (fprintf error-port
                     "catalog-file-read-failed: ~a\n"
                     (exn-message exception))
            #f)])
      (file->bytes catalog-file)))
  (cond
    [(not raw-bytes) #f]
    [else
     (define result (json-bytes->catalog-snapshot raw-bytes))
     (cond
       [(catalog-snapshot-decode-success? result)
        (catalog-snapshot-decode-success-snapshot result)]
       [else
        (fprintf
         error-port
         "~a: ~a\n"
         (catalog-snapshot-decode-failure-code result)
         (catalog-snapshot-decode-failure-detail result))
        #f])]))

(define (activate-snapshot snapshot database-path error-port)
  (with-handlers
      ([exn:fail?
        (lambda (exception)
          (fprintf error-port
                   "catalog-activation-failed: ~a\n"
                   (exn-message exception))
          #f)])
    (define resolved-database-path
      (path->complete-path database-path))
    ;; Use the same parent-directory check and canonical migration sequence as
    ;; production startup. Activation never creates an arbitrary parent tree.
    (initialize-sqlite-database! resolved-database-path)
    (define connection
      (db:sqlite3-connect
       #:database resolved-database-path
       #:mode 'read/write))
    (dynamic-wind
      void
      (lambda ()
        (activate-catalog-snapshot! connection snapshot))
      (lambda ()
        (when (db:connected? connection)
          (db:disconnect connection))))))

(define (run-catalog-cli
         arguments
         #:output-port [output-port (current-output-port)]
         #:error-port [error-port (current-error-port)])
  (unless (vector? arguments)
    (raise-argument-error 'run-catalog-cli "vector?" arguments))
  (unless (output-port? output-port)
    (raise-argument-error 'run-catalog-cli "output-port?" output-port))
  (unless (output-port? error-port)
    (raise-argument-error 'run-catalog-cli "output-port?" error-port))

  (match (vector->list arguments)
    [(list "validate" catalog-file)
     (define snapshot (load-snapshot catalog-file error-port))
     (if snapshot
         (begin
           (print-summary
            output-port
            "valid"
            (summarize-catalog-snapshot snapshot))
           0)
         1)]
    [(list "activate" catalog-file database-path)
     ;; Complete JSON/staged validation deliberately precedes all database
     ;; initialization and mutation.
     (define snapshot (load-snapshot catalog-file error-port))
     (cond
       [(not snapshot) 1]
       [else
        (define summary
          (activate-snapshot snapshot database-path error-port))
        (if summary
            (begin
              (print-summary output-port "activated" summary)
              0)
            1)])]
    [_
     (display usage error-port)
     2]))

(module+ main
  (exit (run-catalog-cli (current-command-line-arguments))))
