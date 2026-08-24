#lang racket

(require (prefix-in db: db)
         "../persistence/sqlite-register-operations.rkt")

(provide make-register-operations-service
         register-operations-service?
         register-operations-load-context
         register-operations-list-active-cashiers
         register-operations-open-shift
         register-operations-close-shift)

(struct register-operations-service
  (connection current-epoch-ms generate-shift-id)
  #:transparent)

(define (make-register-operations-service
         connection
         #:current-epoch-ms current-epoch-ms
         #:generate-shift-id generate-shift-id)
  (define who 'make-register-operations-service)
  (unless (db:connection? connection)
    (raise-argument-error who "connection?" connection))
  (for ([value (in-list (list current-epoch-ms generate-shift-id))]
        [name (in-list '(current-epoch-ms generate-shift-id))])
    (unless (and (procedure? value) (procedure-arity-includes? value 0))
      (raise-arguments-error
       who "expected a zero-argument procedure" (symbol->string name) value)))
  (register-operations-service
   connection current-epoch-ms generate-shift-id))

(define (check-service who service)
  (unless (register-operations-service? service)
    (raise-argument-error who "register-operations-service?" service)))

(define (register-operations-load-context service)
  (check-service 'register-operations-load-context service)
  (load-register-context
   (register-operations-service-connection service)))

(define (register-operations-list-active-cashiers service)
  (check-service 'register-operations-list-active-cashiers service)
  (load-active-cashiers
   (register-operations-service-connection service)))

(define (register-operations-open-shift service cashier-id)
  (check-service 'register-operations-open-shift service)
  (open-register-shift!
   (register-operations-service-connection service)
   cashier-id
   (register-operations-service-current-epoch-ms service)
   (register-operations-service-generate-shift-id service)))

(define (register-operations-close-shift service shift-id)
  (check-service 'register-operations-close-shift service)
  (close-register-shift!
   (register-operations-service-connection service)
   shift-id
   (register-operations-service-current-epoch-ms service)))
