#lang racket

(require rackunit
         "../pos/domain/fake-catalog.rkt"
         "../pos/domain/money.rkt"
         "../pos/domain/transaction.rkt"
         (submod "../pos/domain/transaction.rkt" test-support))

(define (open-sale id)
  (scan-accepted-transaction
   (scan-barcode (make-transaction id)
                 "049000001234"
                 fake-catalog-lookup)))

(module+ test
  (test-case "over-tendered cash satisfies payment and derives change"
    (define original (open-sale "txn-cash-001"))
    (define result (tender-cash original (money 500)))

    (check-pred tender-accepted? result)
    (define paid (tender-accepted-transaction result))

    (check-equal? (transaction-status paid) 'paid)
    (check-equal? (transaction-subtotal paid) (money 199))
    (check-equal? (transaction-total paid) (money 199))
    (check-equal? (transaction-tendered-cash paid) (money 500))
    (check-equal? (transaction-change-due paid) (money 301))
    (check-equal? (transaction-status original) 'open)
    (check-false (transaction-tendered-cash original))
    (check-false (transaction-change-due original)))

  (test-case "exact cash satisfies payment with zero change"
    (define result (tender-cash (open-sale "txn-cash-002") (money 199)))
    (define paid (tender-accepted-transaction result))

    (check-equal? (transaction-status paid) 'paid)
    (check-equal? (transaction-tendered-cash paid) (money 199))
    (check-equal? (transaction-change-due paid) (money 0)))

  (test-case "insufficient cash is rejected without partial tender state"
    (define original (open-sale "txn-cash-003"))
    (define result (tender-cash original (money 198)))

    (check-pred tender-rejected? result)
    (check-equal? (tender-rejected-code result) 'insufficient-tender)
    (check-eq? (tender-rejected-transaction result) original)
    (check-equal? (transaction-status original) 'open)
    (check-false (transaction-tendered-cash original))
    (check-false (transaction-change-due original)))

  (test-case "zero cash against a positive total is rejected"
    (define original (open-sale "txn-cash-004"))
    (define result (tender-cash original (money 0)))

    (check-pred tender-rejected? result)
    (check-equal? (tender-rejected-code result) 'insufficient-tender)
    (check-eq? (tender-rejected-transaction result) original))

  (test-case "cash tender requires an active transaction value"
    (check-exn exn:fail:contract?
               (lambda () (tender-cash #f (money 500)))))

  (test-case "cash tender cannot be applied after payment is satisfied"
    (define paid
      (tender-accepted-transaction
       (tender-cash (open-sale "txn-cash-005") (money 500))))
    (define result (tender-cash paid (money 500)))

    (check-pred tender-rejected? result)
    (check-equal? (tender-rejected-code result) 'invalid-transaction-state)
    (check-eq? (tender-rejected-transaction result) paid)
    (check-equal? (transaction-tendered-cash paid) (money 500))
    (check-equal? (transaction-change-due paid) (money 301)))

  (test-case "cash tender cannot be applied to a completed transaction"
    (define paid
      (tender-accepted-transaction
       (tender-cash (open-sale "txn-cash-006") (money 500))))
    (define completed (transaction-with-status-for-test paid 'completed))
    (define result (tender-cash completed (money 500)))

    (check-pred tender-rejected? result)
    (check-equal? (tender-rejected-code result) 'invalid-transaction-state)
    (check-eq? (tender-rejected-transaction result) completed)
    (check-equal? (transaction-tendered-cash completed) (money 500))
    (check-equal? (transaction-change-due completed) (money 301))))
