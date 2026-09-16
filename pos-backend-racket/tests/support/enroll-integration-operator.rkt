#lang racket

(require (prefix-in db: db)
         "../../pos/application/operator-service.rkt"
         "../../pos/persistence/pos-database-migrations.rkt"
         "../../pos/persistence/sqlite-connection.rkt")

;; This helper is test-only. The operator ID and isolated database path may be
;; command arguments, but the PIN is deliberately read from stdin so even the
;; real-process integration fixture never places credential material in argv.
(define (main arguments)
  (match (vector->list arguments)
    [(list database-path operator-id)
     (define pin (read-line (current-input-port) 'any))
     (when (eof-object? pin)
       (error 'enroll-integration-operator "PIN input is required"))
     (define connection (open-pos-sqlite-connection database-path 'read/write))
     (dynamic-wind
       void
       (lambda ()
         (validate-pos-database-schema! connection #:require-current? #t)
         (define result
           (operator-service-enroll-pin
            (make-operator-service connection)
            operator-id
            pin))
         (unless (operator-pin-enrollment-succeeded? result)
           (error
            'enroll-integration-operator
            "credential enrollment failed")))
       (lambda () (db:disconnect connection)))]
    [_
     (error
      'enroll-integration-operator
      "expected DATABASE_PATH and OPERATOR_ID arguments")]))

(module+ main
  (main (current-command-line-arguments)))
