#lang racket

(require rackunit
         "../pos/domain/money.rkt"
         "../pos/domain/tax.rkt"
         "../pos/domain/transaction-event.rkt"
         "../pos/domain/transaction.rkt")

(define test-item-added
  (sale-item-added "049000001234"
                   "Test Apples"
                   (money 199)))

(define (paid-event-stream id)
  (list (transaction-started id)
        test-item-added
        (cash-tendered (money 500))))

(define (completed-event-stream id)
  (append (paid-event-stream id)
          (list (transaction-completed))))

(module+ test
  (test-case "cash-sale events replay to the completed transaction"
    (define events (completed-event-stream "txn-001"))
    (define result (replay-transaction events))
    (define replayed-again (replay-transaction events))

    (check-pred replay-succeeded? result)
    (check-pred replay-succeeded? replayed-again)
    (define transaction (replay-succeeded-transaction result))
    (define line-item (first (transaction-line-items transaction)))

    (check-equal? transaction
                  (replay-succeeded-transaction replayed-again))
    (check-equal? (transaction-id transaction) "txn-001")
    (check-equal? (transaction-status transaction) 'completed)
    (check-equal? (length (transaction-line-items transaction)) 1)
    (check-equal? (transaction-line-item-barcode line-item)
                  "049000001234")
    (check-equal? (transaction-line-item-description line-item)
                  "Test Apples")
    (check-equal? (transaction-line-item-unit-price line-item) (money 199))
    (check-equal? (transaction-subtotal transaction) (money 199))
    (check-equal? (transaction-total transaction) (money 199))
    (check-equal? (transaction-tendered-cash transaction) (money 500))
    (check-equal? (transaction-change-due transaction) (money 301)))

  (test-case "event values own immutable copies of sale-time text"
    (define source-id (string-copy "txn-snapshot"))
    (define source-barcode (string-copy "049000001234"))
    (define source-description (string-copy "Test Apples"))
    (define started (transaction-started source-id))
    (define item-added
      (sale-item-added source-barcode source-description (money 199)))

    (string-set! source-id 0 #\X)
    (string-set! source-barcode 0 #\9)
    (string-set! source-description 0 #\B)

    (check-pred transaction-event? started)
    (check-pred transaction-event? item-added)
    (check-equal? (transaction-started-transaction-id started)
                  "txn-snapshot")
    (check-equal? (sale-item-added-barcode item-added) "049000001234")
    (check-equal? (sale-item-added-description item-added) "Test Apples")
    (check-equal? (sale-item-added-unit-price item-added) (money 199))
    (check-true (immutable? (transaction-started-transaction-id started)))
    (check-true (immutable? (sale-item-added-barcode item-added)))
    (check-true (immutable? (sale-item-added-description item-added))))

  (test-case "event monetary facts require exact money values"
    (check-exn exn:fail:contract?
               (lambda ()
                 (sale-item-added "049000001234"
                                  "Test Apples"
                                  199)))
    (check-exn exn:fail:contract?
               (lambda ()
                 (cash-tendered 500))))

  (test-case "event identifiers and sale-time text require strings"
    (check-exn exn:fail:contract?
               (lambda () (transaction-started 'txn-001)))
    (check-exn exn:fail:contract?
               (lambda ()
                 (sale-item-added 49000001234
                                  "Test Apples"
                                  (money 199))))
    (check-exn exn:fail:contract?
               (lambda ()
                 (sale-item-added "049000001234"
                                  'test-apples
                                  (money 199)))))

  (test-case "an empty event stream cannot reconstruct a transaction"
    (define result (replay-transaction '()))

    (check-pred replay-failed? result)
    (check-false (replay-failed-event-index result))
    (check-equal? (replay-failed-code result) 'transaction-not-started)
    (check-false (replay-failed-transaction result)))

  (test-case "sale item before transaction start fails replay"
    (define result (replay-transaction (list test-item-added)))

    (check-pred replay-failed? result)
    (check-equal? (replay-failed-event-index result) 0)
    (check-equal? (replay-failed-code result) 'transaction-not-started)
    (check-false (replay-failed-transaction result)))

  (test-case "cash tender before transaction start fails replay"
    (define result
      (replay-transaction (list (cash-tendered (money 500)))))

    (check-pred replay-failed? result)
    (check-equal? (replay-failed-event-index result) 0)
    (check-equal? (replay-failed-code result) 'transaction-not-started)
    (check-false (replay-failed-transaction result)))

  (test-case "completion before transaction start fails replay"
    (define result
      (replay-transaction (list (transaction-completed))))

    (check-pred replay-failed? result)
    (check-equal? (replay-failed-event-index result) 0)
    (check-equal? (replay-failed-code result) 'transaction-not-started)
    (check-false (replay-failed-transaction result)))

  (test-case "duplicate transaction start fails replay"
    (define result
      (replay-transaction
       (list (transaction-started "txn-duplicate")
             (transaction-started "txn-duplicate"))))

    (check-pred replay-failed? result)
    (check-equal? (replay-failed-event-index result) 1)
    (check-equal? (replay-failed-code result) 'duplicate-transaction-started)
    (check-equal? (transaction-id (replay-failed-transaction result))
                  "txn-duplicate")
    (check-equal? (transaction-status (replay-failed-transaction result))
                  'open))

  (test-case "completion before sufficient cash fails replay"
    (define result
      (replay-transaction
       (list (transaction-started "txn-unpaid")
             test-item-added
             (transaction-completed))))

    (check-pred replay-failed? result)
    (check-equal? (replay-failed-event-index result) 2)
    (check-equal? (replay-failed-code result) 'invalid-transaction-state)
    (check-equal? (transaction-status (replay-failed-transaction result))
                  'open)
    (check-equal? (transaction-subtotal (replay-failed-transaction result))
                  (money 199)))

  (test-case "insufficient cash event fails replay without partial tender"
    (define result
      (replay-transaction
       (list (transaction-started "txn-insufficient")
             test-item-added
             (cash-tendered (money 198)))))

    (check-pred replay-failed? result)
    (check-equal? (replay-failed-event-index result) 2)
    (check-equal? (replay-failed-code result) 'insufficient-tender)
    (check-equal? (transaction-status (replay-failed-transaction result))
                  'open)
    (check-false
     (transaction-tendered-cash (replay-failed-transaction result))))

  (test-case "cash tender on an empty transaction fails replay"
    (define result
      (replay-transaction
       (list (transaction-started "txn-empty")
             (cash-tendered (money 500)))))

    (check-pred replay-failed? result)
    (check-equal? (replay-failed-event-index result) 1)
    (check-equal? (replay-failed-code result) 'empty-transaction)
    (check-equal? (transaction-status (replay-failed-transaction result))
                  'open))

  (test-case "event application rejects a lifecycle violation unchanged"
    (define replay-result
      (replay-transaction (completed-event-stream "txn-completed")))
    (define completed
      (replay-succeeded-transaction replay-result))
    (define result
      (apply-transaction-event completed test-item-added))

    (check-pred event-rejected? result)
    (check-equal? (event-rejected-code result)
                  'invalid-transaction-state)
    (check-eq? (event-rejected-transaction result) completed)
    (check-equal? (transaction-status completed) 'completed)
    (check-equal? (transaction-subtotal completed) (money 199)))

  (test-case "line removal replay removes exactly one indexed occurrence"
    (define events
      (list (transaction-started "txn-remove")
            (sale-item-added "A" "Apples" (money 100))
            (sale-item-added "A" "Apples" (money 100))
            (sale-item-added "B" "Bananas" (money 200))
            (sale-line-removed 1)))
    (define result (replay-transaction events))

    (check-pred replay-succeeded? result)
    (define transaction (replay-succeeded-transaction result))
    (check-equal?
     (map transaction-line-item-barcode
          (transaction-line-items transaction))
     '("A" "B"))
    (check-equal? (transaction-subtotal transaction) (money 300)))

  (test-case "line removal subtracts the selected stored taxed contribution"
    (define result
      (replay-transaction
       (list (transaction-started "txn-tax-remove")
             (taxed-sale-item-added
              "taxed" "Taxed" (money 199) "standard" (tax-rate 100000)
              (money 20))
             (sale-item-added "legacy" "Legacy" (money 299))
             (sale-line-removed 0))))

    (check-pred replay-succeeded? result)
    (define transaction (replay-succeeded-transaction result))
    (check-equal? (transaction-subtotal transaction) (money 299))
    (check-equal? (transaction-tax transaction) (money 0))
    (check-equal? (transaction-total transaction) (money 299)))

  (test-case "invalid historical removal fails closed"
    (define result
      (replay-transaction
       (list (transaction-started "txn-invalid-remove")
             test-item-added
             (sale-line-removed 1))))

    (check-pred replay-failed? result)
    (check-equal? (replay-failed-event-index result) 2)
    (check-equal? (replay-failed-code result) 'line-item-not-found))

  (test-case "void replay is terminal and retains the cancelled projection"
    (define result
      (replay-transaction
       (list (transaction-started "txn-void")
             test-item-added
             (transaction-voided))))

    (check-pred replay-succeeded? result)
    (define transaction (replay-succeeded-transaction result))
    (check-equal? (transaction-status transaction) 'voided)
    (check-equal? (length (transaction-line-items transaction)) 1)
    (check-equal? (transaction-subtotal transaction) (money 199))
    (check-equal? (transaction-tax transaction) (money 0))
    (check-equal? (transaction-total transaction) (money 199))
    (check-false (transaction-tendered-cash transaction))
    (check-false (transaction-change-due transaction)))

  (test-case "post-void mutation events fail replay"
    (for ([event (in-list (list test-item-added
                                (sale-line-removed 0)
                                (cash-tendered (money 500))
                                (transaction-completed)
                                (transaction-voided)))])
      (define result
        (replay-transaction
         (list (transaction-started "txn-post-void")
               test-item-added
               (transaction-voided)
               event)))
      (check-pred replay-failed? result)
      (check-equal? (replay-failed-event-index result) 3)
      (check-equal? (replay-failed-code result)
                    'invalid-transaction-state))))
