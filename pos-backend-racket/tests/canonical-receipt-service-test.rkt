#lang racket

(require (prefix-in db: db)
         rackunit
         "../pos/application/transaction-service.rkt"
         "../pos/domain/canonical-receipt.rkt"
         "../pos/domain/money.rkt"
         "../pos/domain/transaction-event.rkt"
         "../pos/persistence/pos-database-migrations.rkt"
         "../pos/persistence/sqlite-transaction-event-store.rkt")

(define (with-service proc)
  (define connection (db:sqlite3-connect #:database 'memory))
  (dynamic-wind
    (lambda () (migrate-pos-database! connection))
    (lambda ()
      (define catalog-lookups 0)
      (define service
        (make-transaction-service
         connection
         #:catalog-lookup
         (lambda (_barcode)
           (set! catalog-lookups (add1 catalog-lookups))
           (error 'catalog "receipt lookup must not query the catalog"))))
      (proc connection service (lambda () catalog-lookups)))
    (lambda () (db:disconnect connection))))

(define (append-completed! connection transaction-id)
  (append-transaction-events!
   connection
   transaction-id
   0
   (list (transaction-started transaction-id)
         (sale-item-added "049000001234" "Historical Apples" (money 199))
         (cash-tendered (money 500))
         (transaction-completed))))

(module+ test
  (test-case "service loads completed receipt through journal replay only"
    (with-service
     (lambda (connection service catalog-lookups)
       (append-completed! connection "txn-service-receipt")

       (define result
         (transaction-service-load-canonical-receipt
          service
          "txn-service-receipt"))

       (check-pred transaction-service-receipt-success? result)
       (define receipt
         (transaction-service-receipt-success-receipt result))
       (check-equal? (canonical-receipt-transaction-id receipt)
                     "txn-service-receipt")
       (check-equal? (canonical-receipt-transaction-version receipt) 4)
       (check-equal? (catalog-lookups) 0))))

  (test-case "service distinguishes missing and non-completed transactions"
    (with-service
     (lambda (connection service _catalog-lookups)
       (append-transaction-events!
        connection
        "txn-open-receipt"
        0
        (list (transaction-started "txn-open-receipt")))

       (define missing
         (transaction-service-load-canonical-receipt
          service
          "txn-missing-receipt"))
       (check-pred transaction-service-receipt-not-found? missing)
       (check-equal?
        (transaction-service-receipt-not-found-transaction-id missing)
        "txn-missing-receipt")

       (define open
         (transaction-service-load-canonical-receipt
          service
          "txn-open-receipt"))
       (check-pred transaction-service-receipt-not-available? open)
       (check-equal?
        (transaction-service-receipt-not-available-reason open)
        'transaction-not-completed))))

  (test-case "receipt load preserves transaction replay failure"
    (with-service
     (lambda (connection service _catalog-lookups)
       (append-transaction-events!
        connection
        "txn-corrupt-receipt"
        0
        (list (transaction-started "txn-corrupt-receipt")))
       (db:query-exec
        connection
        #<<SQL
INSERT INTO transaction_events
  (transaction_id, stream_sequence, schema_version, event_type, event_json)
VALUES ('txn-corrupt-receipt', 2, 1, 'sale_item_added', '{corrupt-receipt-event')
SQL
        )

       (define result
         (transaction-service-load-canonical-receipt
          service
          "txn-corrupt-receipt"))
       (check-pred transaction-service-recovery-failed? result)))))
