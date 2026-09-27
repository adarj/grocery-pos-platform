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
    [(list* database-path operator-role-parts)
     (unless (and (positive? (length operator-role-parts))
                  (even? (length operator-role-parts)))
       (error
        'enroll-integration-operator
        "expected one or more OPERATOR_ID ROLE pairs"))
     (define pin (read-line (current-input-port) 'any))
     (when (eof-object? pin)
       (error 'enroll-integration-operator "PIN input is required"))
     (define connection (open-pos-sqlite-connection database-path 'read/write))
     (dynamic-wind
       void
       (lambda ()
         (validate-pos-database-schema! connection #:require-current? #t)
         (define service (make-operator-service connection))
         (for ([pair (in-slice 2 operator-role-parts)])
           (define operator-id (first pair))
           (define role-text (second pair))
           (define result
             (operator-service-enroll-pin service operator-id pin))
           (unless (operator-pin-enrollment-succeeded? result)
             (error
              'enroll-integration-operator
              "credential enrollment failed"))
           (operator-service-set-role
            service operator-id (string->symbol role-text))))
       (lambda () (db:disconnect connection)))]
    [_
     (error
      'enroll-integration-operator
      "expected DATABASE_PATH and one or more OPERATOR_ID ROLE pairs")]))

(module+ main
  (main (current-command-line-arguments)))
