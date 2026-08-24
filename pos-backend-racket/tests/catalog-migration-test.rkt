#lang racket

(require (prefix-in db: db)
         rackunit
         "../pos/persistence/pos-database-migrations.rkt")

(define (call-with-database procedure)
  (define connection (db:sqlite3-connect #:database 'memory))
  (dynamic-wind
    void
    (lambda () (procedure connection))
    (lambda () (db:disconnect connection))))

(define frozen-migrations-table-sql
  #<<SQL
CREATE TABLE pos_schema_migrations (
  version INTEGER PRIMARY KEY
    CHECK (typeof(version) = 'integer' AND version > 0),
  name TEXT NOT NULL
    CHECK (typeof(name) = 'text')
)
SQL
  )

(define frozen-events-table-sql
  #<<SQL
CREATE TABLE transaction_events (
  id INTEGER PRIMARY KEY,
  transaction_id TEXT NOT NULL
    CHECK (typeof(transaction_id) = 'text'),
  stream_sequence INTEGER NOT NULL
    CHECK (typeof(stream_sequence) = 'integer' AND stream_sequence > 0),
  schema_version INTEGER NOT NULL
    CHECK (typeof(schema_version) = 'integer' AND schema_version > 0),
  event_type TEXT NOT NULL
    CHECK (typeof(event_type) = 'text'),
  event_json TEXT NOT NULL
    CHECK (typeof(event_json) = 'text')
)
SQL
  )

(define frozen-events-index-sql
  #<<SQL
CREATE UNIQUE INDEX transaction_events_stream_sequence_unique
ON transaction_events (transaction_id, stream_sequence)
SQL
  )

(define frozen-command-receipts-table-sql
  #<<SQL
CREATE TABLE transaction_command_receipts (
  command_id TEXT PRIMARY KEY NOT NULL
    CHECK (
      typeof(command_id) = 'text'
      AND length(command_id) > 0
    ),
  transaction_id TEXT NOT NULL
    CHECK (
      typeof(transaction_id) = 'text'
      AND length(transaction_id) > 0
    ),
  command_schema_version INTEGER NOT NULL
    CHECK (
      typeof(command_schema_version) = 'integer'
      AND command_schema_version > 0
    ),
  command_type TEXT NOT NULL
    CHECK (
      typeof(command_type) = 'text'
      AND length(command_type) > 0
    ),
  expected_version INTEGER NOT NULL
    CHECK (
      typeof(expected_version) = 'integer'
      AND expected_version >= 0
    ),
  command_json TEXT NOT NULL
    CHECK (
      typeof(command_json) = 'text'
    ),
  outcome_kind TEXT NOT NULL
    CHECK (
      typeof(outcome_kind) = 'text'
      AND outcome_kind IN (
        'accepted',
        'domain_rejected',
        'not_found',
        'already_exists',
        'version_conflict'
      )
    ),
  outcome_code TEXT NOT NULL
    CHECK (
      typeof(outcome_code) = 'text'
      AND length(outcome_code) > 0
    ),
  outcome_stream_version INTEGER NOT NULL
    CHECK (
      typeof(outcome_stream_version) = 'integer'
      AND outcome_stream_version >= 0
    )
)
SQL
  )

(define (install-frozen-v2! connection)
  (db:query-exec connection frozen-migrations-table-sql)
  (db:query-exec connection frozen-events-table-sql)
  (db:query-exec connection frozen-events-index-sql)
  (db:query-exec connection frozen-command-receipts-table-sql)
  (db:query-exec
   connection
   #<<SQL
INSERT INTO pos_schema_migrations (version, name)
VALUES
  (1, 'create_transaction_events'),
  (2, 'create_transaction_command_receipts')
SQL
   )
  (db:query-exec
   connection
   #<<SQL
INSERT INTO transaction_events
  (transaction_id, stream_sequence, schema_version, event_type, event_json)
VALUES (
  'txn-frozen-v2',
  1,
  1,
  'transaction_started',
  '{"schema_version":1,"event_type":"transaction_started","payload":{"transaction_id":"txn-frozen-v2"}}'
)
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
  ('cmd-frozen-v2',
   'txn-frozen-v2',
   1,
   'start_transaction',
   0,
   '{"schema_version":1,"command_id":"cmd-frozen-v2","transaction_id":"txn-frozen-v2","expected_version":0,"command_type":"start_transaction","payload":{}}',
   'accepted',
   'accepted',
   1)
SQL
   ))

(define frozen-catalog-items-table-sql
  #<<SQL
CREATE TABLE catalog_items (
  item_id TEXT PRIMARY KEY NOT NULL
    CHECK (
      typeof(item_id) = 'text'
      AND length(item_id) > 0
    ),
  description TEXT NOT NULL
    CHECK (
      typeof(description) = 'text'
      AND length(description) > 0
    ),
  unit_price_minor_units INTEGER NOT NULL
    CHECK (
      typeof(unit_price_minor_units) = 'integer'
      AND unit_price_minor_units >= 0
    ),
  active INTEGER NOT NULL
    CHECK (
      typeof(active) = 'integer'
      AND active IN (0, 1)
    )
)
SQL
  )

(define frozen-catalog-barcodes-table-sql
  #<<SQL
CREATE TABLE catalog_barcodes (
  barcode TEXT PRIMARY KEY NOT NULL
    CHECK (
      typeof(barcode) = 'text'
      AND length(barcode) > 0
    ),
  item_id TEXT NOT NULL
    CHECK (
      typeof(item_id) = 'text'
      AND length(item_id) > 0
    )
)
SQL
  )

(define (install-frozen-v3! connection)
  (install-frozen-v2! connection)
  (db:query-exec connection frozen-catalog-items-table-sql)
  (db:query-exec connection frozen-catalog-barcodes-table-sql)
  (db:query-exec
   connection
   "INSERT INTO pos_schema_migrations (version, name) VALUES (3, 'create_catalog')")
  (db:query-exec
   connection
   #<<SQL
INSERT INTO catalog_items
  (item_id, description, unit_price_minor_units, active)
VALUES ('item-v3', 'Existing V3 Item', 199, 1)
SQL
   )
  (db:query-exec
   connection
   "INSERT INTO catalog_barcodes (barcode, item_id) VALUES ('049000001234', 'item-v3')"))

(define frozen-tax-categories-table-sql
  #<<SQL
CREATE TABLE tax_categories (
  tax_category_id TEXT PRIMARY KEY NOT NULL
    CHECK (
      typeof(tax_category_id) = 'text'
      AND length(tax_category_id) > 0
    ),
  description TEXT NOT NULL
    CHECK (
      typeof(description) = 'text'
      AND length(description) > 0
    ),
  rate_millionths INTEGER NOT NULL
    CHECK (
      typeof(rate_millionths) = 'integer'
      AND rate_millionths >= 0
      AND rate_millionths <= 1000000
    )
)
SQL
  )

(define frozen-item-tax-mapping-table-sql
  #<<SQL
CREATE TABLE catalog_item_tax_categories (
  item_id TEXT PRIMARY KEY NOT NULL
    CHECK (
      typeof(item_id) = 'text'
      AND length(item_id) > 0
    ),
  tax_category_id TEXT NOT NULL
    CHECK (
      typeof(tax_category_id) = 'text'
      AND length(tax_category_id) > 0
    )
)
SQL
  )

(define (install-frozen-v4! connection)
  (install-frozen-v3! connection)
  (db:query-exec connection frozen-tax-categories-table-sql)
  (db:query-exec connection frozen-item-tax-mapping-table-sql)
  (db:query-exec
   connection
   "INSERT INTO tax_categories VALUES ('legacy', 'Legacy tax', 100000)")
  (db:query-exec
   connection
   "INSERT INTO catalog_item_tax_categories VALUES ('item-v3', 'legacy')")
  (db:query-exec
   connection
   "INSERT INTO pos_schema_migrations (version, name) VALUES (4, 'create_tax_categories')"))

(define frozen-register-configuration-table-sql
  #<<SQL
CREATE TABLE register_configuration (
  singleton_id INTEGER PRIMARY KEY
    CHECK (
      typeof(singleton_id) = 'integer'
      AND singleton_id = 1
    ),
  register_id TEXT NOT NULL
    CHECK (
      typeof(register_id) = 'text'
      AND length(register_id) > 0
    ),
  display_name TEXT NOT NULL
    CHECK (
      typeof(display_name) = 'text'
      AND length(display_name) > 0
    )
)
SQL
  )

(define frozen-cashiers-table-sql
  #<<SQL
CREATE TABLE cashiers (
  cashier_id TEXT PRIMARY KEY NOT NULL
    CHECK (
      typeof(cashier_id) = 'text'
      AND length(cashier_id) > 0
    ),
  display_name TEXT NOT NULL
    CHECK (
      typeof(display_name) = 'text'
      AND length(display_name) > 0
    ),
  active INTEGER NOT NULL
    CHECK (
      typeof(active) = 'integer'
      AND active IN (0, 1)
    )
)
SQL
  )

(define frozen-register-shifts-table-sql
  #<<SQL
CREATE TABLE register_shifts (
  shift_id TEXT PRIMARY KEY NOT NULL
    CHECK (
      typeof(shift_id) = 'text'
      AND length(shift_id) > 0
    ),
  register_id TEXT NOT NULL
    CHECK (
      typeof(register_id) = 'text'
      AND length(register_id) > 0
    ),
  register_display_name TEXT NOT NULL
    CHECK (
      typeof(register_display_name) = 'text'
      AND length(register_display_name) > 0
    ),
  cashier_id TEXT NOT NULL
    CHECK (
      typeof(cashier_id) = 'text'
      AND length(cashier_id) > 0
    ),
  cashier_display_name TEXT NOT NULL
    CHECK (
      typeof(cashier_display_name) = 'text'
      AND length(cashier_display_name) > 0
    ),
  opened_at_epoch_ms INTEGER NOT NULL
    CHECK (
      typeof(opened_at_epoch_ms) = 'integer'
      AND opened_at_epoch_ms >= 0
    ),
  closed_at_epoch_ms INTEGER
    CHECK (
      closed_at_epoch_ms IS NULL
      OR (
        typeof(closed_at_epoch_ms) = 'integer'
        AND closed_at_epoch_ms >= opened_at_epoch_ms
      )
    ),
  active_transaction_id TEXT
    CHECK (
      active_transaction_id IS NULL
      OR (
        typeof(active_transaction_id) = 'text'
        AND length(active_transaction_id) > 0
      )
    ),
  CHECK (
    closed_at_epoch_ms IS NULL
    OR active_transaction_id IS NULL
  )
)
SQL
  )

(define (install-frozen-v5! connection #:open? [open? #f])
  (install-frozen-v4! connection)
  (db:query-exec connection frozen-register-configuration-table-sql)
  (db:query-exec
   connection
   "CREATE UNIQUE INDEX register_configuration_register_id_unique ON register_configuration (register_id)")
  (db:query-exec connection frozen-cashiers-table-sql)
  (db:query-exec connection frozen-register-shifts-table-sql)
  (db:query-exec
   connection
   "CREATE UNIQUE INDEX register_shifts_one_open_per_register ON register_shifts (register_id) WHERE closed_at_epoch_ms IS NULL")
  (db:query-exec
   connection
   "CREATE UNIQUE INDEX register_shifts_active_transaction_unique ON register_shifts (active_transaction_id) WHERE active_transaction_id IS NOT NULL")
  (db:query-exec
   connection
   "INSERT INTO pos_schema_migrations (version, name) VALUES (5, 'create_register_operations')")
  (db:query-exec
   connection
   "INSERT INTO register_configuration VALUES (1, 'register-v5', 'V5 Register')")
  (db:query-exec
   connection
   "INSERT INTO cashiers VALUES ('cashier-v5', 'V5 Cashier', 1)")
  (db:query-exec
   connection
   #<<SQL
INSERT INTO register_shifts
  (shift_id, register_id, register_display_name, cashier_id,
   cashier_display_name, opened_at_epoch_ms, closed_at_epoch_ms,
   active_transaction_id)
VALUES ('shift-v5', 'register-v5', 'V5 Register', 'cashier-v5',
        'V5 Cashier', 1000, ?, NULL)
SQL
   (if open? db:sql-null 2000)))

(define expected-history
  (list #(1 "create_transaction_events")
        #(2 "create_transaction_command_receipts")
        #(3 "create_catalog")
        #(4 "create_tax_categories")
        #(5 "create_register_operations")
        #(6 "create_shift_cash_accountability")))

(module+ test
  (test-case "fresh database creates catalog and tax schema through migration 4"
    (call-with-database
     (lambda (connection)
       (migrate-pos-database! connection)

       (check-equal?
        (db:query-rows
         connection
         "SELECT version, name FROM pos_schema_migrations ORDER BY version")
        expected-history)
       (check-equal?
        (db:query-list
         connection
         #<<SQL
SELECT name
FROM sqlite_schema
WHERE type = 'table'
  AND name IN (
    'catalog_items',
    'catalog_barcodes',
    'tax_categories',
    'catalog_item_tax_categories'
  )
ORDER BY name
SQL
         )
        '("catalog_barcodes"
          "catalog_item_tax_categories"
          "catalog_items"
          "tax_categories")))))

  (test-case "real frozen v4 database upgrades without defaults or prior-data changes"
    (call-with-database
     (lambda (connection)
       (install-frozen-v4! connection)
       (define events-before
         (db:query-rows connection "SELECT * FROM transaction_events"))
       (define receipts-before
         (db:query-rows connection "SELECT * FROM transaction_command_receipts"))
       (define catalog-before
         (db:query-rows connection "SELECT * FROM catalog_items"))
       (define tax-before
         (db:query-rows connection "SELECT * FROM tax_categories"))
       (migrate-pos-database! connection)
       (check-equal?
        (db:query-rows
         connection
         "SELECT version, name FROM pos_schema_migrations ORDER BY version")
        expected-history)
       (check-equal? (db:query-rows connection "SELECT * FROM transaction_events")
                     events-before)
       (check-equal?
        (db:query-rows connection "SELECT * FROM transaction_command_receipts")
        receipts-before)
       (check-equal? (db:query-rows connection "SELECT * FROM catalog_items")
                     catalog-before)
       (check-equal? (db:query-rows connection "SELECT * FROM tax_categories")
                     tax-before)
       (check-equal? (db:query-value connection
                                     "SELECT COUNT(*) FROM register_configuration")
                     0)
       (check-equal? (db:query-value connection "SELECT COUNT(*) FROM cashiers")
                     0))))

  (test-case "real frozen v5 closed shift upgrades without fabricated cash facts"
    (call-with-database
     (lambda (connection)
       (install-frozen-v5! connection)
       (define events-before
         (db:query-rows connection "SELECT * FROM transaction_events"))
       (define receipts-before
         (db:query-rows connection "SELECT * FROM transaction_command_receipts"))
       (define catalog-before
         (db:query-rows connection "SELECT * FROM catalog_items"))
       (define tax-before
         (db:query-rows connection "SELECT * FROM tax_categories"))
       (define operations-before
         (db:query-rows connection "SELECT * FROM register_shifts"))
       (migrate-pos-database! connection)
       (check-equal?
        (db:query-rows
         connection
         "SELECT version, name FROM pos_schema_migrations ORDER BY version")
        expected-history)
       (check-equal? (db:query-rows connection "SELECT * FROM transaction_events")
                     events-before)
       (check-equal?
        (db:query-rows connection "SELECT * FROM transaction_command_receipts")
        receipts-before)
       (check-equal? (db:query-rows connection "SELECT * FROM catalog_items")
                     catalog-before)
       (check-equal? (db:query-rows connection "SELECT * FROM tax_categories")
                     tax-before)
       (check-equal? (db:query-rows connection "SELECT * FROM register_shifts")
                     operations-before)
       (check-equal?
        (db:query-value connection "SELECT COUNT(*) FROM shift_cash_movements")
        0)
       (check-equal?
        (db:query-value connection "SELECT COUNT(*) FROM shift_cash_reconciliations")
        0))))

  (test-case "real frozen v5 open shift blocks cash-accountability migration"
    (call-with-database
     (lambda (connection)
       (install-frozen-v5! connection #:open? #t)
       (check-exn
        #rx"requires every v5 shift to be closed"
        (lambda () (migrate-pos-database! connection)))
       (check-equal?
        (db:query-list
         connection
         "SELECT version FROM pos_schema_migrations ORDER BY version")
        '(1 2 3 4 5))
       (check-equal?
        (db:query-value
         connection
         "SELECT COUNT(*) FROM sqlite_schema WHERE name = 'shift_cash_movements'")
        0))))

  (test-case "migration 6 validates tables indexes and movement uniqueness"
    (for ([table
           (in-list '("shift_cash_movements"
                      "shift_cash_reconciliations"))])
      (call-with-database
       (lambda (connection)
         (migrate-pos-database! connection)
         (db:query-exec connection (format "DROP TABLE ~a" table))
         (check-exn exn:fail?
                    (lambda () (migrate-pos-database! connection))))))
    (for ([index
           (in-list '("shift_cash_movements_shift_sequence_unique"
                      "shift_cash_movements_one_opening_unique"
                      "shift_cash_movements_cash_sale_transaction_unique"))])
      (call-with-database
       (lambda (connection)
         (migrate-pos-database! connection)
         (db:query-exec connection (format "DROP INDEX ~a" index))
         (check-exn exn:fail?
                    (lambda () (migrate-pos-database! connection))))))
    (call-with-database
     (lambda (connection)
       (migrate-pos-database! connection)
       (db:query-exec
        connection
        "INSERT INTO shift_cash_movements VALUES (NULL, 'shift', 1, 'opening_float', 0, NULL, 0)")
       (check-exn
        db:exn:fail:sql?
        (lambda ()
          (db:query-exec
           connection
           "INSERT INTO shift_cash_movements VALUES (NULL, 'shift', 2, 'opening_float', 1, NULL, 1)")))
       (db:query-exec
        connection
        "INSERT INTO shift_cash_movements VALUES (NULL, 'shift', 2, 'cash_sale', 10, 'txn-one', 2)")
       (check-exn
        db:exn:fail:sql?
        (lambda ()
          (db:query-exec
           connection
           "INSERT INTO shift_cash_movements VALUES (NULL, 'other', 1, 'cash_sale', 10, 'txn-one', 2)"))))))

  (test-case "migration 5 validates owned tables and partial indexes"
    (for ([table
           (in-list
            '("register_configuration" "cashiers" "register_shifts"))])
      (call-with-database
       (lambda (connection)
         (migrate-pos-database! connection)
         (db:query-exec connection (format "DROP TABLE ~a" table))
         (check-exn exn:fail?
                    (lambda () (migrate-pos-database! connection))))))
    (for ([index
           (in-list
            '("register_configuration_register_id_unique"
              "register_shifts_one_open_per_register"
              "register_shifts_active_transaction_unique"))])
      (call-with-database
       (lambda (connection)
         (migrate-pos-database! connection)
         (db:query-exec connection (format "DROP INDEX ~a" index))
         (check-exn exn:fail?
                    (lambda () (migrate-pos-database! connection)))))))

  (test-case "migration 5 enforces one open shift and timestamp primitives"
    (call-with-database
     (lambda (connection)
       (migrate-pos-database! connection)
       (define insert
         #<<SQL
INSERT INTO register_shifts
  (shift_id, register_id, register_display_name,
   cashier_id, cashier_display_name, opened_at_epoch_ms,
   closed_at_epoch_ms, active_transaction_id)
VALUES (?, 'register', 'Register', 'cashier', 'Cashier', ?, ?, ?)
SQL
         )
       (db:query-exec connection insert "shift-one" 1000 db:sql-null db:sql-null)
       (check-exn
        db:exn:fail:sql?
        (lambda ()
          (db:query-exec
           connection insert "shift-two" 1001 db:sql-null db:sql-null)))
       (check-exn
        db:exn:fail:sql?
        (lambda ()
          (db:query-exec
           connection insert "shift-bad-time" 1.5 2.0 db:sql-null)))
       (check-exn
        db:exn:fail:sql?
        (lambda ()
          (db:query-exec
           connection insert "shift-bad-active" 1000 1001 7))))))

  (test-case "real frozen v3 database upgrades existing items to zero tax"
    (call-with-database
     (lambda (connection)
       (install-frozen-v3! connection)
       (define events-before
         (db:query-rows connection "SELECT * FROM transaction_events"))
       (define receipts-before
         (db:query-rows connection "SELECT * FROM transaction_command_receipts"))

       (migrate-pos-database! connection)

       (check-equal?
        (db:query-rows
         connection
         "SELECT version, name FROM pos_schema_migrations ORDER BY version")
        expected-history)
       (check-equal?
        (db:query-rows
         connection
         "SELECT item_id, description, unit_price_minor_units, active FROM catalog_items")
        (list #("item-v3" "Existing V3 Item" 199 1)))
       (check-equal?
        (db:query-rows
         connection
         "SELECT tax_category_id, rate_millionths FROM tax_categories")
        (list #("__legacy_zero_tax__" 0)))
       (check-equal?
        (db:query-rows
         connection
         "SELECT item_id, tax_category_id FROM catalog_item_tax_categories")
        (list #("item-v3" "__legacy_zero_tax__")))
       (check-equal? (db:query-rows connection "SELECT * FROM transaction_events")
                     events-before)
       (check-equal?
        (db:query-rows connection "SELECT * FROM transaction_command_receipts")
        receipts-before))))

  (test-case "real frozen v2 database upgrades without changing prior rows"
    (call-with-database
     (lambda (connection)
       (install-frozen-v2! connection)
       (define events-before
         (db:query-rows connection "SELECT * FROM transaction_events"))
       (define receipts-before
         (db:query-rows
          connection "SELECT * FROM transaction_command_receipts"))

       (migrate-pos-database! connection)

       (check-equal?
        (db:query-rows
         connection
         "SELECT version, name FROM pos_schema_migrations ORDER BY version")
        expected-history)
       (check-equal?
        (db:query-rows connection "SELECT * FROM transaction_events")
        events-before)
       (check-equal?
        (db:query-rows
         connection "SELECT * FROM transaction_command_receipts")
        receipts-before))))

  (test-case "valid migration 4 is idempotent"
    (call-with-database
     (lambda (connection)
       (migrate-pos-database! connection)
       (migrate-pos-database! connection)
       (check-equal?
        (db:query-rows
         connection
         "SELECT version, name FROM pos_schema_migrations ORDER BY version")
        expected-history))))

  (test-case "recorded migration 3 requires both catalog tables"
    (for ([table (in-list '("catalog_items" "catalog_barcodes"))])
      (call-with-database
       (lambda (connection)
         (migrate-pos-database! connection)
         (db:query-exec connection (format "DROP TABLE ~a" table))
         (check-exn exn:fail?
                    (lambda () (migrate-pos-database! connection)))))))

  (test-case "recorded migration 4 requires both tax tables"
    (for ([table (in-list '("tax_categories" "catalog_item_tax_categories"))])
      (call-with-database
       (lambda (connection)
         (migrate-pos-database! connection)
         (db:query-exec connection (format "DROP TABLE ~a" table))
         (check-exn exn:fail?
                    (lambda () (migrate-pos-database! connection)))))))

  (test-case "migration 4 validates tax references and exact item coverage"
    (call-with-database
     (lambda (connection)
       (migrate-pos-database! connection)
       (db:query-exec
        connection
        "INSERT INTO catalog_items VALUES ('unmapped', 'Unmapped', 1, 1)")
       (check-exn exn:fail?
                  (lambda () (migrate-pos-database! connection)))))
    (call-with-database
     (lambda (connection)
       (migrate-pos-database! connection)
       (db:query-exec
        connection
        "INSERT INTO catalog_item_tax_categories VALUES ('missing', '__legacy_zero_tax__')")
       (check-exn exn:fail?
                  (lambda () (migrate-pos-database! connection))))))

  (test-case "migration 4 rejects tax table definition drift"
    (call-with-database
     (lambda (connection)
       (migrate-pos-database! connection)
       (db:query-exec connection "DROP TABLE tax_categories")
       (db:query-exec
        connection
        #<<SQL
CREATE TABLE tax_categories (
  tax_category_id TEXT PRIMARY KEY NOT NULL,
  description TEXT NOT NULL,
  rate_millionths INTEGER NOT NULL
)
SQL
        )
       (check-exn exn:fail?
                  (lambda () (migrate-pos-database! connection)))))
    (call-with-database
     (lambda (connection)
       (migrate-pos-database! connection)
       (db:query-exec connection "DROP TABLE catalog_item_tax_categories")
       (db:query-exec
        connection
        #<<SQL
CREATE TABLE catalog_item_tax_categories (
  item_id TEXT PRIMARY KEY NOT NULL,
  wrong_tax_category_id TEXT NOT NULL
)
SQL
        )
       (check-exn exn:fail?
                  (lambda () (migrate-pos-database! connection))))))

  (test-case "migration rejects catalog item column and constraint drift"
    (call-with-database
     (lambda (connection)
       (migrate-pos-database! connection)
       (db:query-exec connection "DROP TABLE catalog_items")
       (db:query-exec
        connection
        #<<SQL
CREATE TABLE catalog_items (
  item_id TEXT PRIMARY KEY NOT NULL,
  description TEXT NOT NULL,
  unit_price_minor_units TEXT NOT NULL,
  active INTEGER NOT NULL
)
SQL
        )
       (check-exn exn:fail?
                  (lambda () (migrate-pos-database! connection)))))
    (call-with-database
     (lambda (connection)
       (migrate-pos-database! connection)
       (db:query-exec connection "DROP TABLE catalog_items")
       (db:query-exec
        connection
        #<<SQL
CREATE TABLE catalog_items (
  item_id TEXT PRIMARY KEY NOT NULL,
  description TEXT NOT NULL,
  unit_price_minor_units INTEGER NOT NULL,
  active INTEGER NOT NULL
)
SQL
        )
       (check-exn exn:fail?
                  (lambda () (migrate-pos-database! connection))))))

  (test-case "migration rejects catalog barcode column and constraint drift"
    (call-with-database
     (lambda (connection)
       (migrate-pos-database! connection)
       (db:query-exec connection "DROP TABLE catalog_barcodes")
       (db:query-exec
        connection
        #<<SQL
CREATE TABLE catalog_barcodes (
  barcode TEXT PRIMARY KEY NOT NULL,
  wrong_item_id TEXT NOT NULL
)
SQL
        )
       (check-exn exn:fail?
                  (lambda () (migrate-pos-database! connection)))))
    (call-with-database
     (lambda (connection)
       (migrate-pos-database! connection)
       (db:query-exec connection "DROP TABLE catalog_barcodes")
       (db:query-exec
        connection
        #<<SQL
CREATE TABLE catalog_barcodes (
  barcode TEXT PRIMARY KEY NOT NULL,
  item_id TEXT NOT NULL
)
SQL
        )
       (check-exn exn:fail?
                  (lambda () (migrate-pos-database! connection)))))))
