#lang racket

(require (prefix-in db: db)
         json
         net/url
         rackunit
         web-server/http
         "../pos/api/server.rkt"
         "../pos/application/transaction-service.rkt"
         "../pos/domain/money.rkt"
         "../pos/domain/tax.rkt"
         "../pos/domain/transaction-event.rkt"
         (prefix-in op: "../pos/domain/transaction-operational-context.rkt")
         "../pos/persistence/pos-database-migrations.rkt"
         "../pos/persistence/sqlite-transaction-event-store.rkt"
         "../pos/support/readiness.rkt")

(define (request-for method path)
  (request method
           (string->url path)
           '()
           (delay '())
           #f
           "127.0.0.1"
           7340
           "127.0.0.1"))

(define (response-jsexpr response)
  (define output (open-output-bytes))
  ((response-output response) output)
  (bytes->jsexpr (get-output-bytes output)))

(define (response-header response name)
  (define found (headers-assq* name (response-headers response)))
  (and found (header-value found)))

(define (error-code response)
  (hash-ref (hash-ref (response-jsexpr response) 'error) 'code))

(define (get-receipt app transaction-id)
  (app
   (request-for
    #"GET"
    (string-append "/receipts/" transaction-id))))

(define (with-app proc)
  (define connection (db:sqlite3-connect #:database 'memory))
  (dynamic-wind
    (lambda () (migrate-pos-database! connection))
    (lambda ()
      (define service
        (make-transaction-service
         connection
         #:catalog-lookup
         (lambda (_barcode)
           (error 'catalog "receipt query must not use current catalog"))))
      (proc
       connection
       (make-app
        service
        #:readiness-probe
        (lambda ()
          (runtime-ready current-pos-database-schema-version)))))
    (lambda () (db:disconnect connection))))

(define taxed-A
  (taxed-sale-item-added
   "049000001234"
   "Sale-time Apples"
   (money 199)
   "development-standard"
   (tax-rate 100000)
   (money 20)))

(define legacy-B
  (sale-item-added "000000000002" "Removed Legacy Bread" (money 100)))

(define taxed-C
  (taxed-sale-item-added
   "000000000003"
   "Sale-time Milk"
   (money 250)
   "development-reduced"
   (tax-rate 50000)
   (money 13)))

(define (append-completed! connection transaction-id)
  (append-transaction-events!
   connection
   transaction-id
   0
   (list (transaction-started transaction-id)
         taxed-A
         legacy-B
         taxed-C
         (sale-line-removed 1)
         (cash-tendered (money 1000))
         (transaction-completed))))

(module+ test
  (test-case "GET completed receipt returns strict final sale projection"
    (with-app
     (lambda (connection app)
       (append-completed! connection "txn-http-receipt")

       (define response (get-receipt app "txn-http-receipt"))
       (check-equal? (response-code response) 200)
       (define envelope (response-jsexpr response))
       (check-true (hash-ref envelope 'ok))
       (define receipt (hash-ref envelope 'receipt))
       (check-equal? (hash-ref receipt 'schema_version) 1)
       (check-equal? (hash-ref receipt 'transaction_id) "txn-http-receipt")
       (check-equal? (hash-ref receipt 'transaction_version) 7)
       (check-equal? (length (hash-ref receipt 'line_items)) 2)
       (define first-line (first (hash-ref receipt 'line_items)))
       (check-equal? (hash-ref first-line 'barcode) "049000001234")
       (check-equal? (hash-ref first-line 'description) "Sale-time Apples")
       (check-equal? (hash-ref first-line 'unit_price_minor_units) 199)
       (check-equal? (hash-ref first-line 'tax_category_id)
                     "development-standard")
       (check-equal? (hash-ref first-line 'tax_rate_millionths) 100000)
       (check-equal? (hash-ref first-line 'tax_amount_minor_units) 20)
       (check-equal? (hash-ref receipt 'subtotal_minor_units) 449)
       (check-equal? (hash-ref receipt 'tax_minor_units) 33)
       (check-equal? (hash-ref receipt 'total_minor_units) 482)
       (check-equal? (hash-ref receipt 'tendered_cash_minor_units) 1000)
       (check-equal? (hash-ref receipt 'change_due_minor_units) 518)
       (for ([forbidden
              (in-list '(status
                         completed_at
                         created_at
                         timestamp
                         receipt_id))])
         (check-false (hash-has-key? receipt forbidden))))))

  (test-case "legacy receipt line serializes absent tax metadata as null"
    (with-app
     (lambda (connection app)
       (append-transaction-events!
        connection
        "txn-legacy-receipt"
        0
        (list (transaction-started "txn-legacy-receipt")
              (sale-item-added "000000000004" "Legacy Item" (money 25))
              (cash-tendered (money 100))
              (transaction-completed)))

       (define receipt
         (hash-ref
          (response-jsexpr (get-receipt app "txn-legacy-receipt"))
          'receipt))
       (define line (first (hash-ref receipt 'line_items)))
       (check-equal? (hash-ref line 'tax_category_id) 'null)
       (check-equal? (hash-ref line 'tax_rate_millionths) 'null)
       (check-equal? (hash-ref line 'tax_amount_minor_units) 0))))

  (test-case "operational completed transaction returns Receipt Schema v2"
    (with-app
     (lambda (connection app)
       (append-transaction-events!
        connection
        "txn-operational-receipt"
        0
        (list
         (operational-transaction-started
          "txn-operational-receipt"
          (op:transaction-operational-context
           "register-one" "Front Register"
           "cashier-one" "Alice"
           "shift-one" 1000))
         taxed-A
         (cash-tendered (money 500))
         (timestamped-transaction-completed 2000)))

       (define response (get-receipt app "txn-operational-receipt"))
       (check-equal? (response-code response) 200)
       (define receipt
         (hash-ref (response-jsexpr response) 'receipt))
       (check-equal? (hash-ref receipt 'schema_version) 2)
       (check-equal?
        (hash-ref (hash-ref receipt 'register) 'register_id)
        "register-one")
       (check-equal?
        (hash-ref (hash-ref receipt 'register) 'display_name)
        "Front Register")
       (check-equal?
        (hash-ref (hash-ref receipt 'cashier) 'cashier_id)
        "cashier-one")
       (check-equal?
        (hash-ref (hash-ref receipt 'cashier) 'display_name)
        "Alice")
       (check-equal? (hash-ref receipt 'shift_id) "shift-one")
       (check-equal? (hash-ref receipt 'started_at_epoch_ms) 1000)
       (check-equal? (hash-ref receipt 'completed_at_epoch_ms) 2000)
       (check-equal? (hash-ref receipt 'total_minor_units) 219))))

  (test-case "unknown and non-completed receipt queries are distinct"
    (with-app
     (lambda (connection app)
       (define missing (get-receipt app "txn-missing"))
       (check-equal? (response-code missing) 404)
       (check-equal? (error-code missing) "transaction_not_found")

       (for ([transaction-id (in-list '("txn-open" "txn-paid" "txn-voided"))]
             [events
              (in-list
               (list
                (list (transaction-started "txn-open"))
                (list (transaction-started "txn-paid")
                      taxed-A
                      (cash-tendered (money 500)))
                (list (transaction-started "txn-voided")
                      taxed-A
                      (transaction-voided))))])
         (append-transaction-events! connection transaction-id 0 events)
         (define response (get-receipt app transaction-id))
         (check-equal? (response-code response) 409)
         (check-equal? (error-code response) "receipt_not_available")
         (check-equal?
          (hash-ref (hash-ref (response-jsexpr response) 'error) 'reason)
          "transaction_not_completed")))))

  (test-case "receipt replay corruption returns safe recovery error"
    (with-app
     (lambda (connection app)
       (append-transaction-events!
        connection
        "txn-corrupt-http-receipt"
        0
        (list (transaction-started "txn-corrupt-http-receipt")))
       (db:query-exec
        connection
        #<<SQL
INSERT INTO transaction_events
  (transaction_id, stream_sequence, schema_version, event_type, event_json)
VALUES ('txn-corrupt-http-receipt', 2, 1, 'sale_item_added', '{secret-corrupt-receipt')
SQL
        )

       (define response (get-receipt app "txn-corrupt-http-receipt"))
       (check-equal? (response-code response) 500)
       (check-equal? (error-code response) "transaction_recovery_failed")
       (check-false
        (regexp-match?
         #rx"secret"
         (jsexpr->string (response-jsexpr response)))))))

  (test-case "receipt route is GET-only and malformed shapes remain absent"
    (with-app
     (lambda (_connection app)
       (define wrong-method
         (app (request-for #"POST" "/receipts/txn-001")))
       (check-equal? (response-code wrong-method) 405)
       (check-equal? (error-code wrong-method) "method_not_allowed")
       (check-equal? (response-header wrong-method #"Allow") #"GET")

       (for ([path (in-list '("/receipts"
                              "/receipts/"
                              "/receipts/a/b"))])
         (define response (app (request-for #"GET" path)))
         (check-equal? (response-code response) 404)
         (check-equal? (error-code response) "not_found"))))))
