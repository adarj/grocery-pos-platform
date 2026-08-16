#lang racket

(require rackunit
         "../pos/domain/money.rkt"
         "../pos/domain/transaction-event.rkt"
         "../pos/domain/transaction.rkt"
         "../pos/persistence/transaction-event-codec.rkt")

(module+ test
  (test-case "schema v1 JSON bytes decode and replay the complete cash sale"
    (define original-events
      (list (transaction-started "txn-001")
            (sale-item-added "049000001234"
                             "Test Apples"
                             (money 199))
            (cash-tendered (money 500))
            (transaction-completed)))
    (define persisted-representations
      (map transaction-event->json-bytes original-events))
    (define decode-results
      (map json-bytes->transaction-event persisted-representations))

    (for ([result (in-list decode-results)])
      (check-pred event-decode-success? result))

    (define decoded-events
      (map event-decode-success-event decode-results))
    (define replay-result (replay-transaction decoded-events))

    (check-pred replay-succeeded? replay-result)
    (define recovered
      (replay-succeeded-transaction replay-result))
    (define line-item (first (transaction-line-items recovered)))

    (check-equal? (transaction-id recovered) "txn-001")
    (check-equal? (transaction-status recovered) 'completed)
    (check-equal? (transaction-line-item-barcode line-item)
                  "049000001234")
    (check-equal? (transaction-line-item-description line-item)
                  "Test Apples")
    (check-equal? (transaction-subtotal recovered) (money 199))
    (check-equal? (transaction-total recovered) (money 199))
    (check-equal? (transaction-tendered-cash recovered) (money 500))
    (check-equal? (transaction-change-due recovered) (money 301))))
