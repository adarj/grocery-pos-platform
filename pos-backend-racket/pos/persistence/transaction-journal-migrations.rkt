#lang racket

(require (prefix-in db: db))

(provide migrate-transaction-journal!)

(define current-schema-version 1)
(define migration-1-name "create_transaction_events")
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
  (define stream-index-row
    (for/first ([row (in-list
                      (db:query-rows
                       connection
                       "PRAGMA index_list('transaction_events')"))]
                #:when (equal? (vector-ref row 1)
                               stream-sequence-index-name))
      row))
  (unless stream-index-row
    (error 'migrate-transaction-journal!
           "journal schema version 1 is recorded but its stream index is missing"))
  (unless (= (vector-ref stream-index-row 2) 1)
    (error 'migrate-transaction-journal!
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
    (error 'migrate-transaction-journal!
           "journal stream index has unexpected columns: ~e"
           stream-index-columns)))

(define (apply-migration-1! connection)
  (db:query-exec connection create-events-table-sql)
  (db:query-exec connection create-stream-sequence-index-sql)
  (db:query-exec
   connection
   "INSERT INTO pos_schema_migrations (version, name) VALUES (?, ?)"
   current-schema-version
   migration-1-name))

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
     (define applied-migrations
       (db:query-rows
        connection
        "SELECT version, name FROM pos_schema_migrations ORDER BY version ASC"))
     (cond
       [(null? applied-migrations)
        (apply-migration-1! connection)]
       [(equal? applied-migrations
                (list (vector current-schema-version migration-1-name)))
        (validate-current-schema connection)]
       [else
        (error
         'migrate-transaction-journal!
         "unsupported journal migration history: ~e"
         applied-migrations)]))
   #:option 'immediate)
  (void))
