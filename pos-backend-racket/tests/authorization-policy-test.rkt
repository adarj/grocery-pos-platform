#lang racket

(require rackunit
         "../pos/security/authorization-policy.rkt")

(define expected-permissions
  '(register.read
    cashier_directory.read
    transaction.read.own
    transaction.read.any
    transaction.operate.own
    receipt.read.own
    receipt.read.any
    shift.open.own
    shift.close.own
    shift.close.any
    shift.cash_summary.read.own
    shift.cash_summary.read.any))

(define expected-grants
  (hash
   'cashier
   '(register.read
     transaction.read.own
     transaction.operate.own
     receipt.read.own
     shift.open.own
     shift.close.own
     shift.cash_summary.read.own)
   'supervisor
   '(register.read
     cashier_directory.read
     transaction.read.own
     transaction.read.any
     transaction.operate.own
     receipt.read.own
     receipt.read.any
     shift.open.own
     shift.close.own
     shift.cash_summary.read.own
     shift.cash_summary.read.any)
   'manager
   expected-permissions))

(module+ test
  (test-case "fixed roles have an exhaustive explicit permission matrix"
    (check-equal? authorization-permissions expected-permissions)
    (for* ([role (in-list '(cashier supervisor manager))]
           [permission (in-list expected-permissions)])
      (check-equal?
       (operator-role-authorized? role permission)
       (and (memq permission (hash-ref expected-grants role)) #t)
       (format "~a / ~a" role permission)))
    (for ([role (in-list '(cashier supervisor manager))])
      (check-equal? (operator-role-permissions role)
                    (hash-ref expected-grants role))))

  (test-case "unknown roles and permissions deny by default"
    (check-false (operator-role-authorized? 'administrator 'register.read))
    (check-false (operator-role-authorized? 'manager 'future.permission))
    (check-equal? (operator-role-permissions 'administrator) '())
    (check-false (authorization-permission? 'future.permission)))

  (test-case "permission response strings retain deterministic policy order"
    (check-equal?
     (operator-role-permission-strings 'cashier)
     '("register.read"
       "transaction.read.own"
       "transaction.operate.own"
       "receipt.read.own"
       "shift.open.own"
       "shift.close.own"
       "shift.cash_summary.read.own")))

  (test-case "ownership is exact case-sensitive identity equality"
    (check-true (operator-owns-resource? "Cashier-A" "Cashier-A"))
    (check-false (operator-owns-resource? "Cashier-A" "cashier-a"))
    (check-false (operator-owns-resource? "Cashier-A" #f))))
