#lang racket

(require rackunit
         "../pos/domain/money.rkt"
         "../pos/domain/transaction.rkt")

(module+ test
  (test-case "a new transaction is open, empty, and has a zero subtotal"
    (define transaction (make-transaction "txn-001"))

    (check-equal? (transaction-id transaction) "txn-001")
    (check-equal? (transaction-status transaction) 'open)
    (check-equal? (transaction-line-items transaction) '())
    (check-equal? (transaction-subtotal transaction) (money 0))))
