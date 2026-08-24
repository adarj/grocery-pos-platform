#lang racket

(require rackunit
         "../pos/domain/canonical-receipt.rkt"
         "../pos/domain/money.rkt"
         "../pos/domain/register-operations.rkt"
         "../pos/domain/tax.rkt"
         "../pos/domain/transaction-event.rkt"
         (prefix-in op: "../pos/domain/transaction-operational-context.rkt")
         "../pos/domain/transaction.rkt"
         "../pos/persistence/transaction-event-codec.rkt")

(define context
  (op:transaction-operational-context
   "register-one" "Front Register"
   "cashier-one" "Alice"
   "shift-one" 1000))

(define started
  (operational-transaction-started "txn-one" context))
(define completed (timestamped-transaction-completed 2000))
(define voided (timestamped-transaction-voided 1500))

(define sale-events
  (list
   started
   (taxed-sale-item-added
    "049000001234" "Test Apples" (money 199)
    "development-tax" (tax-rate 100000) (money 20))
   (cash-tendered (money 500))
   completed))

(module+ test
  (test-case "operational start and terminal events have strict Schema v2 wire forms"
    (check-equal?
     (transaction-event->jsexpr started)
     (hasheq
      'schema_version 2
      'event_type "transaction_started"
      'payload
      (hasheq
       'transaction_id "txn-one"
       'register_id "register-one"
       'register_display_name "Front Register"
       'cashier_id "cashier-one"
       'cashier_display_name "Alice"
       'shift_id "shift-one"
       'started_at_epoch_ms 1000)))
    (check-equal?
     (transaction-event->jsexpr completed)
     (hasheq 'schema_version 2
             'event_type "transaction_completed"
             'payload (hasheq 'completed_at_epoch_ms 2000)))
    (check-equal?
     (transaction-event->jsexpr voided)
     (hasheq 'schema_version 2
             'event_type "transaction_voided"
             'payload (hasheq 'voided_at_epoch_ms 1500)))
    (for ([event (in-list (list started completed voided))])
      (define decoded
        (json-string->transaction-event
         (transaction-event->json-string event)))
      (check-pred event-decode-success? decoded)
      (check-equal? (event-decode-success-event decoded) event)))

  (test-case "legacy start and terminal event golden forms remain Schema v1"
    (check-equal?
     (transaction-event->jsexpr (transaction-started "txn-legacy"))
     (hasheq 'schema_version 1
             'event_type "transaction_started"
             'payload (hasheq 'transaction_id "txn-legacy")))
    (check-equal?
     (transaction-event->jsexpr (transaction-completed))
     (hasheq 'schema_version 1
             'event_type "transaction_completed"
             'payload (hasheq))))

  (test-case "replay snapshots context and terminal time for canonical receipt v2"
    (define replay (replay-transaction sale-events))
    (check-pred replay-succeeded? replay)
    (define transaction (replay-succeeded-transaction replay))
    (check-equal? (transaction-operational-context transaction) context)
    (check-equal? (transaction-completed-at-epoch-ms transaction) 2000)
    (check-false (transaction-voided-at-epoch-ms transaction))
    (define derived (derive-canonical-receipt transaction 4))
    (check-pred receipt-created? derived)
    (define receipt (receipt-created-receipt derived))
    (check-pred operational-canonical-receipt? receipt)
    (check-equal?
     (operational-canonical-receipt-register receipt)
     (register-identity "register-one" "Front Register"))
    (check-equal?
     (operational-canonical-receipt-cashier receipt)
     (cashier-identity "cashier-one" "Alice"))
    (check-equal? (operational-canonical-receipt-shift-id receipt)
                  "shift-one")
    (check-equal? (operational-canonical-receipt-started-at-epoch-ms receipt)
                  1000)
    (check-equal? (operational-canonical-receipt-completed-at-epoch-ms receipt)
                  2000)
    (check-equal? (canonical-receipt-total receipt) (money 219)))

  (test-case "inconsistent legacy/context terminal combinations fail closed"
    (define replay
      (replay-transaction
       (list started
             (taxed-sale-item-added
              "049000001234" "Test Apples" (money 199)
              "development-tax" (tax-rate 100000) (money 20))
             (cash-tendered (money 500))
             (transaction-completed))))
    (check-pred replay-succeeded? replay)
    (check-exn
     exn:fail?
     (lambda ()
       (derive-canonical-receipt
        (replay-succeeded-transaction replay)
        4))))

  (test-case "terminal time before start is rejected during replay"
    (define result
      (replay-transaction
       (list started
             (taxed-sale-item-added
              "049000001234" "Test Apples" (money 199)
              "development-tax" (tax-rate 100000) (money 20))
             (cash-tendered (money 500))
             (timestamped-transaction-completed 999))))
    (check-pred replay-failed? result)
    (check-equal? (replay-failed-code result)
                  'invalid-operational-timestamp)))
