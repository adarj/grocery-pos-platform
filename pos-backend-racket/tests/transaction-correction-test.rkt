#lang racket

(require rackunit
         "../pos/domain/catalog-item.rkt"
         "../pos/domain/money.rkt"
         "../pos/domain/tax.rkt"
         "../pos/domain/transaction-event.rkt"
         "../pos/domain/transaction.rkt")

(define legacy-A
  (sale-item-added "A" "Legacy Apples" (money 100)))
(define taxed-B
  (taxed-sale-item-added
   "B" "Taxed Bananas" (money 199) "standard" (tax-rate 100000) (money 20)))
(define taxed-C
  (taxed-sale-item-added
   "C" "Taxed Cherries" (money 299) "exempt" (tax-rate 0) (money 0)))

(define (replayed events)
  (define result (replay-transaction events))
  (check-pred replay-succeeded? result)
  (replay-succeeded-transaction result))

(define (open-with events [id "txn-correction"])
  (replayed (cons (transaction-started id) events)))

(module+ test
  (test-case "removing the only line leaves an open empty transaction"
    (define result (remove-line-item (open-with (list legacy-A)) 0))

    (check-pred removal-accepted? result)
    (check-equal? (removal-accepted-events result)
                  (list (sale-line-removed 0)))
    (define transaction (removal-accepted-transaction result))
    (check-equal? (transaction-status transaction) 'open)
    (check-equal? (transaction-line-items transaction) '())
    (check-equal? (transaction-subtotal transaction) (money 0))
    (check-equal? (transaction-tax transaction) (money 0))
    (check-equal? (transaction-total transaction) (money 0)))

  (test-case "first, middle, and last positions preserve remaining order"
    (for ([line-index (in-list '(0 1 2))]
          [expected (in-list '(("B" "C")
                               ("A" "C")
                               ("A" "B")))])
      (define result
        (remove-line-item (open-with (list legacy-A taxed-B taxed-C))
                          line-index))
      (check-pred removal-accepted? result)
      (check-equal?
       (map transaction-line-item-barcode
            (transaction-line-items
             (removal-accepted-transaction result)))
       expected)))

  (test-case "repeated identical lines are distinct indexed occurrences"
    (define transaction
      (open-with (list legacy-A legacy-A taxed-B)))
    (define first-removal
      (removal-accepted-transaction (remove-line-item transaction 0)))
    (define second-removal
      (remove-line-item first-removal 1))

    (check-pred removal-accepted? second-removal)
    (check-equal?
     (map transaction-line-item-barcode
          (transaction-line-items
           (removal-accepted-transaction second-removal)))
     '("A")))

  (test-case "removal subtracts exact stored base price and tax"
    (define result
      (remove-line-item (open-with (list legacy-A taxed-B taxed-C)) 1))
    (define transaction (removal-accepted-transaction result))

    (check-equal? (transaction-subtotal transaction) (money 399))
    (check-equal? (transaction-tax transaction) (money 0))
    (check-equal? (transaction-total transaction) (money 399)))

  (test-case "out-of-range and empty-basket removals are domain rejections"
    (for ([transaction (in-list (list (open-with '() "txn-empty")
                                      (open-with (list legacy-A)
                                                 "txn-out-of-range")))]
          [index (in-list '(0 1))])
      (define result (remove-line-item transaction index))
      (check-pred removal-rejected? result)
      (check-equal? (removal-rejected-code result) 'line-item-not-found)
      (check-eq? (removal-rejected-transaction result) transaction)
      (check-equal? (removal-rejected-events result) '())))

  (test-case "remove rejects invalid programming-level indices"
    (define transaction (open-with (list legacy-A)))
    (for ([index (in-list (list -1 1.0 "0"))])
      (check-exn exn:fail:contract?
                 (lambda () (remove-line-item transaction index)))))

  (test-case "void accepts empty and populated open transactions"
    (for ([transaction
           (in-list
            (list (open-with '() "txn-empty-void")
                  (open-with (list legacy-A taxed-B) "txn-full-void")))])
      (define result (void-transaction transaction))
      (check-pred void-accepted? result)
      (check-equal? (void-accepted-events result)
                    (list (transaction-voided)))
      (define voided (void-accepted-transaction result))
      (check-equal? (transaction-status voided) 'voided)
      (check-equal? (transaction-line-items voided)
                    (transaction-line-items transaction))
      (check-equal? (transaction-subtotal voided)
                    (transaction-subtotal transaction))
      (check-equal? (transaction-tax voided)
                    (transaction-tax transaction))
      (check-equal? (transaction-total voided)
                    (transaction-total transaction))
      (check-false (transaction-tendered-cash voided))
      (check-false (transaction-change-due voided))))

  (test-case "paid, completed, and voided transactions reject corrections"
    (define paid
      (replayed
       (list (transaction-started "txn-paid")
             taxed-B
             (cash-tendered (money 500)))))
    (define completed
      (replayed
       (list (transaction-started "txn-completed")
             taxed-B
             (cash-tendered (money 500))
             (transaction-completed))))
    (define voided
      (replayed
       (list (transaction-started "txn-voided")
             taxed-B
             (transaction-voided))))

    (for ([transaction (in-list (list paid completed voided))])
      (define removal (remove-line-item transaction 0))
      (define voiding (void-transaction transaction))
      (check-pred removal-rejected? removal)
      (check-equal? (removal-rejected-code removal)
                    'invalid-transaction-state)
      (check-pred void-rejected? voiding)
      (check-equal? (void-rejected-code voiding)
                    'invalid-transaction-state)))

  (test-case "voided transactions reject every existing mutation without catalog work"
    (define voided
      (void-accepted-transaction
       (void-transaction (open-with (list taxed-B) "txn-terminal"))))
    (define lookup-count 0)
    (define scan
      (scan-barcode
       voided
       "B"
       (lambda (_barcode)
         (set! lookup-count (add1 lookup-count))
         (catalog-item "B" "Taxed Bananas" (money 199)
                       "standard" (tax-rate 100000)))))

    (check-pred scan-rejected? scan)
    (check-equal? (scan-rejected-code scan) 'invalid-transaction-state)
    (check-equal? lookup-count 0)
    (check-equal? (tender-rejected-code (tender-cash voided (money 500)))
                  'invalid-transaction-state)
    (check-equal?
     (completion-rejected-code (complete-transaction voided))
     'invalid-transaction-state)
    (check-equal? (removal-rejected-code (remove-line-item voided 0))
                  'invalid-transaction-state)
    (check-equal? (void-rejected-code (void-transaction voided))
                  'invalid-transaction-state)))
