#lang racket

(require (prefix-in db: db))

(provide migrate-transaction-journal!)

(define current-schema-version 1)

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

(define (validate-current-schema connection)
  (unless (schema-object-exists? connection "table" "transaction_events")
    (error 'migrate-transaction-journal!
           "journal schema version 1 is recorded but transaction_events is missing"))
  (unless (schema-object-exists?
           connection
           "index"
           "transaction_events_stream_sequence_unique")
    (error 'migrate-transaction-journal!
           "journal schema version 1 is recorded but its stream index is missing")))

(define (apply-migration-1! connection)
  (db:query-exec connection create-events-table-sql)
  (db:query-exec connection create-stream-sequence-index-sql)
  (db:query-exec
   connection
   #<<SQL
INSERT INTO pos_schema_migrations (version, name)
VALUES (1, 'create_transaction_events')
SQL
   ))

(define (migrate-transaction-journal! connection)
  (unless (db:connection? connection)
    (raise-argument-error
     'migrate-transaction-journal!
     "connection?"
     connection))

  (db:call-with-transaction
   connection
   (lambda ()
     (db:query-exec connection create-migrations-table-sql)
     (define applied-versions
       (db:query-list
        connection
        "SELECT version FROM pos_schema_migrations ORDER BY version ASC"))
     (cond
       [(null? applied-versions)
        (apply-migration-1! connection)]
       [(equal? applied-versions (list current-schema-version))
        (validate-current-schema connection)]
       [else
        (error
         'migrate-transaction-journal!
         "unsupported journal migration history: ~e"
         applied-versions)]))
   #:option 'immediate)
  (void))
