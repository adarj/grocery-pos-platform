#lang racket

(require (prefix-in db: db)
         rackunit
         "../pos/application/transaction-command-receipt.rkt"
         "../pos/application/transaction-command.rkt"
         "../pos/application/transaction-service.rkt"
         "../pos/domain/catalog-item.rkt"
         "../pos/domain/money.rkt"
         "../pos/domain/transaction-event.rkt"
         "../pos/domain/transaction.rkt"
         "../pos/persistence/pos-database-migrations.rkt"
         "../pos/persistence/sqlite-catalog.rkt"
         "../pos/persistence/sqlite-transaction-event-store.rkt")

(define barcode "049000001234")

(define (call-with-store procedure)
  (define connection (db:sqlite3-connect #:database 'memory))
  (dynamic-wind
    void
    (lambda ()
      (migrate-pos-database! connection)
      (db:query-exec
       connection
       #<<SQL
INSERT INTO catalog_items
  (item_id, description, unit_price_minor_units, active)
VALUES ('item-apples', 'Apples', 199, 1)
SQL
       )
      (db:query-exec
       connection
       "INSERT INTO catalog_barcodes (barcode, item_id) VALUES (?, ?)"
       barcode
       "item-apples")
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
      "persistent catalog scan snapshots sale-time facts and replay ignores edits"
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
              (sale-item-added barcode "Apples" (money 199))))

       (db:query-exec
        connection
        #<<SQL
UPDATE catalog_items
SET description = 'Premium Apples',
    unit_price_minor_units = 299
WHERE item_id = 'item-apples'
SQL
        )
       (define current-item
         (lookup-catalog-item-by-barcode connection barcode))
       (check-equal? (catalog-item-description current-item)
                     "Premium Apples")
       (check-equal? (catalog-item-unit-price current-item) (money 299))

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
       (define recovered-items (transaction-line-items recovered))
       (check-equal? (length recovered-items) 1)
       (define recovered-item (car recovered-items))
       (check-equal? (transaction-line-item-barcode recovered-item) barcode)
       (check-equal? (transaction-line-item-description recovered-item)
                     "Apples")
       (check-equal? (transaction-line-item-unit-price recovered-item)
                     (money 199))))))
