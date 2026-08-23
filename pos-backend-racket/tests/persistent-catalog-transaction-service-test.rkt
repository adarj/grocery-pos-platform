#lang racket

(require (prefix-in db: db)
         json
         rackunit
         "../pos/application/transaction-command-receipt.rkt"
         "../pos/application/transaction-command.rkt"
         "../pos/application/transaction-service.rkt"
         "../pos/domain/catalog-item.rkt"
         "../pos/domain/money.rkt"
         "../pos/domain/tax.rkt"
         "../pos/domain/transaction-event.rkt"
         "../pos/domain/transaction.rkt"
         "../pos/persistence/catalog-snapshot-codec.rkt"
         "../pos/persistence/pos-database-migrations.rkt"
         "../pos/persistence/sqlite-catalog.rkt"
         "../pos/persistence/sqlite-transaction-event-store.rkt")

(define barcode "049000001234")

(define (catalog-jsexpr description price category-id rate)
  (hasheq
   'schema_version 2
   'tax_categories
   (list
    (hasheq 'tax_category_id category-id
            'description (string-append category-id " tax")
            'rate_millionths rate))
   'items
   (list
    (hasheq 'item_id "item-apples"
            'description description
            'unit_price_minor_units price
            'active #t
            'tax_category_id category-id))
   'barcodes
   (list (hasheq 'barcode barcode 'item_id "item-apples"))))

(define (decode-snapshot value)
  (define result
    (json-string->catalog-snapshot (jsexpr->string value)))
  (check-pred catalog-snapshot-decode-success? result)
  (catalog-snapshot-decode-success-snapshot result))

(define snapshot-a
  (decode-snapshot (catalog-jsexpr "Apples" 199 "standard" 100000)))
(define snapshot-b
  (decode-snapshot (catalog-jsexpr "Premium Apples" 299 "exempt" 0)))

(define (call-with-store procedure)
  (define connection (db:sqlite3-connect #:database 'memory))
  (dynamic-wind
    void
    (lambda ()
      (migrate-pos-database! connection)
      (activate-catalog-snapshot! connection snapshot-a)
      (procedure connection))
    (lambda () (db:disconnect connection))))

(define (make-catalog-service connection catalog-lookup)
  (make-transaction-service
   connection
   #:catalog-lookup catalog-lookup))

(define (resolved-receipt result)
  (check-pred transaction-service-command-resolved? result)
  (transaction-service-command-resolved-receipt result))

(module+ test
  (test-case
      "catalog replacement changes new scans but not history or durable retry"
    (call-with-store
     (lambda (connection)
       (define lookup-count 0)
       (define service
         (make-catalog-service
          connection
          (lambda (scanned-barcode)
            (set! lookup-count (add1 lookup-count))
            (lookup-catalog-item-by-barcode connection scanned-barcode))))

       (define start-receipt
         (resolved-receipt
          (transaction-service-execute-command
           service
           (start-transaction-command
            "cmd-catalog-start" "txn-catalog" 0))))
       (check-equal?
        (transaction-command-receipt-outcome-kind start-receipt)
        'accepted)

       (define scan-command
         (scan-barcode-command
          "cmd-catalog-scan" "txn-catalog" 1 barcode))
       (define scan-receipt
         (resolved-receipt
          (transaction-service-execute-command service scan-command)))

       (check-equal?
        (transaction-command-receipt-outcome-kind scan-receipt)
        'accepted)
       (check-equal?
        (transaction-command-receipt-outcome-stream-version scan-receipt)
        2)
       (check-equal? lookup-count 1)

       (define stored-events
         (load-transaction-events connection "txn-catalog"))
       (check-pred journal-load-succeeded? stored-events)
       (check-equal?
        (journal-load-succeeded-events stored-events)
        (list (transaction-started "txn-catalog")
              (taxed-sale-item-added barcode
                                     "Apples"
                                     (money 199)
                                     "standard"
                                     (tax-rate 100000)
                                     (money 20))))

       (activate-catalog-snapshot! connection snapshot-b)
       (define current-item
         (lookup-catalog-item-by-barcode connection barcode))
       (check-equal? (catalog-item-description current-item)
                     "Premium Apples")
       (check-equal? (catalog-item-unit-price current-item) (money 299))
       (check-equal? (catalog-item-tax-rate current-item) (tax-rate 0))

       ;; Receipt recovery precedes transaction replay and current catalog
       ;; lookup, so replacement cannot alter the known command result.
       (define lookups-before-retry lookup-count)
       (define retry-receipt
         (resolved-receipt
          (transaction-service-execute-command service scan-command)))
       (check-equal? retry-receipt scan-receipt)
       (check-equal? lookup-count lookups-before-retry)
       (define events-after-retry
         (load-transaction-events connection "txn-catalog"))
       (check-pred journal-load-succeeded? events-after-retry)
       (check-equal?
        (journal-load-succeeded-events events-after-retry)
        (list (transaction-started "txn-catalog")
              (taxed-sale-item-added barcode
                                     "Apples"
                                     (money 199)
                                     "standard"
                                     (tax-rate 100000)
                                     (money 20))))

       ;; A genuinely new transaction/command observes the replacement.
       (resolved-receipt
        (transaction-service-execute-command
         service
         (start-transaction-command
          "cmd-catalog-new-start" "txn-catalog-new" 0)))
       (resolved-receipt
        (transaction-service-execute-command
         service
         (scan-barcode-command
          "cmd-catalog-new-scan" "txn-catalog-new" 1 barcode)))
       (check-equal? lookup-count (add1 lookups-before-retry))
       (define new-events
         (load-transaction-events connection "txn-catalog-new"))
       (check-pred journal-load-succeeded? new-events)
       (check-equal?
        (journal-load-succeeded-events new-events)
        (list (transaction-started "txn-catalog-new")
              (taxed-sale-item-added
               barcode
               "Premium Apples"
               (money 299)
               "exempt"
               (tax-rate 0)
               (money 0))))

       (define replay-catalog-lookups 0)
       (define replay-service
         (make-catalog-service
          connection
          (lambda (_barcode)
            (set! replay-catalog-lookups (add1 replay-catalog-lookups))
            (error 'test "historical replay consulted the current catalog"))))
       (define recovered-result
         (transaction-service-load-transaction
          replay-service "txn-catalog"))

       (check-pred transaction-service-success? recovered-result)
       (check-equal? replay-catalog-lookups 0)
       (define recovered
         (transaction-service-success-transaction recovered-result))
       (check-equal? (transaction-status recovered) 'open)
       (check-equal? (transaction-subtotal recovered) (money 199))
       (check-equal? (transaction-tax recovered) (money 20))
       (check-equal? (transaction-total recovered) (money 219))
       (define recovered-items (transaction-line-items recovered))
       (check-equal? (length recovered-items) 1)
       (define recovered-item (car recovered-items))
       (check-equal? (transaction-line-item-barcode recovered-item) barcode)
       (check-equal? (transaction-line-item-description recovered-item)
                     "Apples")
       (check-equal? (transaction-line-item-unit-price recovered-item)
                     (money 199))
       (check-equal? (transaction-line-item-tax-amount recovered-item)
                     (money 20)))))

  (test-case
      "unresolved scan uses catalog active when backend first decides it"
    (call-with-store
     (lambda (connection)
       (define service
         (make-catalog-service
          connection
          (lambda (scanned-barcode)
            (lookup-catalog-item-by-barcode connection scanned-barcode))))
       (resolved-receipt
        (transaction-service-execute-command
         service
         (start-transaction-command
          "cmd-unresolved-start" "txn-unresolved" 0)))
       (define persisted-but-unresolved-command
         (scan-barcode-command
          "cmd-unresolved-scan" "txn-unresolved" 1 barcode))

       ;; No receipt or event has established a merchandise interpretation.
       (activate-catalog-snapshot! connection snapshot-b)
       (define receipt
         (resolved-receipt
          (transaction-service-execute-command
           service persisted-but-unresolved-command)))
       (check-equal?
        (transaction-command-receipt-outcome-kind receipt)
        'accepted)
       (define events
         (load-transaction-events connection "txn-unresolved"))
       (check-pred journal-load-succeeded? events)
       (check-equal?
        (journal-load-succeeded-events events)
        (list (transaction-started "txn-unresolved")
              (taxed-sale-item-added
               barcode
               "Premium Apples"
               (money 299)
               "exempt"
               (tax-rate 0)
               (money 0))))))))
