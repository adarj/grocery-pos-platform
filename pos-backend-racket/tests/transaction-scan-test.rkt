#lang racket

(require rackunit
         "../pos/domain/catalog-item.rkt"
         "../pos/domain/fake-catalog.rkt"
         "../pos/domain/money.rkt"
         "../pos/domain/transaction.rkt")

(define (completed-sale id)
  (define scanned
    (scan-accepted-transaction
     (scan-barcode (make-transaction id)
                   "049000001234"
                   fake-catalog-lookup)))
  (define paid
    (tender-accepted-transaction
     (tender-cash scanned (money 199))))
  (completion-accepted-transaction
   (complete-transaction paid)))

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

  (test-case "scanned line owns immutable sale-time text"
    (define source-barcode (string-copy "049000001234"))
    (define source-description (string-copy "Test Apples"))
    (define item
      (catalog-item source-barcode source-description (money 199)))
    (define result
      (scan-barcode (make-transaction "txn-snapshot")
                    source-barcode
                    (lambda (_barcode) item)))
    (define line-item
      (first
       (transaction-line-items
        (scan-accepted-transaction result))))

    (string-set! source-barcode 0 #\9)
    (string-set! source-description 0 #\B)

    (check-equal? (transaction-line-item-barcode line-item) "049000001234")
    (check-equal? (transaction-line-item-description line-item) "Test Apples")
    (check-true (immutable? (transaction-line-item-barcode line-item)))
    (check-true (immutable? (transaction-line-item-description line-item))))

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
    (define completed (completed-sale "txn-004"))
    (define result
      (scan-barcode completed "049000001234" fake-catalog-lookup))

    (check-pred scan-rejected? result)
    (check-equal? (scan-rejected-code result) 'invalid-transaction-state)
    (check-eq? (scan-rejected-transaction result) completed)
    (check-equal? (length (transaction-line-items completed)) 1)
    (check-equal? (transaction-subtotal completed) (money 199))))
