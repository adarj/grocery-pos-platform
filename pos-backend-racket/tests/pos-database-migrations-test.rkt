#lang racket

(require db
         rackunit
         "../pos/domain/money.rkt"
         "../pos/domain/transaction-event.rkt"
         (only-in "../pos/domain/transaction.rkt"
                  replay-transaction
                  replay-succeeded?
                  replay-succeeded-transaction
                  transaction-id
                  transaction-status
                  transaction-subtotal)
         "../pos/persistence/sqlite-transaction-event-store.rkt"
         "../pos/persistence/pos-database-migrations.rkt")

(define (call-with-test-database procedure)
  (define connection
    (sqlite3-connect #:database 'memory))
  (dynamic-wind
    void
    (lambda () (procedure connection))
    (lambda () (disconnect connection))))

;; Frozen fixture for the schema deployed by migration v1. This deliberately
;; does not invoke the current migrator, so the upgrade test starts from a real
;; historical database shape rather than a damaged v2 database.
(define frozen-v1-migrations-table-sql
  #<<SQL
CREATE TABLE pos_schema_migrations (
  version INTEGER PRIMARY KEY
    CHECK (typeof(version) = 'integer' AND version > 0),
  name TEXT NOT NULL
    CHECK (typeof(name) = 'text')
)
SQL
  )

(define frozen-v1-events-table-sql
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

(define frozen-v1-stream-index-sql
  #<<SQL
CREATE UNIQUE INDEX transaction_events_stream_sequence_unique
ON transaction_events (transaction_id, stream_sequence)
SQL
  )

(define (install-frozen-v1! connection)
  (query-exec connection frozen-v1-migrations-table-sql)
  (query-exec connection frozen-v1-events-table-sql)
  (query-exec connection frozen-v1-stream-index-sql)
  (query-exec
   connection
   "INSERT INTO pos_schema_migrations (version, name) VALUES (1, 'create_transaction_events')"))

(define expected-migration-history
  (list #(1 "create_transaction_events")
        #(2 "create_transaction_command_receipts")
        #(3 "create_catalog")
        #(4 "create_tax_categories")))

(module+ test
  (test-case "fresh database migrates through versions 1, 2, 3, and 4"
    (call-with-test-database
     (lambda (connection)
       (migrate-pos-database! connection)

       (check-equal?
        (query-list
         connection
         #<<SQL
SELECT name
FROM sqlite_schema
WHERE type = 'table'
  AND name IN (
    'pos_schema_migrations',
    'transaction_events',
    'transaction_command_receipts',
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
          "pos_schema_migrations"
          "tax_categories"
          "transaction_command_receipts"
          "transaction_events"))
       (check-equal?
        (query-list
         connection
         #<<SQL
SELECT name
FROM sqlite_schema
WHERE type = 'index'
  AND name = 'transaction_events_stream_sequence_unique'
SQL
         )
        '("transaction_events_stream_sequence_unique"))
       (check-equal?
        (query-rows
         connection
         "SELECT version, name FROM pos_schema_migrations ORDER BY version")
        expected-migration-history))))

  (test-case "real v1 database upgrades without changing its event stream"
    (call-with-test-database
     (lambda (connection)
       (install-frozen-v1! connection)
       (define original-events
         (list (transaction-started "txn-upgrade")
               (sale-item-added "049000001234"
                                "Test Apples"
                                (money 199))))
       (define append-result
         (append-transaction-events!
          connection "txn-upgrade" 0 original-events))
       (check-pred journal-append-succeeded? append-result)
       (define rows-before
         (query-rows
          connection
          "SELECT * FROM transaction_events ORDER BY id"))

       (migrate-pos-database! connection)

       (check-equal?
        (query-rows
         connection
         "SELECT version, name FROM pos_schema_migrations ORDER BY version")
        expected-migration-history)
       (check-equal?
        (query-rows connection "SELECT * FROM transaction_events ORDER BY id")
        rows-before)
       (check-equal?
        (query-value
         connection
         #<<SQL
SELECT COUNT(*)
FROM sqlite_schema
WHERE type = 'table' AND name = 'transaction_command_receipts'
SQL
         )
        1)

       (define loaded
         (load-transaction-events connection "txn-upgrade"))
       (check-pred journal-load-succeeded? loaded)
       (check-equal? (journal-load-succeeded-events loaded)
                     original-events)
       (define replayed
         (replay-transaction (journal-load-succeeded-events loaded)))
       (check-pred replay-succeeded? replayed)
       (define recovered (replay-succeeded-transaction replayed))
       (check-equal? (transaction-id recovered) "txn-upgrade")
       (check-equal? (transaction-status recovered) 'open)
       (check-equal? (transaction-subtotal recovered) (money 199)))))

  (test-case "valid v4 migration is safe to run again"
    (call-with-test-database
     (lambda (connection)
       (migrate-pos-database! connection)
       (migrate-pos-database! connection)

       (check-equal?
        (query-rows
         connection
         "SELECT version, name FROM pos_schema_migrations ORDER BY version")
        expected-migration-history)
       (check-equal?
        (query-value
         connection
         "SELECT COUNT(*) FROM sqlite_schema WHERE name = 'transaction_events'")
        1)
       (check-equal?
        (query-value
         connection
         "SELECT COUNT(*) FROM sqlite_schema WHERE name = 'transaction_command_receipts'")
        1))))

  (test-case "migration rejects unknown, missing, or renamed history"
    (call-with-test-database
     (lambda (connection)
       (migrate-pos-database! connection)
       (query-exec
        connection
        "INSERT INTO pos_schema_migrations (version, name) VALUES (5, 'unknown')")
       (check-exn exn:fail?
                  (lambda () (migrate-pos-database! connection)))))

    (call-with-test-database
     (lambda (connection)
       (query-exec connection frozen-v1-migrations-table-sql)
       (query-exec
        connection
        "INSERT INTO pos_schema_migrations (version, name) VALUES (2, 'create_transaction_command_receipts')")
       (check-exn exn:fail?
                  (lambda () (migrate-pos-database! connection)))))

    (call-with-test-database
     (lambda (connection)
       (migrate-pos-database! connection)
       (query-exec
        connection
        "UPDATE pos_schema_migrations SET name = 'renamed' WHERE version = 2")
       (check-exn exn:fail?
                  (lambda () (migrate-pos-database! connection))))))

  (test-case "migration rejects a drifted command-receipt table"
    (call-with-test-database
     (lambda (connection)
       (migrate-pos-database! connection)
       (query-exec connection "DROP TABLE transaction_command_receipts")
       (query-exec
        connection
        #<<SQL
CREATE TABLE transaction_command_receipts (
  command_id TEXT NOT NULL,
  transaction_id TEXT NOT NULL,
  command_schema_version INTEGER NOT NULL,
  command_type TEXT NOT NULL,
  expected_version INTEGER NOT NULL,
  command_json TEXT NOT NULL,
  outcome_kind TEXT NOT NULL,
  outcome_code TEXT NOT NULL,
  outcome_stream_version INTEGER NOT NULL,
  PRIMARY KEY (command_id, transaction_id)
)
SQL
        )
       (check-exn exn:fail?
                  (lambda () (migrate-pos-database! connection))))))

  (test-case "migration rejects a same-named non-unique stream index"
    (call-with-test-database
     (lambda (connection)
       (migrate-pos-database! connection)
       (query-exec
        connection
        "DROP INDEX transaction_events_stream_sequence_unique")
       (query-exec
        connection
        #<<SQL
CREATE INDEX transaction_events_stream_sequence_unique
ON transaction_events (transaction_id, stream_sequence)
SQL
        )

       (check-exn exn:fail?
                  (lambda ()
                    (migrate-pos-database! connection))))))

  (test-case "migration rejects a stream index over the wrong columns"
    (call-with-test-database
     (lambda (connection)
       (migrate-pos-database! connection)
       (query-exec
        connection
        "DROP INDEX transaction_events_stream_sequence_unique")
       (query-exec
        connection
        #<<SQL
CREATE UNIQUE INDEX transaction_events_stream_sequence_unique
ON transaction_events (transaction_id)
SQL
        )

       (check-exn exn:fail?
                  (lambda ()
                    (migrate-pos-database! connection))))))

  (test-case "database constraints continue to defend stream positions"
    (call-with-test-database
     (lambda (connection)
       (migrate-pos-database! connection)
       (define insert-sql
         #<<SQL
INSERT INTO transaction_events
  (transaction_id, stream_sequence, schema_version, event_type, event_json)
VALUES (?, ?, ?, ?, ?)
SQL
         )

       (check-exn
        exn:fail:sql?
        (lambda ()
          (query-exec connection insert-sql
                      "txn-001" 0 1 "transaction_started" "{}")))
       (check-exn
        exn:fail:sql?
        (lambda ()
          (query-exec connection insert-sql
                      sql-null 1 1 "transaction_started" "{}")))

       (query-exec connection insert-sql
                   "txn-001" 1 1 "transaction_started" "{}")
       (check-exn
        exn:fail:sql?
        (lambda ()
          (query-exec connection insert-sql
                      "txn-001" 1 1 "transaction_started" "{}")))))))
