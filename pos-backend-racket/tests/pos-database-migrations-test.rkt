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
        #(4 "create_tax_categories")
        #(5 "create_register_operations")
        #(6 "create_shift_cash_accountability")
        #(7 "create_operator_identity_credentials")))

(define (rewind-current-fixture-to-v6! connection)
  ;; The v1-v6 definitions remain owned by the production migrator. Rewinding
  ;; only the newly owned v7 objects gives this test a populated, valid v6
  ;; prefix without copying historical SQL into another fixture.
  (migrate-pos-database! connection)
  (query-exec connection "DROP TABLE operator_pin_credentials")
  (query-exec connection "DROP TABLE operator_roles")
  (query-exec connection "DROP TABLE operators")
  (query-exec connection "DELETE FROM pos_schema_migrations WHERE version = 7"))

(define m6-business-tables
  '(transaction_events
    transaction_command_receipts
    catalog_items
    catalog_barcodes
    tax_categories
    catalog_item_tax_categories
    register_configuration
    cashiers
    register_shifts
    shift_cash_movements
    shift_cash_reconciliations))

(define (snapshot-m6-business-state connection)
  (for/hash ([table (in-list m6-business-tables)])
    (values table
            (query-rows connection (format "SELECT * FROM ~a ORDER BY rowid" table)))))

(define (populate-v6-business-state! connection)
  (query-exec
   connection
   #<<SQL
INSERT INTO transaction_events
  (transaction_id, stream_sequence, schema_version, event_type, event_json)
VALUES
  ('txn-v6', 1, 1, 'transaction_started',
   '{"schema_version":1,"event_type":"transaction_started","payload":{"transaction_id":"txn-v6"}}')
SQL
   )
  (query-exec
   connection
   #<<SQL
INSERT INTO transaction_command_receipts
  (command_id, transaction_id, command_schema_version, command_type,
   expected_version, command_json, outcome_kind, outcome_code,
   outcome_stream_version)
VALUES
  ('cmd-v6', 'txn-v6', 1, 'start_transaction', 0,
   '{"schema_version":1,"command_id":"cmd-v6","transaction_id":"txn-v6","expected_version":0,"command_type":"start_transaction","payload":{}}',
   'accepted', 'accepted', 1)
SQL
   )
  (query-exec
   connection
   "INSERT INTO catalog_items VALUES ('item-v6', 'V6 Item', 200, 1)")
  (query-exec
   connection
   "INSERT INTO catalog_barcodes VALUES ('000000000006', 'item-v6')")
  (query-exec
   connection
   "INSERT INTO tax_categories VALUES ('tax-v6', 'V6 Tax', 50000)")
  (query-exec
   connection
   "INSERT INTO catalog_item_tax_categories VALUES ('item-v6', 'tax-v6')")
  (query-exec
   connection
   "INSERT INTO register_configuration VALUES (1, 'register-v6', 'V6 Register')")
  (query-exec
   connection
   #<<SQL
INSERT INTO cashiers (cashier_id, display_name, active)
VALUES ('Cashier-A', 'Alice', 1), (' cashier-B ', 'Bob', 0)
SQL
   )
  (query-exec
   connection
   #<<SQL
INSERT INTO register_shifts
  (shift_id, register_id, register_display_name, cashier_id,
   cashier_display_name, opened_at_epoch_ms, closed_at_epoch_ms,
   active_transaction_id)
VALUES
  ('shift-v6', 'register-v6', 'V6 Register', 'Cashier-A', 'Alice',
   900, 2000, NULL)
SQL
   )
  (query-exec
   connection
   #<<SQL
INSERT INTO shift_cash_movements
  (id, shift_id, movement_sequence, movement_type, amount_minor_units,
   transaction_id, recorded_at_epoch_ms)
VALUES
  (1, 'shift-v6', 1, 'opening_float', 500, NULL, 900),
  (2, 'shift-v6', 2, 'cash_sale', 200, 'txn-v6', 1500)
SQL
   )
  (query-exec
   connection
   #<<SQL
INSERT INTO shift_cash_reconciliations
  (shift_id, expected_cash_minor_units, counted_cash_minor_units,
   over_short_minor_units)
VALUES ('shift-v6', 700, 690, -10)
SQL
   ))

(module+ test
  (test-case "migration history and schema validation are reusable without migrating"
    (call-with-test-database
     (lambda (connection)
       (install-frozen-v1! connection)

       (check-equal? current-pos-database-schema-version 7)
       (check-equal?
        (read-pos-database-migration-history connection)
        (list #(1 "create_transaction_events")))
       (check-equal?
        (classify-pos-database-migration-history
         (read-pos-database-migration-history connection))
        'supported-prefix)
       (check-not-exn
        (lambda () (validate-pos-database-schema! connection)))
       (check-exn
        exn:fail?
        (lambda ()
          (validate-pos-database-schema!
           connection
           #:require-current? #t)))

       ;; Inspection/validation must not advance a historical database.
       (check-equal?
        (read-pos-database-migration-history connection)
        (list #(1 "create_transaction_events")))
       (check-equal?
        (query-value
         connection
         #<<SQL
SELECT COUNT(*)
FROM sqlite_schema
WHERE type = 'table' AND name = 'transaction_command_receipts'
SQL
         )
        0))))

  (test-case "current schema validates non-mutatingly and unknown history is rejected"
    (call-with-test-database
     (lambda (connection)
       (migrate-pos-database! connection)
       (define history-before
         (read-pos-database-migration-history connection))

       (check-equal? history-before expected-migration-history)
       (check-equal?
        (classify-pos-database-migration-history history-before)
        'current)
       (check-not-exn
        (lambda ()
          (validate-pos-database-schema!
           connection
           #:require-current? #t)))
       (check-equal?
        (read-pos-database-migration-history connection)
        history-before)

       (query-exec
        connection
        "INSERT INTO pos_schema_migrations (version, name) VALUES (8, 'unknown')")
       (define unsupported-history
         (read-pos-database-migration-history connection))
       (check-equal?
        (classify-pos-database-migration-history unsupported-history)
        'unsupported)
       (check-exn
        exn:fail?
        (lambda () (validate-pos-database-schema! connection))))))

  (test-case "fresh database migrates through versions 1 through 7"
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

  (test-case "v7 backfills active and inactive cashiers without changing M6 state"
    (call-with-test-database
     (lambda (connection)
       (rewind-current-fixture-to-v6! connection)
       (populate-v6-business-state! connection)
       (define m6-state-before (snapshot-m6-business-state connection))

       (migrate-pos-database! connection)

       (check-equal? (snapshot-m6-business-state connection) m6-state-before)
       (check-equal?
        (query-rows
         connection
         "SELECT operator_id, display_name, active FROM operators ORDER BY operator_id")
        (list #(" cashier-B " "Bob" 0)
              #("Cashier-A" "Alice" 1)))
       (check-equal?
        (query-rows
         connection
         "SELECT operator_id, role FROM operator_roles ORDER BY operator_id")
        (list #(" cashier-B " "cashier")
              #("Cashier-A" "cashier")))
       (check-equal?
        (query-value connection "SELECT COUNT(*) FROM operator_pin_credentials")
        0)
       (check-equal?
        (read-pos-database-migration-history connection)
        expected-migration-history))))

  (test-case "v7 schema constrains roles credentials and relational state"
    (call-with-test-database
     (lambda (connection)
       (migrate-pos-database! connection)
       (query-exec connection "PRAGMA foreign_keys = ON")
       (for ([role (in-list '("cashier" "supervisor" "manager"))])
         (define operator-id (string-append "operator-" role))
         (query-exec
          connection
          "INSERT INTO operators (operator_id, display_name, active) VALUES (?, ?, 1)"
          operator-id
          role)
         (query-exec
          connection
          "INSERT INTO operator_roles (operator_id, role) VALUES (?, ?)"
          operator-id
          role))
       (query-exec
        connection
        #<<SQL
INSERT INTO operator_pin_credentials
  (operator_id, password_hash, credential_revision)
VALUES ('operator-manager', '$argon2id$v=19$m=19456,t=2,p=1$c2FsdA$aGFzaA', 1)
SQL
        )
       (check-not-exn
        (lambda ()
          (validate-pos-database-schema! connection #:require-current? #t)))
       (check-exn
        exn:fail:sql?
        (lambda ()
          (query-exec
           connection
           "INSERT INTO operators (operator_id, display_name, active) VALUES ('', 'Bad', 1)")))
       (check-exn
        exn:fail:sql?
        (lambda ()
          (query-exec
           connection
           "UPDATE operator_roles SET role = 'administrator' WHERE operator_id = 'operator-manager'")))
       (check-exn
        exn:fail:sql?
        (lambda ()
          (query-exec
           connection
           "UPDATE operator_pin_credentials SET password_hash = '$argon2i$bad' WHERE operator_id = 'operator-manager'")))
       (check-exn
        exn:fail:sql?
        (lambda ()
          (query-exec
           connection
           "UPDATE operator_pin_credentials SET credential_revision = 0 WHERE operator_id = 'operator-manager'")))

       (query-exec
        connection
        "INSERT INTO operators (operator_id, display_name, active) VALUES ('role-missing', 'Missing Role', 1)")
       (check-exn
        exn:fail?
        (lambda ()
          (validate-pos-database-schema! connection #:require-current? #t))))))

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

  (test-case "valid v7 migration is safe to run again"
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
       "INSERT INTO pos_schema_migrations (version, name) VALUES (8, 'unknown')")
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
