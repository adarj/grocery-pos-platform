#lang racket

(require (prefix-in db: db)
         ffi/unsafe
         file/sha1
         json
         racket/random
         "../pos/domain/security-audit-event.rkt"
         "../pos/persistence/pos-database-migrations.rkt"
         "../pos/persistence/security-audit-store.rkt"
         "../pos/persistence/sqlite-connection.rkt")

(provide run-security-audit-cli)

(define canonical-database-path "/var/lib/grocery-pos/pos.db")
(define system-geteuid
  (get-ffi-obj "geteuid" (ffi-lib #f) (_fun -> _uint)))

(define (write-json-line value port)
  (write-json value port)
  (newline port))

(define (failure code error-port)
  (write-json-line
   (hasheq 'ok #f
           'error (hasheq 'code code
                          'message "Security audit inspection could not be completed."))
   error-port)
  1)

(define (parse-natural text)
  (define value (string->number text))
  (and (exact-integer? value) (>= value 0) value))

(define (parse-positive-bounded text)
  (define value (string->number text))
  (and (exact-integer? value) (<= 1 value 1000) value))

(define (parse-request arguments)
  (match (vector->list arguments)
    [(list "verify") (list 'verify 0 1)]
    [(list "list") (list 'list 0 100)]
    [(list "list" after-text limit-text)
     (define after (parse-natural after-text))
     (define limit (parse-positive-bounded limit-text))
     (and after limit (list 'list after limit))]
    [_ #f]))

(define (run-security-audit-cli
         arguments
         #:database-path [database-path canonical-database-path]
         #:effective-user-id [effective-user-id system-geteuid]
         #:output-port [output-port (current-output-port)]
         #:error-port [error-port (current-error-port)]
         #:append-audit! [append-audit! #f])
  (unless (vector? arguments)
    (raise-argument-error 'run-security-audit-cli "vector?" arguments))
  (cond
    [(not (zero? (effective-user-id)))
     (failure "not_privileged" error-port)]
    [else
     (define request (parse-request arguments))
     (cond
       [(not request) (failure "invalid_audit_command" error-port)]
       [else
        (with-handlers ([exn:fail?
                         (lambda (_exception)
                           (failure "audit_unavailable" error-port))])
          (define connection
            (open-pos-sqlite-connection database-path 'read/write))
          (dynamic-wind
            void
            (lambda ()
              (validate-pos-database-schema! connection #:require-current? #t)
              (define verified (verify-security-audit-ledger connection))
              (unless (security-audit-ledger-valid? verified)
                (error 'run-security-audit-cli "audit integrity failed"))
              (define operation (first request))
              (define after (second request))
              (define limit (third request))
              (define access-event
                (audit-accessed-event operation after limit))
              (define access-sequence
                (if append-audit!
                    (append-audit! connection access-event)
                    (append-security-audit-event!
                     connection access-event
                     #:source-kind 'root_cli
                     #:source-instance-id
                     (string-append
                      "audit_root_cli_"
                      (bytes->hex-string (crypto-random-bytes 16)))
                     #:occurred-at-epoch-ms
                     (inexact->exact
                      (floor (current-inexact-milliseconds))))))
              (unless (and (exact-integer? access-sequence)
                           (> access-sequence
                              (security-audit-ledger-valid-event-count verified)))
                (error 'run-security-audit-cli "audit access append did not advance sequence"))
              (case operation
                [(verify)
                 (write-json-line
                  (hasheq 'ok #t 'status "valid"
                          'event_count
                          (security-audit-ledger-valid-event-count verified)
                          'verified_through_sequence
                          (security-audit-ledger-valid-event-count verified)
                          'access_event_sequence access-sequence)
                  output-port)]
                [(list)
                 (for ([record
                        (in-list
                         (list-security-audit-events connection after limit))])
                   (write-json-line record output-port))])
              0)
            (lambda () (db:disconnect connection))))])]))

(module+ main
  (exit (run-security-audit-cli (current-command-line-arguments))))
