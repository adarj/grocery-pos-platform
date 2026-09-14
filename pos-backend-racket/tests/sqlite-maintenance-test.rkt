#lang racket

(require (prefix-in db: db)
         racket/file
         racket/string
         rackunit
         "../pos/domain/transaction-event.rkt"
         "../pos/persistence/pos-database-migrations.rkt"
         "../pos/persistence/sqlite-connection.rkt"
         "../pos/persistence/sqlite-maintenance.rkt"
         "../pos/persistence/sqlite-transaction-event-store.rkt"
         "../pos/runtime.rkt")

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

(define (call-with-temporary-directory procedure)
  (define directory
    (make-temporary-file "grocery-pos-maintenance-~a" 'directory))
  (dynamic-wind
    void
    (lambda () (procedure directory))
    (lambda () (delete-directory/files directory))))

(define (call-with-raw-connection database-path mode procedure)
  (define connection
    (db:sqlite3-connect #:database database-path #:mode mode))
  (dynamic-wind
    void
    (lambda () (procedure connection))
    (lambda ()
      (when (db:connected? connection)
        (db:disconnect connection)))))

(define (call-with-production-connection database-path procedure)
  (define connection
    (open-pos-sqlite-connection database-path 'read/write))
  (dynamic-wind
    void
    (lambda () (procedure connection))
    (lambda ()
      (when (db:connected? connection)
        (db:disconnect connection)))))

(define (install-frozen-v1-file! database-path)
  (call-with-raw-connection
   database-path
   'create
   (lambda (connection)
     (db:query-exec connection frozen-v1-migrations-table-sql)
     (db:query-exec connection frozen-v1-events-table-sql)
     (db:query-exec connection frozen-v1-stream-index-sql)
     (db:query-exec
      connection
      "INSERT INTO pos_schema_migrations (version, name) VALUES (1, 'create_transaction_events')"))))

(define (partial-files directory)
  (for/list ([entry (in-list (directory-list directory))]
             #:when (string-suffix? (path->string entry) ".partial"))
    entry))

(module+ test
  (test-case "read-only inspection never creates or migrates a database"
    (call-with-temporary-directory
     (lambda (directory)
       (define missing-path (build-path directory "missing.sqlite"))
       (define missing-info (inspect-pos-sqlite-database missing-path))
       (check-false (sqlite-database-info-file-exists? missing-info))
       (check-false (sqlite-database-info-read-only-openable? missing-info))
       (check-equal? (sqlite-database-info-migration-status missing-info)
                     'missing-file)
       (check-false (file-exists? missing-path))
       (check-exn
        exn:fail?
        (lambda ()
          (call-with-pos-sqlite-inspection-connection
           missing-path void)))
       (check-false (file-exists? missing-path))

       (define v1-path (build-path directory "v1.sqlite"))
       (install-frozen-v1-file! v1-path)
       (define bytes-before (file->bytes v1-path))
       (define info (inspect-pos-sqlite-database v1-path))
       (check-true (sqlite-database-info-read-only-openable? info))
       (check-equal? (sqlite-database-info-journal-mode info) "delete")
       (check-equal?
        (sqlite-database-info-migration-history info)
        (list #(1 "create_transaction_events")))
       (check-equal?
        (sqlite-database-info-highest-applied-migration-version info)
        1)
       (check-equal?
        (sqlite-database-info-current-supported-migration-version info)
        7)
       (check-equal? (sqlite-database-info-migration-status info)
                     'supported-prefix)
       (check-true (sqlite-database-info-schema-valid? info))
       (check-equal? (file->bytes v1-path) bytes-before)
       (call-with-raw-connection
        v1-path
        'read-only
        (lambda (connection)
          (check-equal?
           (db:query-value
            connection
            "SELECT COUNT(*) FROM pos_schema_migrations")
           1)
          (check-equal?
           (db:query-value
            connection
            "SELECT COUNT(*) FROM sqlite_schema WHERE name = 'transaction_command_receipts'")
           0))))))

  (test-case "inspection reports current metadata, sidecars, unsupported history, and drift"
    (call-with-temporary-directory
     (lambda (directory)
       (define database-path (build-path directory "pos.sqlite"))
       (initialize-sqlite-database! database-path)
       (define info (inspect-pos-sqlite-database database-path))
       (check-true (sqlite-database-info-file-exists? info))
       (check-true (sqlite-database-info-regular-file? info))
       (check-true (sqlite-database-info-read-only-openable? info))
       (check-equal? (sqlite-database-info-journal-mode info) "wal")
       (check-equal? (sqlite-database-info-migration-status info) 'current)
       (check-equal?
        (length (sqlite-database-info-migration-history info))
        7)
       (check-equal?
        (sqlite-database-info-highest-applied-migration-version info)
        7)
       (check-true (sqlite-database-info-schema-valid? info))
       (check-pred exact-positive-integer?
                   (sqlite-database-info-page-size info))
       (check-pred exact-positive-integer?
                   (sqlite-database-info-page-count info))
       (check-pred exact-nonnegative-integer?
                   (sqlite-database-info-freelist-count info))
       (check-pred exact-positive-integer?
                   (sqlite-database-info-main-file-size info))
       (check-true (boolean? (sqlite-database-info-wal-file-exists? info)))
       (check-true (boolean? (sqlite-database-info-shm-file-exists? info)))

       (call-with-production-connection
        database-path
        (lambda (connection)
          (db:query-exec
           connection
           "INSERT INTO pos_schema_migrations (version, name) VALUES (8, 'unknown')")))
       (define unsupported (inspect-pos-sqlite-database database-path))
       (check-equal? (sqlite-database-info-migration-status unsupported)
                     'unsupported)
       (check-false (sqlite-database-info-schema-valid? unsupported))

       (call-with-production-connection
        database-path
        (lambda (connection)
          (db:query-exec
           connection
          "DELETE FROM pos_schema_migrations WHERE version = 8")
          (db:query-exec connection "DROP TABLE transaction_command_receipts")))
       (define drifted (inspect-pos-sqlite-database database-path))
       (check-equal? (sqlite-database-info-migration-status drifted) 'invalid)
       (check-false (sqlite-database-info-schema-valid? drifted)))))

  (test-case "inspection connections close after successful and failed callbacks"
    (call-with-temporary-directory
     (lambda (directory)
       (define database-path (build-path directory "pos.sqlite"))
       (initialize-sqlite-database! database-path)
       (define successful-connection #f)
       (check-equal?
        (call-with-pos-sqlite-inspection-connection
         database-path
         (lambda (connection)
           (set! successful-connection connection)
           (db:query-value connection "SELECT 42")))
        42)
       (check-false (db:connected? successful-connection))

       (define failing-connection #f)
       (check-exn
        exn:fail?
        (lambda ()
          (call-with-pos-sqlite-inspection-connection
           database-path
           (lambda (connection)
             (set! failing-connection connection)
             (error 'test "simulated inspection failure")))))
       (check-false (db:connected? failing-connection)))))

  (test-case "quick and full integrity checks interpret SQLite health results"
    (call-with-temporary-directory
     (lambda (directory)
       (define database-path (build-path directory "pos.sqlite"))
       (initialize-sqlite-database! database-path)
       (define quick (quick-check-pos-sqlite-database database-path))
       (check-true (sqlite-check-result-healthy? quick))
       (check-equal? (sqlite-check-result-messages quick) '("ok"))

       (define full (integrity-check-pos-sqlite-database database-path))
       (check-true (sqlite-integrity-result-healthy? full))
       (check-equal? (sqlite-integrity-result-messages full) '("ok"))
       (check-equal?
        (sqlite-integrity-result-foreign-key-violations full)
        '()))))

  (test-case "malformed files fail closed without replacement or repair"
    (call-with-temporary-directory
     (lambda (directory)
       (define malformed-path (build-path directory "malformed.sqlite"))
       (call-with-output-file
        malformed-path
        #:exists 'error
        (lambda (output) (display "not a sqlite database" output)))
       (define bytes-before (file->bytes malformed-path))

       (define info (inspect-pos-sqlite-database malformed-path))
       (check-true (sqlite-database-info-file-exists? info))
       (check-false (sqlite-database-info-read-only-openable? info))
       (check-equal? (sqlite-database-info-migration-status info)
                     'unavailable)
       (check-exn
        exn:fail?
        (lambda () (quick-check-pos-sqlite-database malformed-path)))
       (check-exn
        exn:fail?
        (lambda () (integrity-check-pos-sqlite-database malformed-path)))
       (define validation
         (validate-pos-sqlite-backup malformed-path))
       (check-false (sqlite-backup-validation-valid? validation))
       (check-equal? (file->bytes malformed-path) bytes-before))))

  (test-case "backup validation requires an exact current POS schema"
    (call-with-temporary-directory
     (lambda (directory)
       (define v1-path (build-path directory "v1.sqlite"))
       (install-frozen-v1-file! v1-path)
       (define bytes-before (file->bytes v1-path))
       (define validation (validate-pos-sqlite-backup v1-path))
       (check-false (sqlite-backup-validation-valid? validation))
       (check-equal?
        (sqlite-backup-validation-migration-status validation)
        'supported-prefix)
       (check-false (sqlite-backup-validation-schema-valid? validation))
       (check-equal? (file->bytes v1-path) bytes-before))))

  (test-case "backup validation rejects foreign-key violations"
    (call-with-temporary-directory
     (lambda (directory)
       (define database-path (build-path directory "foreign-key.sqlite"))
       (initialize-sqlite-database! database-path)
       ;; The extra test tables do not alter migration-owned schema. A raw
       ;; connection deliberately creates the unusual corrupt candidate that
       ;; production foreign-key enforcement would prevent.
       (call-with-raw-connection
        database-path
        'read/write
        (lambda (connection)
          (db:query-exec connection "PRAGMA foreign_keys = OFF")
          (db:query-exec
           connection
           "CREATE TABLE test_parent (id INTEGER PRIMARY KEY)")
          (db:query-exec
           connection
           "CREATE TABLE test_child (parent_id INTEGER REFERENCES test_parent(id))")
          (db:query-exec
           connection
           "INSERT INTO test_child (parent_id) VALUES (999)")))

       (define validation (validate-pos-sqlite-backup database-path))
       (check-false (sqlite-backup-validation-valid? validation))
       (define integrity
         (sqlite-backup-validation-integrity-result validation))
       (check-pred sqlite-integrity-result? integrity)
       (check-equal? (sqlite-integrity-result-messages integrity) '("ok"))
       (check-equal?
        (length (sqlite-integrity-result-foreign-key-violations integrity))
        1))))

  (test-case "validated VACUUM INTO backup works while the WAL source stays open"
    (call-with-temporary-directory
     (lambda (directory)
       (define source-path (build-path directory "pos.sqlite"))
       (define backup-path (build-path directory "pos-backup.sqlite"))
       (initialize-sqlite-database! source-path)
       (call-with-production-connection
        source-path
        (lambda (live-connection)
          (check-pred
           journal-append-succeeded?
           (append-transaction-events!
            live-connection
            "txn-before-backup"
            0
            (list (transaction-started "txn-before-backup"))))

          (define history-before
            (read-pos-database-migration-history live-connection))
          (define created
            (create-pos-sqlite-backup! source-path backup-path))
          (check-equal? (sqlite-backup-created-path created)
                        (path->complete-path backup-path))
          (check-true (file-exists? backup-path))
          (check-true
           (sqlite-backup-validation-valid?
            (sqlite-backup-created-validation created)))
          (check-equal? (partial-files directory) '())

          (define backup-bytes-before-validation (file->bytes backup-path))
          (check-true
           (sqlite-backup-validation-valid?
            (validate-pos-sqlite-backup backup-path)))
          (check-equal? (file->bytes backup-path)
                        backup-bytes-before-validation)

          (call-with-pos-sqlite-inspection-connection
           backup-path
           (lambda (backup-connection)
             (check-equal?
              (db:query-value
               backup-connection
               "SELECT COUNT(*) FROM transaction_events WHERE transaction_id = 'txn-before-backup'")
              1)
             (check-equal?
              (read-pos-database-migration-history backup-connection)
              history-before)))

          ;; The source remains writable, and post-snapshot facts do not appear
          ;; retroactively in the already published standalone backup.
          (check-pred
           journal-append-succeeded?
           (append-transaction-events!
            live-connection
            "txn-after-backup"
            0
            (list (transaction-started "txn-after-backup"))))
          (check-equal?
           (read-pos-database-migration-history live-connection)
           history-before)
          (call-with-pos-sqlite-inspection-connection
           backup-path
           (lambda (backup-connection)
             (check-equal?
              (db:query-value
               backup-connection
               "SELECT COUNT(*) FROM transaction_events WHERE transaction_id = 'txn-after-backup'")
              0)))))))

  (test-case "backup destination safeguards preserve source and caller files"
    (call-with-temporary-directory
     (lambda (directory)
       (define source-path (build-path directory "pos.sqlite"))
       (initialize-sqlite-database! source-path)
       (define source-bytes-before (file->bytes source-path))

       (define existing-path (build-path directory "existing.sqlite"))
       (call-with-output-file
        existing-path
        #:exists 'error
        (lambda (output) (display "caller-owned" output)))
       (check-exn
        exn:fail?
        (lambda ()
          (create-pos-sqlite-backup! source-path existing-path)))
       (check-equal? (file->string existing-path) "caller-owned")

       (check-exn
        exn:fail?
        (lambda ()
          (create-pos-sqlite-backup! source-path source-path)))
       (check-equal? (file->bytes source-path) source-bytes-before)

       (define missing-parent (build-path directory "missing" "backup.sqlite"))
       (check-exn
        exn:fail?
        (lambda ()
          (create-pos-sqlite-backup! source-path missing-parent)))
       (check-false (directory-exists? (build-path directory "missing")))
       (check-equal? (partial-files directory) '()))))

  (test-case "invalid source or candidate never publishes a final backup"
    (call-with-temporary-directory
     (lambda (directory)
       (define drifted-source (build-path directory "drifted.sqlite"))
       (define drifted-output (build-path directory "drifted-backup.sqlite"))
       (initialize-sqlite-database! drifted-source)
       (call-with-production-connection
        drifted-source
        (lambda (connection)
          (db:query-exec connection "DROP TABLE transaction_command_receipts")))
       (check-exn
        exn:fail?
        (lambda ()
          (create-pos-sqlite-backup! drifted-source drifted-output)))
       (check-false (file-exists? drifted-output))
       (check-true (file-exists? drifted-source))
       (check-equal? (partial-files directory) '())

       (define valid-source (build-path directory "valid.sqlite"))
       (define failed-output (build-path directory "failed-backup.sqlite"))
       (initialize-sqlite-database! valid-source)
       (define observed-candidate #f)
       (check-exn
        exn:fail?
        (lambda ()
          (create-pos-sqlite-backup!
           valid-source
           failed-output
           #:validate-candidate
           (lambda (candidate)
             (set! observed-candidate candidate)
             (check-equal? (path-only candidate) directory)
             (check-true (string-suffix? (path->string candidate)
                                         ".partial"))
             (check-pred exact-positive-integer? (file-size candidate))
             (error 'test "simulated candidate validation failure")))))
       (check-false (file-exists? failed-output))
       (check-false (file-exists? observed-candidate))
       (check-true (file-exists? valid-source))
       (check-equal? (partial-files directory) '()))))

  (test-case "destination race does not overwrite the appearing final file"
    (call-with-temporary-directory
     (lambda (directory)
       (define source-path (build-path directory "pos.sqlite"))
       (define final-path (build-path directory "backup.sqlite"))
       (initialize-sqlite-database! source-path)
       (check-exn
        exn:fail?
        (lambda ()
          (create-pos-sqlite-backup!
           source-path
           final-path
           #:validate-candidate
           (lambda (candidate)
             (define validation (validate-pos-sqlite-backup candidate))
             (call-with-output-file
              final-path
              #:exists 'error
              (lambda (output) (display "race-winner" output)))
             validation))))
       (check-equal? (file->string final-path) "race-winner")
       (check-equal? (partial-files directory) '()))))))
