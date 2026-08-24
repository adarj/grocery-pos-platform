#lang racket

(require (prefix-in db: db))

(provide migrate-pos-database!)

(struct pos-database-migration (version name apply! validate!)
  #:transparent)

(define migration-1-name "create_transaction_events")
(define migration-2-name "create_transaction_command_receipts")
(define migration-3-name "create_catalog")
(define migration-4-name "create_tax_categories")
(define migration-5-name "create_register_operations")
(define migration-6-name "create_shift_cash_accountability")
(define stream-sequence-index-name
  "transaction_events_stream_sequence_unique")

(define create-migrations-table-sql
  #<<SQL
CREATE TABLE IF NOT EXISTS pos_schema_migrations (
  version INTEGER PRIMARY KEY
    CHECK (typeof(version) = 'integer' AND version > 0),
  name TEXT NOT NULL
    CHECK (typeof(name) = 'text')
)
SQL
  )

(define create-events-table-sql
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

(define create-stream-sequence-index-sql
  #<<SQL
CREATE UNIQUE INDEX transaction_events_stream_sequence_unique
ON transaction_events (transaction_id, stream_sequence)
SQL
  )

(define create-command-receipts-table-sql
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

(define create-catalog-items-table-sql
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

(define create-catalog-barcodes-table-sql
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

(define create-tax-categories-table-sql
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

(define create-catalog-item-tax-categories-table-sql
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

(define create-register-configuration-table-sql
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

(define create-register-id-index-sql
  #<<SQL
CREATE UNIQUE INDEX register_configuration_register_id_unique
ON register_configuration (register_id)
SQL
  )

(define create-cashiers-table-sql
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

(define create-register-shifts-table-sql
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

(define create-open-shift-index-sql
  #<<SQL
CREATE UNIQUE INDEX register_shifts_one_open_per_register
ON register_shifts (register_id)
WHERE closed_at_epoch_ms IS NULL
SQL
  )

(define create-active-transaction-index-sql
  #<<SQL
CREATE UNIQUE INDEX register_shifts_active_transaction_unique
ON register_shifts (active_transaction_id)
WHERE active_transaction_id IS NOT NULL
SQL
  )

(define create-shift-cash-movements-table-sql
  #<<SQL
CREATE TABLE shift_cash_movements (
  id INTEGER PRIMARY KEY,
  shift_id TEXT NOT NULL
    CHECK (
      typeof(shift_id) = 'text'
      AND length(shift_id) > 0
    ),
  movement_sequence INTEGER NOT NULL
    CHECK (
      typeof(movement_sequence) = 'integer'
      AND movement_sequence > 0
    ),
  movement_type TEXT NOT NULL
    CHECK (
      typeof(movement_type) = 'text'
      AND movement_type IN ('opening_float', 'cash_sale')
    ),
  amount_minor_units INTEGER NOT NULL
    CHECK (
      typeof(amount_minor_units) = 'integer'
      AND amount_minor_units >= 0
    ),
  transaction_id TEXT
    CHECK (
      transaction_id IS NULL
      OR (
        typeof(transaction_id) = 'text'
        AND length(transaction_id) > 0
      )
    ),
  recorded_at_epoch_ms INTEGER NOT NULL
    CHECK (
      typeof(recorded_at_epoch_ms) = 'integer'
      AND recorded_at_epoch_ms >= 0
    ),
  CHECK (
    (movement_type = 'opening_float' AND transaction_id IS NULL)
    OR
    (movement_type = 'cash_sale' AND transaction_id IS NOT NULL)
  )
)
SQL
  )

(define create-shift-cash-reconciliations-table-sql
  #<<SQL
CREATE TABLE shift_cash_reconciliations (
  shift_id TEXT PRIMARY KEY NOT NULL
    CHECK (
      typeof(shift_id) = 'text'
      AND length(shift_id) > 0
    ),
  expected_cash_minor_units INTEGER NOT NULL
    CHECK (
      typeof(expected_cash_minor_units) = 'integer'
      AND expected_cash_minor_units >= 0
    ),
  counted_cash_minor_units INTEGER NOT NULL
    CHECK (
      typeof(counted_cash_minor_units) = 'integer'
      AND counted_cash_minor_units >= 0
    ),
  over_short_minor_units INTEGER NOT NULL
    CHECK (
      typeof(over_short_minor_units) = 'integer'
    ),
  CHECK (
    over_short_minor_units =
      counted_cash_minor_units - expected_cash_minor_units
  )
)
SQL
  )

(define create-shift-movement-sequence-index-sql
  #<<SQL
CREATE UNIQUE INDEX shift_cash_movements_shift_sequence_unique
ON shift_cash_movements (shift_id, movement_sequence)
SQL
  )

(define create-shift-opening-index-sql
  #<<SQL
CREATE UNIQUE INDEX shift_cash_movements_one_opening_unique
ON shift_cash_movements (shift_id)
WHERE movement_type = 'opening_float'
SQL
  )

(define create-cash-sale-transaction-index-sql
  #<<SQL
CREATE UNIQUE INDEX shift_cash_movements_cash_sale_transaction_unique
ON shift_cash_movements (transaction_id)
WHERE movement_type = 'cash_sale'
SQL
  )

(define (schema-object-exists? connection type name)
  (= 1
     (db:query-value
      connection
      #<<SQL
SELECT COUNT(*)
FROM sqlite_schema
WHERE type = ? AND name = ?
SQL
      type
      name)))

(define (validate-events-schema connection)
  (unless (schema-object-exists? connection "table" "transaction_events")
    (error 'migrate-pos-database!
           "migration 1 is recorded but transaction_events is missing"))
  (define stream-index-row
    (for/first ([row (in-list
                      (db:query-rows
                       connection
                       "PRAGMA index_list('transaction_events')"))]
                #:when (equal? (vector-ref row 1)
                               stream-sequence-index-name))
      row))
  (unless stream-index-row
    (error 'migrate-pos-database!
           "migration 1 is recorded but its stream index is missing"))
  (unless (= (vector-ref stream-index-row 2) 1)
    (error 'migrate-pos-database!
           "journal stream index must be unique"))
  (define stream-index-columns
    (for/list ([row (in-list
                     (db:query-rows
                      connection
                      (format "PRAGMA index_info('~a')"
                              stream-sequence-index-name)))])
      (vector-ref row 2)))
  (unless (equal? stream-index-columns
                  '("transaction_id" "stream_sequence"))
    (error 'migrate-pos-database!
           "journal stream index has unexpected columns: ~e"
           stream-index-columns)))

(define expected-command-receipt-columns
  (list (vector "command_id" "TEXT" 1 1)
        (vector "transaction_id" "TEXT" 1 0)
        (vector "command_schema_version" "INTEGER" 1 0)
        (vector "command_type" "TEXT" 1 0)
        (vector "expected_version" "INTEGER" 1 0)
        (vector "command_json" "TEXT" 1 0)
        (vector "outcome_kind" "TEXT" 1 0)
        (vector "outcome_code" "TEXT" 1 0)
        (vector "outcome_stream_version" "INTEGER" 1 0)))

(define (normalize-schema-sql sql)
  (string-downcase
   (string-trim (regexp-replace* #px"\\s+" sql " "))))

(define (validate-command-receipts-schema connection)
  (unless (schema-object-exists?
           connection "table" "transaction_command_receipts")
    (error 'migrate-pos-database!
           "migration 2 is recorded but transaction_command_receipts is missing"))

  (define actual-columns
    (for/list ([row (in-list
                     (db:query-rows
                      connection
                      "PRAGMA table_info('transaction_command_receipts')"))])
      (vector (vector-ref row 1)
              (string-upcase (vector-ref row 2))
              (vector-ref row 3)
              (vector-ref row 5))))
  (unless (equal? actual-columns expected-command-receipt-columns)
    (error 'migrate-pos-database!
           "transaction command receipt table has unexpected columns: ~e"
           actual-columns))

  ;; PRAGMA table_info does not expose CHECK expressions. Since this table is
  ;; owned exclusively by migration 2, compare normalized migration DDL to
  ;; detect constraint drift without attempting to parse arbitrary SQL.
  (define recorded-sql
    (db:query-value
     connection
     #<<SQL
SELECT sql
FROM sqlite_schema
WHERE type = 'table' AND name = 'transaction_command_receipts'
SQL
     ))
  (unless (string=? (normalize-schema-sql recorded-sql)
                    (normalize-schema-sql
                     create-command-receipts-table-sql))
    (error 'migrate-pos-database!
           "transaction command receipt table definition has drifted")))

(define expected-catalog-item-columns
  (list (vector "item_id" "TEXT" 1 1)
        (vector "description" "TEXT" 1 0)
        (vector "unit_price_minor_units" "INTEGER" 1 0)
        (vector "active" "INTEGER" 1 0)))

(define expected-catalog-barcode-columns
  (list (vector "barcode" "TEXT" 1 1)
        (vector "item_id" "TEXT" 1 0)))

(define expected-tax-category-columns
  (list (vector "tax_category_id" "TEXT" 1 1)
        (vector "description" "TEXT" 1 0)
        (vector "rate_millionths" "INTEGER" 1 0)))

(define expected-catalog-item-tax-category-columns
  (list (vector "item_id" "TEXT" 1 1)
        (vector "tax_category_id" "TEXT" 1 0)))

(define expected-register-configuration-columns
  (list (vector "singleton_id" "INTEGER" 0 1)
        (vector "register_id" "TEXT" 1 0)
        (vector "display_name" "TEXT" 1 0)))

(define expected-cashier-columns
  (list (vector "cashier_id" "TEXT" 1 1)
        (vector "display_name" "TEXT" 1 0)
        (vector "active" "INTEGER" 1 0)))

(define expected-register-shift-columns
  (list (vector "shift_id" "TEXT" 1 1)
        (vector "register_id" "TEXT" 1 0)
        (vector "register_display_name" "TEXT" 1 0)
        (vector "cashier_id" "TEXT" 1 0)
        (vector "cashier_display_name" "TEXT" 1 0)
        (vector "opened_at_epoch_ms" "INTEGER" 1 0)
        (vector "closed_at_epoch_ms" "INTEGER" 0 0)
        (vector "active_transaction_id" "TEXT" 0 0)))

(define expected-shift-cash-movement-columns
  (list (vector "id" "INTEGER" 0 1)
        (vector "shift_id" "TEXT" 1 0)
        (vector "movement_sequence" "INTEGER" 1 0)
        (vector "movement_type" "TEXT" 1 0)
        (vector "amount_minor_units" "INTEGER" 1 0)
        (vector "transaction_id" "TEXT" 0 0)
        (vector "recorded_at_epoch_ms" "INTEGER" 1 0)))

(define expected-shift-cash-reconciliation-columns
  (list (vector "shift_id" "TEXT" 1 1)
        (vector "expected_cash_minor_units" "INTEGER" 1 0)
        (vector "counted_cash_minor_units" "INTEGER" 1 0)
        (vector "over_short_minor_units" "INTEGER" 1 0)))

(define (validate-owned-table-schema connection
                                     migration-version
                                     table-name
                                     expected-columns
                                     expected-sql)
  (unless (schema-object-exists? connection "table" table-name)
    (error 'migrate-pos-database!
           "migration ~a is recorded but ~a is missing"
           migration-version
           table-name))

  (define actual-columns
    (for/list ([row (in-list
                     (db:query-rows
                      connection
                      (format "PRAGMA table_info('~a')" table-name)))])
      (vector (vector-ref row 1)
              (string-upcase (vector-ref row 2))
              (vector-ref row 3)
              (vector-ref row 5))))
  (unless (equal? actual-columns expected-columns)
    (error 'migrate-pos-database!
           "~a has unexpected columns: ~e"
           table-name
           actual-columns))

  ;; Each table passed here is wholly owned by its creating migration.
  ;; Comparing normalized DDL catches CHECK-constraint drift that PRAGMA
  ;; table_info does not expose without pretending to parse arbitrary SQL.
  (define recorded-sql
    (db:query-value
     connection
     #<<SQL
SELECT sql
FROM sqlite_schema
WHERE type = 'table' AND name = ?
SQL
     table-name))
  (unless (string=? (normalize-schema-sql recorded-sql)
                    (normalize-schema-sql expected-sql))
    (error 'migrate-pos-database!
           "~a definition has drifted"
           table-name)))

(define (validate-catalog-schema connection)
  (validate-owned-table-schema connection
                               3
                               "catalog_items"
                               expected-catalog-item-columns
                               create-catalog-items-table-sql)
  (validate-owned-table-schema connection
                               3
                               "catalog_barcodes"
                               expected-catalog-barcode-columns
                               create-catalog-barcodes-table-sql))

(define (validate-tax-reference-integrity connection)
  (define unmapped-item-count
    (db:query-value
     connection
     #<<SQL
SELECT COUNT(*)
FROM catalog_items AS item
LEFT JOIN catalog_item_tax_categories AS mapping
  ON mapping.item_id = item.item_id
WHERE mapping.item_id IS NULL
SQL
     ))
  (define orphan-item-mapping-count
    (db:query-value
     connection
     #<<SQL
SELECT COUNT(*)
FROM catalog_item_tax_categories AS mapping
LEFT JOIN catalog_items AS item
  ON item.item_id = mapping.item_id
WHERE item.item_id IS NULL
SQL
     ))
  (define orphan-category-mapping-count
    (db:query-value
     connection
     #<<SQL
SELECT COUNT(*)
FROM catalog_item_tax_categories AS mapping
LEFT JOIN tax_categories AS category
  ON category.tax_category_id = mapping.tax_category_id
WHERE category.tax_category_id IS NULL
SQL
     ))
  (unless (zero? unmapped-item-count)
    (error 'migrate-pos-database!
           "catalog contains items without a tax category mapping"))
  (unless (zero? orphan-item-mapping-count)
    (error 'migrate-pos-database!
           "catalog tax mappings contain missing items"))
  (unless (zero? orphan-category-mapping-count)
    (error 'migrate-pos-database!
           "catalog tax mappings contain missing tax categories")))

(define (validate-tax-categories-schema connection)
  (validate-owned-table-schema connection
                               4
                               "tax_categories"
                               expected-tax-category-columns
                               create-tax-categories-table-sql)
  (validate-owned-table-schema
   connection
   4
   "catalog_item_tax_categories"
   expected-catalog-item-tax-category-columns
   create-catalog-item-tax-categories-table-sql)
  (validate-tax-reference-integrity connection))

(define (validate-owned-index-schema connection
                                     migration-version
                                     index-name
                                     expected-sql)
  (unless (schema-object-exists? connection "index" index-name)
    (error 'migrate-pos-database!
           "migration ~a is recorded but index ~a is missing"
           migration-version
           index-name))
  (define recorded-sql
    (db:query-value
     connection
     "SELECT sql FROM sqlite_schema WHERE type = 'index' AND name = ?"
     index-name))
  (unless (and recorded-sql
               (string=? (normalize-schema-sql recorded-sql)
                         (normalize-schema-sql expected-sql)))
    (error 'migrate-pos-database!
           "~a definition has drifted"
           index-name)))

(define (validate-register-operations-schema connection)
  (validate-owned-table-schema
   connection
   5
   "register_configuration"
   expected-register-configuration-columns
   create-register-configuration-table-sql)
  (validate-owned-table-schema
   connection
   5
   "cashiers"
   expected-cashier-columns
   create-cashiers-table-sql)
  (validate-owned-table-schema
   connection
   5
   "register_shifts"
   expected-register-shift-columns
   create-register-shifts-table-sql)
  (validate-owned-index-schema
   connection
   5
   "register_configuration_register_id_unique"
   create-register-id-index-sql)
  (validate-owned-index-schema
   connection
   5
   "register_shifts_one_open_per_register"
   create-open-shift-index-sql)
  (validate-owned-index-schema
   connection
   5
   "register_shifts_active_transaction_unique"
   create-active-transaction-index-sql))

(define (validate-shift-cash-integrity connection)
  (define orphan-movements
    (db:query-value
     connection
     #<<SQL
SELECT COUNT(*)
FROM shift_cash_movements AS movement
LEFT JOIN register_shifts AS shift ON shift.shift_id = movement.shift_id
WHERE shift.shift_id IS NULL
SQL
     ))
  (define orphan-reconciliations
    (db:query-value
     connection
     #<<SQL
SELECT COUNT(*)
FROM shift_cash_reconciliations AS reconciliation
LEFT JOIN register_shifts AS shift ON shift.shift_id = reconciliation.shift_id
WHERE shift.shift_id IS NULL
SQL
     ))
  (define tracked-without-one-opening
    (db:query-value
     connection
     #<<SQL
SELECT COUNT(*)
FROM (
  SELECT shift_id,
         SUM(CASE WHEN movement_type = 'opening_float' THEN 1 ELSE 0 END)
           AS opening_count
  FROM shift_cash_movements
  GROUP BY shift_id
)
WHERE opening_count <> 1
SQL
     ))
  (define open-without-opening
    (db:query-value
     connection
     #<<SQL
SELECT COUNT(*)
FROM register_shifts AS shift
LEFT JOIN shift_cash_movements AS movement
  ON movement.shift_id = shift.shift_id
 AND movement.movement_type = 'opening_float'
WHERE shift.closed_at_epoch_ms IS NULL
  AND movement.id IS NULL
SQL
     ))
  (define noncontiguous-ledgers
    (db:query-value
     connection
     #<<SQL
SELECT COUNT(*)
FROM (
  SELECT shift_id, COUNT(*) AS movement_count,
         MIN(movement_sequence) AS minimum_sequence,
         MAX(movement_sequence) AS maximum_sequence
  FROM shift_cash_movements
  GROUP BY shift_id
)
WHERE minimum_sequence <> 1 OR maximum_sequence <> movement_count
SQL
     ))
  (define inconsistent-reconciliations
    (db:query-value
     connection
     #<<SQL
SELECT COUNT(*)
FROM shift_cash_reconciliations AS reconciliation
JOIN register_shifts AS shift ON shift.shift_id = reconciliation.shift_id
LEFT JOIN (
  SELECT shift_id, SUM(amount_minor_units) AS expected_cash_minor_units
  FROM shift_cash_movements
  GROUP BY shift_id
) AS ledger ON ledger.shift_id = reconciliation.shift_id
WHERE shift.closed_at_epoch_ms IS NULL
   OR ledger.expected_cash_minor_units IS NULL
   OR reconciliation.expected_cash_minor_units <>
        ledger.expected_cash_minor_units
SQL
     ))
  (unless (zero? orphan-movements)
    (error 'migrate-pos-database! "cash movements reference missing shifts"))
  (unless (zero? orphan-reconciliations)
    (error 'migrate-pos-database!
           "cash reconciliations reference missing shifts"))
  (unless (zero? tracked-without-one-opening)
    (error 'migrate-pos-database!
           "tracked shift cash ledgers require exactly one opening movement"))
  (unless (zero? open-without-opening)
    (error 'migrate-pos-database!
           "open v6 shifts require an opening cash movement"))
  (unless (zero? noncontiguous-ledgers)
    (error 'migrate-pos-database!
           "shift cash movement sequences must be contiguous from one"))
  (unless (zero? inconsistent-reconciliations)
    (error 'migrate-pos-database!
           "shift cash reconciliation disagrees with shift or ledger state")))

(define (validate-shift-cash-accountability-schema connection)
  (validate-owned-table-schema
   connection 6 "shift_cash_movements"
   expected-shift-cash-movement-columns
   create-shift-cash-movements-table-sql)
  (validate-owned-table-schema
   connection 6 "shift_cash_reconciliations"
   expected-shift-cash-reconciliation-columns
   create-shift-cash-reconciliations-table-sql)
  (validate-owned-index-schema
   connection 6 "shift_cash_movements_shift_sequence_unique"
   create-shift-movement-sequence-index-sql)
  (validate-owned-index-schema
   connection 6 "shift_cash_movements_one_opening_unique"
   create-shift-opening-index-sql)
  (validate-owned-index-schema
   connection 6 "shift_cash_movements_cash_sale_transaction_unique"
   create-cash-sale-transaction-index-sql)
  (validate-shift-cash-integrity connection))

(define (apply-migration-1! connection)
  (db:query-exec connection create-events-table-sql)
  (db:query-exec connection create-stream-sequence-index-sql))

(define (apply-migration-2! connection)
  (db:query-exec connection create-command-receipts-table-sql))

(define (apply-migration-3! connection)
  (db:query-exec connection create-catalog-items-table-sql)
  (db:query-exec connection create-catalog-barcodes-table-sql))

(define (apply-migration-4! connection)
  (db:query-exec connection create-tax-categories-table-sql)
  (db:query-exec connection create-catalog-item-tax-categories-table-sql)
  (db:query-exec
   connection
   #<<SQL
INSERT INTO tax_categories
  (tax_category_id, description, rate_millionths)
VALUES ('__legacy_zero_tax__', 'Legacy zero tax', 0)
SQL
   )
  (db:query-exec
   connection
   #<<SQL
INSERT INTO catalog_item_tax_categories (item_id, tax_category_id)
SELECT item_id, '__legacy_zero_tax__'
FROM catalog_items
SQL
   ))

(define (apply-migration-5! connection)
  (db:query-exec connection create-register-configuration-table-sql)
  (db:query-exec connection create-register-id-index-sql)
  (db:query-exec connection create-cashiers-table-sql)
  (db:query-exec connection create-register-shifts-table-sql)
  (db:query-exec connection create-open-shift-index-sql)
  (db:query-exec connection create-active-transaction-index-sql))

(define (apply-migration-6! connection)
  (when (positive?
         (db:query-value
          connection
          "SELECT COUNT(*) FROM register_shifts WHERE closed_at_epoch_ms IS NULL"))
    (error 'migrate-pos-database!
           "cash-accountability migration requires every v5 shift to be closed"))
  (db:query-exec connection create-shift-cash-movements-table-sql)
  (db:query-exec connection create-shift-cash-reconciliations-table-sql)
  (db:query-exec connection create-shift-movement-sequence-index-sql)
  (db:query-exec connection create-shift-opening-index-sql)
  (db:query-exec connection create-cash-sale-transaction-index-sql))

(define migrations
  (list
   (pos-database-migration 1
                           migration-1-name
                           apply-migration-1!
                           validate-events-schema)
   (pos-database-migration 2
                           migration-2-name
                           apply-migration-2!
                           validate-command-receipts-schema)
   (pos-database-migration 3
                           migration-3-name
                           apply-migration-3!
                           validate-catalog-schema)
   (pos-database-migration 4
                           migration-4-name
                           apply-migration-4!
                           validate-tax-categories-schema)
   (pos-database-migration 5
                           migration-5-name
                           apply-migration-5!
                           validate-register-operations-schema)
   (pos-database-migration 6
                           migration-6-name
                           apply-migration-6!
                           validate-shift-cash-accountability-schema)))

(define (migration-row-matches? row migration)
  (and (= (vector-length row) 2)
       (equal? (vector-ref row 0)
               (pos-database-migration-version migration))
       (equal? (vector-ref row 1)
               (pos-database-migration-name migration))))

(define (valid-migration-prefix? applied-migrations)
  (and (<= (length applied-migrations) (length migrations))
       (for/and ([row (in-list applied-migrations)]
                 [migration (in-list migrations)])
         (migration-row-matches? row migration))))

(define (record-migration! connection migration)
  (db:query-exec
   connection
   "INSERT INTO pos_schema_migrations (version, name) VALUES (?, ?)"
   (pos-database-migration-version migration)
   (pos-database-migration-name migration)))

(define (migrate-pos-database! connection)
  (unless (db:connection? connection)
    (raise-argument-error
     'migrate-pos-database!
     "connection?"
     connection))

  (db:call-with-transaction
   connection
   (lambda ()
     (db:query-exec connection create-migrations-table-sql)
     (define applied-migrations
       (db:query-rows
        connection
        "SELECT version, name FROM pos_schema_migrations ORDER BY version ASC"))
     (unless (valid-migration-prefix? applied-migrations)
       (error
        'migrate-pos-database!
        "unsupported POS database migration history: ~e"
        applied-migrations))

     (define applied-count (length applied-migrations))
     (for ([migration (in-list (take migrations applied-count))])
       ((pos-database-migration-validate! migration) connection))
     (for ([migration (in-list (drop migrations applied-count))])
       ((pos-database-migration-apply! migration) connection)
       ((pos-database-migration-validate! migration) connection)
       (record-migration! connection migration)))
   #:option 'immediate)
  (void))
