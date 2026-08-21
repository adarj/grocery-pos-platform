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

(define expected-history
  (list #(1 "create_transaction_events")
        #(2 "create_transaction_command_receipts")
        #(3 "create_catalog")))

(module+ test
  (test-case "fresh database creates catalog schema as migration 3"
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
  AND name IN ('catalog_items', 'catalog_barcodes')
ORDER BY name
SQL
         )
        '("catalog_barcodes" "catalog_items")))))

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

  (test-case "valid migration 3 is idempotent"
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
