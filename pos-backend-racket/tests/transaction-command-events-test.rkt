#lang racket

(require rackunit
         "../pos/domain/fake-catalog.rkt"
         "../pos/domain/money.rkt"
         "../pos/domain/transaction-event.rkt"
         "../pos/domain/transaction.rkt")

(define test-barcode "049000001234")

(define (live-open-sale id)
  (define started (start-transaction id))
  (scan-accepted-transaction
   (scan-barcode (start-accepted-transaction started)
                 test-barcode
                 fake-catalog-lookup)))

(define (live-paid-sale id)
  (tender-accepted-transaction
   (tender-cash (live-open-sale id) (money 500))))

(define (only-event events)
  (check-equal? (length events) 1)
  (first events))

(module+ test
  (test-case "live transaction start emits and applies transaction-started"
    (define result (start-transaction "txn-start"))

    (check-pred start-accepted? result)
    (define started (start-accepted-transaction result))
    (define events (start-accepted-events result))
    (define event (only-event events))

    (check-pred transaction-started? event)
    (check-equal? (transaction-started-transaction-id event) "txn-start")
    (check-equal? (transaction-status started) 'open)
    (check-equal? (transaction-line-items started) '())
    (check-equal? (transaction-subtotal started) (money 0))

    (define applied (apply-transaction-event #f event))
    (define replayed (replay-transaction events))
    (check-pred event-applied? applied)
    (check-pred replay-succeeded? replayed)
    (check-equal? (event-applied-transaction applied) started)
    (check-equal? (replay-succeeded-transaction replayed) started)
    (check-equal? (make-transaction "txn-start") started))

  (test-case "known-barcode scan emits and applies its sale-time snapshot"
    (define start-result (start-transaction "txn-scan"))
    (define open (start-accepted-transaction start-result))
    (define lookup-count 0)
    (define result
      (scan-barcode
       open
       test-barcode
       (lambda (barcode)
         (set! lookup-count (add1 lookup-count))
         (fake-catalog-lookup barcode))))

    (check-pred scan-accepted? result)
    (define scanned (scan-accepted-transaction result))
    (define events (scan-accepted-events result))
    (define event (only-event events))

    (check-pred sale-item-added? event)
    (check-equal? (sale-item-added-barcode event) test-barcode)
    (check-equal? (sale-item-added-description event) "Test Apples")
    (check-equal? (sale-item-added-unit-price event) (money 199))

    (define applied (apply-transaction-event open event))
    (check-pred event-applied? applied)
    (check-equal? (event-applied-transaction applied) scanned)
    (check-equal? (transaction-subtotal scanned) (money 199))

    (define replayed
      (replay-transaction
       (append (start-accepted-events start-result) events)))
    (check-pred replay-succeeded? replayed)
    (check-equal? (replay-succeeded-transaction replayed) scanned)
    (check-equal? lookup-count 1))

  (test-case "rejected scans emit no events and preserve prior state"
    (define open (start-accepted-transaction
                  (start-transaction "txn-scan-rejected")))
    (define unknown
      (scan-barcode open "000000000000" fake-catalog-lookup))

    (check-pred scan-rejected? unknown)
    (check-equal? (scan-rejected-code unknown) 'unknown-barcode)
    (check-equal? (scan-rejected-events unknown) '())
    (check-eq? (scan-rejected-transaction unknown) open)

    (define paid (live-paid-sale "txn-scan-invalid"))
    (define invalid
      (scan-barcode
       paid
       test-barcode
       (lambda (_barcode)
         (error 'test "invalid-state scan performed a catalog lookup"))))

    (check-pred scan-rejected? invalid)
    (check-equal? (scan-rejected-code invalid) 'invalid-transaction-state)
    (check-equal? (scan-rejected-events invalid) '())
    (check-eq? (scan-rejected-transaction invalid) paid))

  (test-case "sufficient cash tender emits and applies cash-tendered"
    (define open (live-open-sale "txn-tender"))
    (define result (tender-cash open (money 500)))

    (check-pred tender-accepted? result)
    (define paid (tender-accepted-transaction result))
    (define events (tender-accepted-events result))
    (define event (only-event events))

    (check-pred cash-tendered? event)
    (check-equal? (cash-tendered-amount event) (money 500))

    (define applied (apply-transaction-event open event))
    (check-pred event-applied? applied)
    (check-equal? (event-applied-transaction applied) paid)
    (check-equal? (transaction-status paid) 'paid)
    (check-equal? (transaction-change-due paid) (money 301)))

  (test-case "rejected cash tenders emit no events and preserve prior state"
    (define empty
      (start-accepted-transaction
       (start-transaction "txn-tender-empty")))
    (define empty-result (tender-cash empty (money 0)))

    (check-pred tender-rejected? empty-result)
    (check-equal? (tender-rejected-code empty-result) 'empty-transaction)
    (check-equal? (tender-rejected-events empty-result) '())
    (check-eq? (tender-rejected-transaction empty-result) empty)

    (define open (live-open-sale "txn-tender-rejected"))
    (define insufficient (tender-cash open (money 198)))

    (check-pred tender-rejected? insufficient)
    (check-equal? (tender-rejected-code insufficient) 'insufficient-tender)
    (check-equal? (tender-rejected-events insufficient) '())
    (check-eq? (tender-rejected-transaction insufficient) open)

    (define paid (live-paid-sale "txn-tender-invalid"))
    (define invalid (tender-cash paid (money 500)))

    (check-pred tender-rejected? invalid)
    (check-equal? (tender-rejected-code invalid) 'invalid-transaction-state)
    (check-equal? (tender-rejected-events invalid) '())
    (check-eq? (tender-rejected-transaction invalid) paid))

  (test-case "paid transaction completion emits and applies completion"
    (define paid (live-paid-sale "txn-completion"))
    (define result (complete-transaction paid))

    (check-pred completion-accepted? result)
    (define completed (completion-accepted-transaction result))
    (define events (completion-accepted-events result))
    (define event (only-event events))

    (check-pred transaction-completed? event)
    (define applied (apply-transaction-event paid event))
    (check-pred event-applied? applied)
    (check-equal? (event-applied-transaction applied) completed)
    (check-equal? (transaction-status completed) 'completed))

  (test-case "rejected completions emit no events and preserve prior state"
    (define open (live-open-sale "txn-completion-rejected"))
    (define unpaid (complete-transaction open))

    (check-pred completion-rejected? unpaid)
    (check-equal? (completion-rejected-code unpaid)
                  'invalid-transaction-state)
    (check-equal? (completion-rejected-events unpaid) '())
    (check-eq? (completion-rejected-transaction unpaid) open)

    (define paid (live-paid-sale "txn-completion-duplicate"))
    (define first-completion (complete-transaction paid))
    (define completed
      (completion-accepted-transaction first-completion))
    (define duplicate (complete-transaction completed))

    (check-pred completion-rejected? duplicate)
    (check-equal? (completion-rejected-code duplicate)
                  'invalid-transaction-state)
    (check-equal? (completion-rejected-events duplicate) '())
    (check-eq? (completion-rejected-transaction duplicate) completed))

  (test-case "live cash sale and emitted-event replay reach equivalent state"
    (define start-result (start-transaction "txn-001"))
    (define scan-result
      (scan-barcode (start-accepted-transaction start-result)
                    test-barcode
                    fake-catalog-lookup))
    (define tender-result
      (tender-cash (scan-accepted-transaction scan-result)
                   (money 500)))
    (define completion-result
      (complete-transaction
       (tender-accepted-transaction tender-result)))
    (define live-transaction
      (completion-accepted-transaction completion-result))
    (define emitted-events
      (append (start-accepted-events start-result)
              (scan-accepted-events scan-result)
              (tender-accepted-events tender-result)
              (completion-accepted-events completion-result)))

    (check-equal? (length emitted-events) 4)
    (define replay-result (replay-transaction emitted-events))
    (check-pred replay-succeeded? replay-result)
    (define replayed-transaction
      (replay-succeeded-transaction replay-result))

    (check-equal? replayed-transaction live-transaction)
    (check-equal? (transaction-id replayed-transaction) "txn-001")
    (check-equal? (transaction-status replayed-transaction) 'completed)
    (check-equal? (transaction-line-items replayed-transaction)
                  (transaction-line-items live-transaction))
    (check-equal? (transaction-subtotal replayed-transaction) (money 199))
    (check-equal? (transaction-total replayed-transaction) (money 199))
    (check-equal? (transaction-tendered-cash replayed-transaction)
                  (money 500))
    (check-equal? (transaction-change-due replayed-transaction)
                  (money 301))))
