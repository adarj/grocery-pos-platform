#lang racket

(require "money.rkt")

(provide make-transaction
         transaction?
         transaction-id
         transaction-status
         transaction-line-items
         transaction-subtotal)

(struct transaction (id status line-items)
  #:transparent)

(define (make-transaction id)
  (transaction id 'open '()))

(define (transaction-subtotal transaction)
  (unless (transaction? transaction)
    (raise-argument-error
     'transaction-subtotal
     "transaction?"
     transaction))
  (money 0))
