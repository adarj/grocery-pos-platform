#lang racket

(require rackunit
         "../pos/domain/fake-catalog.rkt"
         "../pos/domain/money.rkt"
         "../pos/domain/transaction.rkt"
         (submod "../pos/domain/transaction.rkt" test-support))

(module+ test
  (test-case "scanning a known barcode adds a sale-time line item"
    (define original (make-transaction "txn-001"))
    (define result
      (scan-barcode original "049000001234" fake-catalog-lookup))

    (check-pred scan-accepted? result)
    (define updated (scan-accepted-transaction result))
    (define line-item (first (transaction-line-items updated)))

    (check-equal? (transaction-line-item-barcode line-item) "049000001234")
    (check-equal? (transaction-line-item-description line-item) "Test Apples")
    (check-equal? (transaction-line-item-unit-price line-item) (money 199))
    (check-equal? (transaction-subtotal updated) (money 199))
    (check-equal? (transaction-line-items original) '()))

  (test-case "each additional known scan adds another line to the subtotal"
    (define original (make-transaction "txn-002"))
    (define after-first-scan
      (scan-accepted-transaction
       (scan-barcode original "049000001234" fake-catalog-lookup)))
    (define after-second-scan
      (scan-accepted-transaction
       (scan-barcode after-first-scan "049000001234" fake-catalog-lookup)))

    (check-equal? (length (transaction-line-items after-second-scan)) 2)
    (check-equal? (transaction-subtotal after-second-scan) (money 398)))

  (test-case "unknown barcode is rejected without changing the transaction"
    (define original (make-transaction "txn-003"))
    (define result
      (scan-barcode original "000000000000" fake-catalog-lookup))

    (check-pred scan-rejected? result)
    (check-equal? (scan-rejected-code result) 'unknown-barcode)
    (check-eq? (scan-rejected-transaction result) original)
    (check-equal? (transaction-line-items original) '())
    (check-equal? (transaction-subtotal original) (money 0)))

  (test-case "transaction state that does not accept items rejects scanning"
    (define completed
      (make-transaction-with-status-for-test "txn-004" 'completed))
    (define result
      (scan-barcode completed "049000001234" fake-catalog-lookup))

    (check-pred scan-rejected? result)
    (check-equal? (scan-rejected-code result) 'invalid-transaction-state)
    (check-eq? (scan-rejected-transaction result) completed)
    (check-equal? (transaction-line-items completed) '())
    (check-equal? (transaction-subtotal completed) (money 0))))
