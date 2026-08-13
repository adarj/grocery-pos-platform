#lang racket

(require rackunit
         "../pos/domain/fake-catalog.rkt"
         "../pos/domain/money.rkt"
         "../pos/domain/transaction.rkt")

(define (paid-sale id)
  (define scanned
    (scan-accepted-transaction
     (scan-barcode (make-transaction id)
                   "049000001234"
                   fake-catalog-lookup)))
  (tender-accepted-transaction
   (tender-cash scanned (money 500))))

(module+ test
  (test-case "a paid cash sale completes with its exact monetary facts intact"
    (define paid (paid-sale "txn-complete-001"))
    (define result (complete-transaction paid))

    (check-pred completion-accepted? result)
    (define completed (completion-accepted-transaction result))

    (check-equal? (transaction-status completed) 'completed)
    (check-equal? (transaction-subtotal completed) (money 199))
    (check-equal? (transaction-total completed) (money 199))
    (check-equal? (transaction-tendered-cash completed) (money 500))
    (check-equal? (transaction-change-due completed) (money 301))
    (check-true
     (exact-integer?
      (money-minor-units (transaction-subtotal completed))))
    (check-true
     (exact-integer?
      (money-minor-units (transaction-change-due completed))))
    (check-equal? (transaction-status paid) 'paid))

  (test-case "an unpaid transaction cannot complete"
    (define open (make-transaction "txn-complete-002"))
    (define result (complete-transaction open))

    (check-pred completion-rejected? result)
    (check-equal? (completion-rejected-code result)
                  'invalid-transaction-state)
    (check-eq? (completion-rejected-transaction result) open)
    (check-equal? (transaction-status open) 'open))

  (test-case "a completed transaction cannot complete again"
    (define completed
      (completion-accepted-transaction
       (complete-transaction (paid-sale "txn-complete-003"))))
    (define result (complete-transaction completed))

    (check-pred completion-rejected? result)
    (check-equal? (completion-rejected-code result)
                  'invalid-transaction-state)
    (check-eq? (completion-rejected-transaction result) completed)
    (check-equal? (transaction-status completed) 'completed)
    (check-equal? (transaction-tendered-cash completed) (money 500))
    (check-equal? (transaction-change-due completed) (money 301))))
