#lang racket

(require rackunit
         "../pos/domain/operator-identity.rkt")

(module+ test
  (test-case "operator roles are fixed and parsed strictly"
    (check-equal? operator-roles '(cashier supervisor manager))
    (for ([role (in-list operator-roles)])
      (check-true (operator-role? role))
      (check-eq? (parse-operator-role (symbol->string role)) role)
      (check-equal? (operator-role->string role) (symbol->string role)))
    (check-false (operator-role? 'administrator))
    (check-false (parse-operator-role "Manager"))
    (check-false (parse-operator-role " manager ")))

  (test-case "operator identity preserves opaque case-sensitive IDs"
    (define operator
      (operator-identity
       " Cashier-A " "Alice" #t 'cashier 'enrollment-required #f))
    (check-equal? (operator-identity-operator-id operator) " Cashier-A ")
    (check-true (immutable? (operator-identity-operator-id operator)))
    (check-eq? (operator-identity-credential-state operator)
               'enrollment-required)
    (check-false (operator-identity-credential-revision operator)))

  (test-case "credential enrollment state and revision must agree"
    (check-not-exn
     (lambda ()
       (operator-identity "manager" "Manager" #t 'manager 'enrolled 1)))
    (check-exn
     exn:fail:contract?
     (lambda ()
       (operator-identity "manager" "Manager" #t 'manager 'enrolled #f)))
    (check-exn
     exn:fail:contract?
     (lambda ()
       (operator-identity
        "cashier" "Cashier" #t 'cashier 'enrollment-required 1)))))
