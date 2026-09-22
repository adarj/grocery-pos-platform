#lang racket

(require (prefix-in db: db)
         "authentication-service.rkt"
         "../domain/register-operations.rkt"
         "../domain/shift-cash-accountability.rkt"
         "../persistence/sqlite-register-operations.rkt"
         "../persistence/sqlite-shift-cash-accountability.rkt"
         "../security/authorization-policy.rkt")

(provide make-register-operations-service
         register-operations-service?
         register-operations-load-context
         register-operations-list-active-cashiers
         register-operations-open-shift
         register-operations-close-shift
         register-operations-load-cash-summary
         (struct-out register-cash-summary-limited)
         (struct-out register-cash-summary-full)
         (struct-out register-cash-summary-not-found)
         (struct-out register-cash-summary-unavailable)
         (struct-out register-cash-summary-authorization-denied))

(struct register-cash-summary-limited (shift-id status) #:transparent)
(struct register-cash-summary-full (summary) #:transparent)
(struct register-cash-summary-not-found () #:transparent)
(struct register-cash-summary-unavailable () #:transparent)
(struct register-cash-summary-authorization-denied () #:transparent)

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

(define (check-principal who principal)
  (unless (authenticated-operator? principal)
    (raise-argument-error who "authenticated-operator?" principal)))

(define (register-operations-load-context service)
  (check-service 'register-operations-load-context service)
  (load-register-context
   (register-operations-service-connection service)))

(define (register-operations-list-active-cashiers service)
  (check-service 'register-operations-list-active-cashiers service)
  (load-active-cashiers
   (register-operations-service-connection service)))

(define (register-operations-open-shift service principal opening-cash)
  (check-service 'register-operations-open-shift service)
  (check-principal 'register-operations-open-shift principal)
  (if (operator-role-authorized?
       (authenticated-operator-role principal) 'shift.open.own)
      (open-register-shift!
       (register-operations-service-connection service)
       (authenticated-operator-operator-id principal)
       opening-cash
       (register-operations-service-current-epoch-ms service)
       (register-operations-service-generate-shift-id service))
      (register-shift-open-rejected 'authorization-denied)))

(define (register-operations-close-shift service principal shift-id counted-cash)
  (check-service 'register-operations-close-shift service)
  (check-principal 'register-operations-close-shift principal)
  (close-register-shift!
   (register-operations-service-connection service)
   shift-id
   counted-cash
   (register-operations-service-current-epoch-ms service)
   (authenticated-operator-operator-id principal)
   (authenticated-operator-role principal)))

(define (full-summary-result connection shift-id)
  (define result (load-shift-cash-summary connection shift-id))
  (cond
    [(shift-cash-summary-found? result)
     (register-cash-summary-full
      (shift-cash-summary-found-summary result))]
    [else (register-cash-summary-unavailable)]))

(define (register-operations-load-cash-summary service principal shift-id)
  (check-service 'register-operations-load-cash-summary service)
  (check-principal 'register-operations-load-cash-summary principal)
  (define connection (register-operations-service-connection service))
  (define shift (load-shift-by-id connection shift-id))
  (cond
    [(not shift) (register-cash-summary-not-found)]
    [else
     (define role (authenticated-operator-role principal))
     (define own?
       (operator-owns-resource?
        (authenticated-operator-operator-id principal)
        (register-shift-cashier-id shift)))
     (cond
       [(operator-role-authorized? role 'shift.cash_summary.read.any)
        (full-summary-result connection shift-id)]
       [(and own?
             (operator-role-authorized?
              role 'shift.cash_summary.read.own))
        (if (register-shift-closed-at-epoch-ms shift)
            (full-summary-result connection shift-id)
            (register-cash-summary-limited shift-id 'open))]
       [else (register-cash-summary-authorization-denied)])]))
