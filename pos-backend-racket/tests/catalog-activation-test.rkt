#lang racket

(require (prefix-in db: db)
         json
         racket/file
         rackunit
         "../pos/domain/catalog-item.rkt"
         "../pos/domain/money.rkt"
         "../pos/domain/tax.rkt"
         "../pos/persistence/catalog-snapshot-codec.rkt"
         "../pos/persistence/pos-database-migrations.rkt"
         "../pos/persistence/sqlite-catalog.rkt"
         (submod "../pos/persistence/sqlite-catalog.rkt" test-support))

(define catalog-a
  (hasheq
   'schema_version 2
   'tax_categories
   (list
    (hasheq 'tax_category_id "standard"
            'description "Standard"
            'rate_millionths 100000)
    (hasheq 'tax_category_id "exempt"
            'description "Exempt"
            'rate_millionths 0))
   'items
   (list
    (hasheq 'item_id "item-apples"
            'description "Apples"
            'unit_price_minor_units 199
            'active #t
            'tax_category_id "standard")
    (hasheq 'item_id "item-inactive"
            'description "Inactive Item"
            'unit_price_minor_units 250
            'active #f
            'tax_category_id "exempt"))
   'barcodes
   (list
    (hasheq 'barcode "049000001234" 'item_id "item-apples")
    (hasheq 'barcode "049000001235" 'item_id "item-apples")
    (hasheq 'barcode "000000000099" 'item_id "item-inactive"))))

(define catalog-b
  (hasheq
   'schema_version 2
   'tax_categories
   (list
    (hasheq 'tax_category_id "new-standard"
            'description "New Standard"
            'rate_millionths 88750))
   'items
   (list
    (hasheq 'item_id "item-apples"
            'description "Premium Apples"
            'unit_price_minor_units 299
            'active #t
            'tax_category_id "new-standard")
    (hasheq 'item_id "item-free"
            'description "Free Sample"
            'unit_price_minor_units 0
            'active #t
            'tax_category_id "new-standard"))
   'barcodes
   (list
    (hasheq 'barcode "049000001234" 'item_id "item-apples")
    (hasheq 'barcode "000000000001" 'item_id "item-free"))))

(define catalog-that-triggers-failure
  (hasheq
   'schema_version 2
   'tax_categories
   (list
    (hasheq 'tax_category_id "replacement"
            'description "Replacement"
            'rate_millionths 50000))
   'items
   (list
    (hasheq 'item_id "item-new"
            'description "New Item"
            'unit_price_minor_units 500
            'active #t
            'tax_category_id "replacement"))
   'barcodes
   (list
    (hasheq 'barcode "trigger-failure" 'item_id "item-new"))))

(define legacy-v1-catalog
  (hasheq
   'schema_version 1
   'items
   (list
    (hasheq 'item_id "item-legacy"
            'description "Legacy Item"
            'unit_price_minor_units 125
            'active #t))
   'barcodes
   (list
    (hasheq 'barcode "000000000125" 'item_id "item-legacy"))))

(define (decode-snapshot value)
  (define result
    (json-string->catalog-snapshot (jsexpr->string value)))
  (check-pred catalog-snapshot-decode-success? result)
  (catalog-snapshot-decode-success-snapshot result))

(define snapshot-a (decode-snapshot catalog-a))
(define snapshot-b (decode-snapshot catalog-b))
(define failing-snapshot (decode-snapshot catalog-that-triggers-failure))
(define legacy-v1-snapshot (decode-snapshot legacy-v1-catalog))

(define (call-with-database procedure)
  (define connection (db:sqlite3-connect #:database 'memory))
  (dynamic-wind
    void
    (lambda ()
      (migrate-pos-database! connection)
      (procedure connection))
    (lambda () (db:disconnect connection))))

(define (catalog-rows connection table columns order-column)
  (db:query-rows
   connection
   (format "SELECT ~a FROM ~a ORDER BY ~a"
           columns
           table
           order-column)))

(module+ test
  (test-case "valid activation populates both normalized tables exactly"
    (call-with-database
     (lambda (connection)
       (define summary
         (activate-catalog-snapshot! connection snapshot-a))

       (check-equal? (catalog-snapshot-summary-item-count summary) 2)
       (check-equal? (catalog-snapshot-summary-barcode-count summary) 3)
       (check-equal? (catalog-snapshot-summary-tax-category-count summary) 2)
       (check-equal?
        (catalog-rows connection
                      "catalog_items"
                      "item_id, description, unit_price_minor_units, active"
                      "item_id")
        (list #("item-apples" "Apples" 199 1)
              #("item-inactive" "Inactive Item" 250 0)))
       (check-equal?
        (catalog-rows connection
                      "catalog_barcodes"
                      "barcode, item_id"
                      "barcode")
        (list #("000000000099" "item-inactive")
              #("049000001234" "item-apples")
              #("049000001235" "item-apples")))
       (check-equal?
        (catalog-rows connection
                      "tax_categories"
                      "tax_category_id, description, rate_millionths"
                      "tax_category_id")
        (list #("exempt" "Exempt" 0)
              #("standard" "Standard" 100000)))
       (check-equal?
        (catalog-rows connection
                      "catalog_item_tax_categories"
                      "item_id, tax_category_id"
                      "item_id")
        (list #("item-apples" "standard")
              #("item-inactive" "exempt")))
       (check-equal?
        (catalog-item-tax-rate
         (lookup-catalog-item-by-barcode connection "049000001234"))
        (tax-rate 100000))
       (check-false
        (lookup-catalog-item-by-barcode connection "000000000099")))))

  (test-case "second activation is complete replacement rather than merge"
    (call-with-database
     (lambda (connection)
       (activate-catalog-snapshot! connection snapshot-a)
       (activate-catalog-snapshot! connection snapshot-b)

       (check-equal?
        (catalog-rows connection
                      "catalog_items"
                      "item_id, description, unit_price_minor_units, active"
                      "item_id")
        (list #("item-apples" "Premium Apples" 299 1)
              #("item-free" "Free Sample" 0 1)))
       (check-equal?
        (catalog-rows connection
                      "catalog_barcodes"
                      "barcode, item_id"
                      "barcode")
        (list #("000000000001" "item-free")
              #("049000001234" "item-apples")))
       (check-equal?
        (catalog-rows connection
                      "tax_categories"
                      "tax_category_id, rate_millionths"
                      "tax_category_id")
        (list #("new-standard" 88750)))
       (check-false
        (lookup-catalog-item-by-barcode connection "049000001235"))
       (check-false
        (lookup-catalog-item-by-barcode connection "000000000099")))))

  (test-case "schema v1 activation is complete explicit zero-tax catalog"
    (call-with-database
     (lambda (connection)
       (activate-catalog-snapshot! connection snapshot-a)
       (activate-catalog-snapshot! connection legacy-v1-snapshot)
       (define item
         (lookup-catalog-item-by-barcode connection "000000000125"))
       (check-equal? (catalog-item-tax-category-id item)
                     legacy-zero-tax-category-id)
       (check-equal? (catalog-item-tax-rate item) (tax-rate 0))
       (check-false
        (lookup-catalog-item-by-barcode connection "049000001234"))
       (check-equal?
        (catalog-rows connection
                      "tax_categories"
                      "tax_category_id, rate_millionths"
                      "tax_category_id")
        (list #( "__legacy_zero_tax__" 0))))))

  (test-case "activation never changes transaction facts or command receipts"
    (call-with-database
     (lambda (connection)
       (db:query-exec
        connection
        #<<SQL
INSERT INTO transaction_events
  (transaction_id, stream_sequence, schema_version, event_type, event_json)
VALUES
  ('txn-catalog-preserve',
   1,
   1,
   'transaction_started',
   '{"schema_version":1,"event_type":"transaction_started","payload":{"transaction_id":"txn-catalog-preserve"}}')
SQL
        )
       (db:query-exec
        connection
        #<<SQL
INSERT INTO transaction_command_receipts
  (command_id,
   transaction_id,
   command_schema_version,
   command_type,
   expected_version,
   command_json,
   outcome_kind,
   outcome_code,
   outcome_stream_version)
VALUES
  ('cmd-catalog-preserve',
   'txn-catalog-preserve',
   1,
   'start_transaction',
   0,
   '{"schema_version":1,"command_id":"cmd-catalog-preserve","transaction_id":"txn-catalog-preserve","expected_version":0,"command_type":"start_transaction","payload":{}}',
   'accepted',
   'accepted',
   1)
SQL
        )
       (define events-before
         (db:query-rows connection "SELECT * FROM transaction_events"))
       (define receipts-before
         (db:query-rows
          connection "SELECT * FROM transaction_command_receipts"))

       (activate-catalog-snapshot! connection snapshot-a)
       (activate-catalog-snapshot! connection snapshot-b)

       (check-equal?
        (db:query-rows connection "SELECT * FROM transaction_events")
        events-before)
       (check-equal?
        (db:query-rows
         connection "SELECT * FROM transaction_command_receipts")
        receipts-before))))

  (test-case "database failure rolls back and leaves old catalog usable"
    (call-with-database
     (lambda (connection)
       (activate-catalog-snapshot! connection snapshot-a)
       (db:query-exec
        connection
        #<<SQL
CREATE TRIGGER fail_catalog_barcode_insert
BEFORE INSERT ON catalog_barcodes
WHEN NEW.barcode = 'trigger-failure'
BEGIN
  SELECT RAISE(ABORT, 'simulated catalog activation failure');
END
SQL
        )

       (check-exn
        db:exn:fail:sql?
        (lambda ()
          (activate-catalog-snapshot! connection failing-snapshot)))

       (define original
         (lookup-catalog-item-by-barcode connection "049000001234"))
       (check-equal? (catalog-item-description original) "Apples")
       (check-equal?
        (catalog-item-unit-price original)
        (money 199))
       (check-equal? (catalog-item-tax-rate original) (tax-rate 100000))
       (check-equal?
        (db:query-value connection "SELECT COUNT(*) FROM catalog_items")
        2)
       (check-equal?
        (db:query-value connection "SELECT COUNT(*) FROM catalog_barcodes")
        3)
       (check-equal?
        (db:query-value connection "SELECT COUNT(*) FROM tax_categories")
        2))))

  (test-case "successful activation contains no orphan barcode assignments"
    (call-with-database
     (lambda (connection)
       (activate-catalog-snapshot! connection snapshot-b)
       (check-equal?
        (db:query-value
         connection
         #<<SQL
SELECT COUNT(*)
FROM catalog_barcodes AS barcode_assignment
LEFT JOIN catalog_items AS item
  ON item.item_id = barcode_assignment.item_id
WHERE item.item_id IS NULL
SQL
         )
        0))))

  (test-case "second connection sees old catalog until replacement commits"
    (define directory
      (make-temporary-file "catalog-activation-atomic-~a" 'directory))
    (define database-path (build-path directory "pos.db"))
    (define writer
      (db:sqlite3-connect #:database database-path #:mode 'create))
    (define reader
      (db:sqlite3-connect #:database database-path #:mode 'read/write))
    (dynamic-wind
      void
      (lambda ()
        (migrate-pos-database! writer)
        (activate-catalog-snapshot! writer snapshot-a)
        (define cleared (make-channel))
        (define continue (make-semaphore 0))
        (define result-channel (make-channel))
        (define worker
          (thread
           (lambda ()
             (channel-put
              result-channel
              (with-handlers ([exn:fail? values])
                (activate-catalog-snapshot/observe!
                 writer
                 snapshot-b
                 (lambda ()
                   (channel-put cleared 'cleared)
                   (semaphore-wait continue))))))))

        (check-equal? (channel-get cleared) 'cleared)
        (define before-commit
          (lookup-catalog-item-by-barcode reader "049000001234"))
        (check-equal? (catalog-item-description before-commit) "Apples")
        (check-equal? (catalog-item-unit-price before-commit) (money 199))
        (check-equal? (catalog-item-tax-rate before-commit)
                      (tax-rate 100000))

        (semaphore-post continue)
        (define activation-result (channel-get result-channel))
        (thread-wait worker)
        (when (exn:fail? activation-result)
          (raise activation-result))

        (define after-commit
          (lookup-catalog-item-by-barcode reader "049000001234"))
        (check-equal? (catalog-item-description after-commit)
                      "Premium Apples")
        (check-equal? (catalog-item-unit-price after-commit) (money 299))
        (check-equal? (catalog-item-tax-rate after-commit) (tax-rate 88750)))
      (lambda ()
        (when (db:connected? reader) (db:disconnect reader))
        (when (db:connected? writer) (db:disconnect writer))
        (delete-directory/files directory)))))
