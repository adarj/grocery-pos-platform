#lang racket

(require (prefix-in db: db))

(provide migrate-pos-database!)

(struct pos-database-migration (version name apply! validate!)
  #:transparent)

(define migration-1-name "create_transaction_events")
(define migration-2-name "create_transaction_command_receipts")
(define migration-3-name "create_catalog")
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

  ;; Both catalog tables are wholly owned by migration 3. Comparing their
  ;; normalized DDL catches CHECK-constraint drift that PRAGMA table_info does
  ;; not expose without pretending to parse arbitrary SQL.
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

(define (apply-migration-1! connection)
  (db:query-exec connection create-events-table-sql)
  (db:query-exec connection create-stream-sequence-index-sql))

(define (apply-migration-2! connection)
  (db:query-exec connection create-command-receipts-table-sql))

(define (apply-migration-3! connection)
  (db:query-exec connection create-catalog-items-table-sql)
  (db:query-exec connection create-catalog-barcodes-table-sql))

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
                           validate-catalog-schema)))

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
