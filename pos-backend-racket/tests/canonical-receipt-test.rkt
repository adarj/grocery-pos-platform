#lang racket

(require rackunit
         "../pos/domain/canonical-receipt.rkt"
         "../pos/domain/money.rkt"
         "../pos/domain/tax.rkt"
         "../pos/domain/transaction-event.rkt"
         "../pos/domain/transaction.rkt")

(define legacy-apples
  (sale-item-added "049000001234" "Legacy Apples" (money 199)))

(define taxed-bread
  (taxed-sale-item-added
   "012345678905"
   "Taxed Bread"
   (money 250)
   "development-standard"
   (tax-rate 100000)
   (money 25)))

(define taxed-milk
  (taxed-sale-item-added
   "000111222333"
   "Taxed Milk"
   (money 100)
   "development-reduced"
   (tax-rate 50000)
   (money 5)))

(define (replayed events)
  (define result (replay-transaction events))
  (check-pred replay-succeeded? result)
  (replay-succeeded-transaction result))

(define (completed-transaction line-events
                               #:corrections [corrections '()]
                               #:cash [cash 1000]
                               #:id [transaction-id "txn-receipt"])
  (replayed
   (append
    (list (transaction-started transaction-id))
    line-events
    corrections
    (list (cash-tendered (money cash))
          (transaction-completed)))))

(module+ test
  (test-case "completed replay produces exact canonical receipt"
    (define transaction
      (completed-transaction
       (list legacy-apples taxed-bread taxed-milk)
       #:id "txn-exact-receipt"))
    (define result (derive-canonical-receipt transaction 6))

    (check-pred receipt-created? result)
    (define receipt (receipt-created-receipt result))
    (check-equal? (canonical-receipt-transaction-id receipt)
                  "txn-exact-receipt")
    (check-equal? (canonical-receipt-transaction-version receipt) 6)
    (check-equal? (canonical-receipt-subtotal receipt) (money 549))
    (check-equal? (canonical-receipt-tax receipt) (money 30))
    (check-equal? (canonical-receipt-total receipt) (money 579))
    (check-equal? (canonical-receipt-tendered-cash receipt) (money 1000))
    (check-equal? (canonical-receipt-change-due receipt) (money 421))

    (define lines (canonical-receipt-line-items receipt))
    (check-equal? (map canonical-receipt-line-description lines)
                  '("Legacy Apples" "Taxed Bread" "Taxed Milk"))
    (check-equal? (canonical-receipt-line-barcode (second lines))
                  "012345678905")
    (check-equal? (canonical-receipt-line-unit-price (second lines))
                  (money 250))
    (check-equal? (canonical-receipt-line-tax-category-id (second lines))
                  "development-standard")
    (check-equal?
     (tax-rate-millionths
      (canonical-receipt-line-tax-rate (second lines)))
     100000)
    (check-equal? (canonical-receipt-line-tax-amount (second lines))
                  (money 25)))

  (test-case "legacy sale lines retain absent tax metadata and zero line tax"
    (define result
      (derive-canonical-receipt
       (completed-transaction (list legacy-apples))
       4))
    (define line
      (first
       (canonical-receipt-line-items
        (receipt-created-receipt result))))

    (check-false (canonical-receipt-line-tax-category-id line))
    (check-false (canonical-receipt-line-tax-rate line))
    (check-equal? (canonical-receipt-line-tax-amount line) (money 0)))

  (test-case "open paid and voided transactions have no sales receipt"
    (define open
      (replayed (list (transaction-started "txn-open") taxed-bread)))
    (define paid
      (replayed
       (list (transaction-started "txn-paid")
             taxed-bread
             (cash-tendered (money 500)))))
    (define voided
      (replayed
       (list (transaction-started "txn-voided")
             taxed-bread
             (transaction-voided))))

    (for ([transaction (in-list (list open paid voided))])
      (define result (derive-canonical-receipt transaction 3))
      (check-pred receipt-unavailable? result)
      (check-equal? (receipt-unavailable-reason result)
                    'transaction-not-completed)))

  (test-case "receipt reflects final retained order after correction"
    (define result
      (derive-canonical-receipt
       (completed-transaction
        (list legacy-apples taxed-bread taxed-milk)
        #:corrections (list (sale-line-removed 1)))
       7))
    (define receipt (receipt-created-receipt result))

    (check-equal?
     (map canonical-receipt-line-description
          (canonical-receipt-line-items receipt))
     '("Legacy Apples" "Taxed Milk"))
    (check-equal? (canonical-receipt-subtotal receipt) (money 299))
    (check-equal? (canonical-receipt-tax receipt) (money 5))
    (check-equal? (canonical-receipt-total receipt) (money 304)))

  (test-case "one removed repeated scan leaves the other occurrences"
    (define result
      (derive-canonical-receipt
       (completed-transaction
        (list taxed-bread taxed-bread taxed-bread)
        #:corrections (list (sale-line-removed 1)))
       7))

    (check-equal?
     (length
      (canonical-receipt-line-items
       (receipt-created-receipt result)))
     2)))
