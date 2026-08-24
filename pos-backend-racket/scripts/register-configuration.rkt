#lang racket

(require (prefix-in db: db)
         racket/file
         "../pos/persistence/operational-configuration-snapshot-codec.rkt"
         "../pos/persistence/sqlite-connection.rkt"
         "../pos/persistence/sqlite-register-operations.rkt"
         "../pos/runtime.rkt")

(provide run-register-configuration-cli)

(define usage
  (string-append
   "Usage:\n"
   "  register-configuration.rkt validate <configuration-file>\n"
   "  register-configuration.rkt activate <configuration-file> <database-path>\n"))

(define (print-summary output-port action snapshot)
  (define register
    (operational-configuration-snapshot-register snapshot))
  (define summary (summarize-operational-configuration snapshot))
  (fprintf
   output-port
   "Register configuration ~a: register=~a cashiers=~a active=~a inactive=~a\n"
   action
   (operational-configuration-register-register-id register)
   (operational-configuration-summary-cashier-count summary)
   (operational-configuration-summary-active-cashier-count summary)
   (operational-configuration-summary-inactive-cashier-count summary)))

(define (load-snapshot path error-port)
  (define bytes
    (with-handlers
        ([exn:fail?
          (lambda (exception)
            (fprintf error-port
                     "configuration-file-read-failed: ~a\n"
                     (exn-message exception))
            #f)])
      (file->bytes path)))
  (and bytes
       (let ([decoded
              (json-bytes->operational-configuration-snapshot bytes)])
         (cond
           [(operational-configuration-decode-success? decoded)
            (operational-configuration-decode-success-snapshot decoded)]
           [else
            (fprintf error-port
                     "~a: ~a\n"
                     (operational-configuration-decode-failure-code decoded)
                     (operational-configuration-decode-failure-detail decoded))
            #f]))))

(define (activate snapshot database-path error-port)
  (with-handlers
      ([exn:fail?
        (lambda (exception)
          (fprintf error-port
                   "register-configuration-activation-failed: ~a\n"
                   (exn-message exception))
          #f)])
    (define resolved (path->complete-path database-path))
    (initialize-sqlite-database! resolved)
    (define connection
      (open-pos-sqlite-connection resolved 'read/write))
    (dynamic-wind
      void
      (lambda ()
        (define result
          (activate-operational-configuration! connection snapshot))
        (cond
          [(operational-configuration-activation-succeeded? result) result]
          [(operational-configuration-activation-rejected? result)
           (fprintf error-port
                    "register-configuration-activation-rejected: ~a\n"
                    (operational-configuration-activation-rejected-code result))
           #f]
          [else
           (error 'activate "unsupported activation result: ~e" result)]))
      (lambda ()
        (when (db:connected? connection)
          (db:disconnect connection))))))

(define (run-register-configuration-cli
         arguments
         #:output-port [output-port (current-output-port)]
         #:error-port [error-port (current-error-port)])
  (match (vector->list arguments)
    [(list "validate" configuration-file)
     (define snapshot (load-snapshot configuration-file error-port))
     (if snapshot
         (begin (print-summary output-port "valid" snapshot) 0)
         1)]
    [(list "activate" configuration-file database-path)
     (define snapshot (load-snapshot configuration-file error-port))
     (if (and snapshot (activate snapshot database-path error-port))
         (begin (print-summary output-port "activated" snapshot) 0)
         1)]
    [_
     (display usage error-port)
     2]))

(module+ main
  (exit
   (run-register-configuration-cli
    (current-command-line-arguments))))
