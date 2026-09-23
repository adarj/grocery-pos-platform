#lang racket

(provide authorization-permissions
         authorization-permission?
         operator-role-permissions
         operator-role-permission-strings
         operator-role-authorized?
         operator-owns-resource?)

;; Ordering is part of the safe authentication-response contract. Grants are
;; explicit per role: there is no rank, inheritance, or wildcard permission.
(define authorization-permissions
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
    shift.cash_summary.read.any
    approval.transaction_void))

(define role-grants
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
     shift.cash_summary.read.any
     approval.transaction_void)
   'manager
   authorization-permissions))

(define (authorization-permission? value)
  (and (memq value authorization-permissions) #t))

(define (operator-role-permissions role)
  (hash-ref role-grants role '()))

(define (operator-role-authorized? role permission)
  (and (authorization-permission? permission)
       (memq permission (operator-role-permissions role))
       #t))

(define (operator-role-permission-strings role)
  (for/list ([permission (in-list (operator-role-permissions role))])
    (symbol->string permission)))

(define (operator-owns-resource? operator-id owner-id)
  (and (string? operator-id)
       (string? owner-id)
       (string=? operator-id owner-id)))
