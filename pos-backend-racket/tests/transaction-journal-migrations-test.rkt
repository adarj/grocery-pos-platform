#lang racket

(require db
         rackunit
         "../pos/persistence/transaction-journal-migrations.rkt")

(define (call-with-test-database procedure)
  (define connection
    (sqlite3-connect #:database 'memory))
  (dynamic-wind
    void
    (lambda () (procedure connection))
    (lambda () (disconnect connection))))

(module+ test
  (test-case "migration initializes the transaction journal schema"
    (call-with-test-database
     (lambda (connection)
       (migrate-transaction-journal! connection)

       (check-equal?
        (query-list
         connection
         #<<SQL
SELECT name
FROM sqlite_schema
WHERE type = 'table'
  AND name IN ('pos_schema_migrations', 'transaction_events')
ORDER BY name
SQL
         )
        '("pos_schema_migrations" "transaction_events"))
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
        (query-row
         connection
         "SELECT version, name FROM pos_schema_migrations")
        #(1 "create_transaction_events")))))

  (test-case "migration is safe to run again"
    (call-with-test-database
     (lambda (connection)
       (migrate-transaction-journal! connection)
       (migrate-transaction-journal! connection)

       (check-equal?
        (query-value
         connection
         "SELECT COUNT(*) FROM pos_schema_migrations")
        1)
       (check-equal?
        (query-value
         connection
         "SELECT COUNT(*) FROM sqlite_schema WHERE name = 'transaction_events'")
        1))))

  (test-case "migration rejects inconsistent recorded history"
    (call-with-test-database
     (lambda (connection)
       (migrate-transaction-journal! connection)
       (query-exec
        connection
        "UPDATE pos_schema_migrations SET name = 'unexpected_migration'")

       (check-exn exn:fail?
                  (lambda ()
                    (migrate-transaction-journal! connection)))))

    (call-with-test-database
     (lambda (connection)
       (migrate-transaction-journal! connection)
       (query-exec
        connection
        "UPDATE pos_schema_migrations SET version = 2")

       (check-exn exn:fail?
                  (lambda ()
                    (migrate-transaction-journal! connection))))))

  (test-case "migration rejects a same-named non-unique stream index"
    (call-with-test-database
     (lambda (connection)
       (migrate-transaction-journal! connection)
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
                    (migrate-transaction-journal! connection))))))

  (test-case "migration rejects a stream index over the wrong columns"
    (call-with-test-database
     (lambda (connection)
       (migrate-transaction-journal! connection)
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
                    (migrate-transaction-journal! connection))))))

  (test-case "database constraints defend stream positions"
    (call-with-test-database
     (lambda (connection)
       (migrate-transaction-journal! connection)
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
