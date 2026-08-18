#lang racket

(require (prefix-in db: db))

(provide migrate-transaction-journal!)

(struct journal-migration (version name apply! validate!)
  #:transparent)

(define migration-1-name "create_transaction_events")
(define migration-2-name "create_transaction_command_receipts")
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
    (error 'migrate-transaction-journal!
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
    (error 'migrate-transaction-journal!
           "migration 1 is recorded but its stream index is missing"))
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
    (error 'migrate-transaction-journal!
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
    (error 'migrate-transaction-journal!
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
    (error 'migrate-transaction-journal!
           "transaction command receipt table definition has drifted")))

(define (apply-migration-1! connection)
  (db:query-exec connection create-events-table-sql)
  (db:query-exec connection create-stream-sequence-index-sql))

(define (apply-migration-2! connection)
  (db:query-exec connection create-command-receipts-table-sql))

(define migrations
  (list
   (journal-migration 1
                      migration-1-name
                      apply-migration-1!
                      validate-events-schema)
   (journal-migration 2
                      migration-2-name
                      apply-migration-2!
                      validate-command-receipts-schema)))

(define (migration-row-matches? row migration)
  (and (= (vector-length row) 2)
       (equal? (vector-ref row 0)
               (journal-migration-version migration))
       (equal? (vector-ref row 1)
               (journal-migration-name migration))))

(define (valid-migration-prefix? applied-migrations)
  (and (<= (length applied-migrations) (length migrations))
       (for/and ([row (in-list applied-migrations)]
                 [migration (in-list migrations)])
         (migration-row-matches? row migration))))

(define (record-migration! connection migration)
  (db:query-exec
   connection
   "INSERT INTO pos_schema_migrations (version, name) VALUES (?, ?)"
   (journal-migration-version migration)
   (journal-migration-name migration)))

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
     (unless (valid-migration-prefix? applied-migrations)
       (error
        'migrate-transaction-journal!
        "unsupported journal migration history: ~e"
        applied-migrations))

     (define applied-count (length applied-migrations))
     (for ([migration (in-list (take migrations applied-count))])
       ((journal-migration-validate! migration) connection))
     (for ([migration (in-list (drop migrations applied-count))])
       ((journal-migration-apply! migration) connection)
       ((journal-migration-validate! migration) connection)
       (record-migration! connection migration)))
   #:option 'immediate)
  (void))
