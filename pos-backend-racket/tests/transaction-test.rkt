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
    (check-equal? (transaction-subtotal transaction) (money 0)))

  (test-case "transaction owns an immutable copy of its identifier"
    (define source-id (string-copy "txn-002"))
    (define transaction (make-transaction source-id))

    (string-set! source-id 0 #\X)

    (check-equal? (transaction-id transaction) "txn-002")
    (check-true (immutable? (transaction-id transaction))))

  (test-case "transaction identifier must be a string"
    (check-exn exn:fail:contract?
               (lambda () (make-transaction 'txn-003)))))
