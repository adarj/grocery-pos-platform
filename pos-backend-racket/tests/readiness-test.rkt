#lang racket

(require (prefix-in db: db)
         racket/file
         rackunit
         "../pos/persistence/pos-database-migrations.rkt"
         "../pos/persistence/sqlite-connection.rkt"
         "../pos/runtime-config.rkt"
         "../pos/runtime.rkt"
         "../pos/support/readiness.rkt")

(define (call-with-temporary-database procedure)
  (define directory
    (make-temporary-file "grocery-pos-readiness-~a" 'directory))
  (define database-path (build-path directory "pos.db"))
  (dynamic-wind
    void
    (lambda () (procedure database-path directory))
    (lambda () (delete-directory/files directory))))

(define (with-raw-connection database-path mode procedure)
  (define connection
    (db:sqlite3-connect #:database database-path #:mode mode))
  (dynamic-wind
    void
    (lambda () (procedure connection))
    (lambda ()
      (when (db:connected? connection)
        (db:disconnect connection)))))

(define (migration-history database-path)
  (with-raw-connection
   database-path
   'read-only
   read-pos-database-migration-history))

(define (runtime-config database-path)
  (pos-runtime-config "127.0.0.1" 7340 database-path))

(module+ test
  (test-case "current database is ready through a fresh production connection"
    (call-with-temporary-database
     (lambda (database-path _directory)
       (initialize-sqlite-database! database-path)
       (define opened-connection #f)
       (define result
         (probe-pos-database-readiness
          database-path
          #:connect
          (lambda (path mode)
            (check-equal? mode 'read/write)
            (set! opened-connection
                  (open-pos-sqlite-connection path mode))
            opened-connection)))
       (check-equal?
        result
        (runtime-ready current-pos-database-schema-version))
       (check-false (db:connected? opened-connection)))))

  (test-case "missing database is not ready and is never created"
    (call-with-temporary-database
     (lambda (database-path _directory)
       (check-equal?
        (probe-pos-database-readiness database-path)
        (runtime-not-ready 'database_missing))
       (check-false (file-exists? database-path)))))

  (test-case "stopped runtime is not ready without probing persistence"
    (call-with-temporary-database
     (lambda (database-path _directory)
       (define connection-count 0)
       (define (recording-connect path mode)
         (set! connection-count (add1 connection-count))
         (open-pos-sqlite-connection path mode))
       (define runtime
         (start-pos-runtime
          (runtime-config database-path)
          #:connect recording-connect))
       (stop-pos-runtime! runtime)
       (define count-before-readiness connection-count)
       (check-equal?
        (pos-runtime-readiness runtime)
        (runtime-not-ready 'runtime_stopped))
       (check-equal? connection-count count-before-readiness))))

  (test-case "supported historical schema is not ready and is not migrated"
    (call-with-temporary-database
     (lambda (database-path _directory)
       (with-raw-connection
        database-path
        'create
        (lambda (connection)
          (check-equal?
           (db:query-value connection "PRAGMA journal_mode = WAL")
           "wal")
          (db:query-exec
           connection
           #<<SQL
CREATE TABLE pos_schema_migrations (
  version INTEGER PRIMARY KEY
    CHECK (typeof(version) = 'integer' AND version > 0),
  name TEXT NOT NULL
    CHECK (typeof(name) = 'text')
)
SQL
           )
          (db:query-exec
           connection
           "INSERT INTO pos_schema_migrations (version, name) VALUES (1, 'create_transaction_events')")
          (db:query-exec
           connection
           "CREATE TABLE transaction_events (id INTEGER PRIMARY KEY, transaction_id TEXT NOT NULL CHECK (typeof(transaction_id) = 'text'), stream_sequence INTEGER NOT NULL CHECK (typeof(stream_sequence) = 'integer' AND stream_sequence > 0), schema_version INTEGER NOT NULL CHECK (typeof(schema_version) = 'integer' AND schema_version > 0), event_type TEXT NOT NULL CHECK (typeof(event_type) = 'text'), event_json TEXT NOT NULL CHECK (typeof(event_json) = 'text'))")
          (db:query-exec
           connection
           "CREATE UNIQUE INDEX transaction_events_stream_sequence_unique ON transaction_events (transaction_id, stream_sequence)")))
       (define history-before (migration-history database-path))
       (check-equal?
        (probe-pos-database-readiness database-path)
        (runtime-not-ready 'database_schema_not_current))
       (check-equal? (migration-history database-path) history-before))))

  (test-case "non-WAL replacement database fails the production contract"
    (call-with-temporary-database
     (lambda (database-path _directory)
       (with-raw-connection
        database-path
        'create
        migrate-pos-database!)
       (check-equal?
        (probe-pos-database-readiness database-path)
        (runtime-not-ready 'database_unavailable)))))

  (test-case "missing live database makes readiness false while runtime stays alive"
    (call-with-temporary-database
     (lambda (database-path directory)
       (define runtime
         (start-pos-runtime (runtime-config database-path)))
       (define relocated-path (build-path directory "relocated.db"))
       (dynamic-wind
         void
         (lambda ()
           (check-pred runtime-ready? (pos-runtime-readiness runtime))
           (rename-file-or-directory database-path relocated-path)
           (check-false (pos-runtime-stopped? runtime))
           (check-equal?
            (pos-runtime-readiness runtime)
            (runtime-not-ready 'database_missing))
           (check-false (file-exists? database-path)))
         (lambda () (stop-pos-runtime! runtime)))))))
