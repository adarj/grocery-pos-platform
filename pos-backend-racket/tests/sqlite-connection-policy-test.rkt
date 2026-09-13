#lang racket

(require (prefix-in db: db)
         racket/file
         rackunit
         "../pos/domain/transaction-event.rkt"
         "../pos/persistence/pos-database-migrations.rkt"
         "../pos/persistence/sqlite-connection.rkt"
         "../pos/persistence/sqlite-transaction-event-store.rkt"
         "../pos/runtime.rkt")

(define expected-migration-history
  (list #(1 "create_transaction_events")
        #(2 "create_transaction_command_receipts")
        #(3 "create_catalog")
        #(4 "create_tax_categories")
        #(5 "create_register_operations")
        #(6 "create_shift_cash_accountability")))

(define (call-with-temporary-database procedure)
  (define directory
    (make-temporary-file "grocery-pos-sqlite-policy-~a" 'directory))
  (define database-path (build-path directory "pos.db"))
  (dynamic-wind
    void
    (lambda () (procedure database-path))
    (lambda () (delete-directory/files directory))))

(define (call-with-raw-connection database-path mode procedure)
  (define connection
    (db:sqlite3-connect #:database database-path #:mode mode))
  (dynamic-wind
    void
    (lambda () (procedure connection))
    (lambda () (db:disconnect connection))))

(define (call-with-production-connection database-path procedure)
  (define connection
    (open-pos-sqlite-connection database-path 'read/write))
  (dynamic-wind
    void
    (lambda () (procedure connection))
    (lambda () (db:disconnect connection))))

(define (check-production-pragmas connection)
  (check-equal? (db:query-value connection "PRAGMA journal_mode") "wal")
  (check-equal? (db:query-value connection "PRAGMA synchronous") 2)
  (check-equal? (db:query-value connection "PRAGMA foreign_keys") 1)
  (check-equal?
   (db:query-value connection "PRAGMA wal_autocheckpoint")
   pos-sqlite-wal-autocheckpoint-pages))

(module+ test
  (test-case "fresh canonical initialization establishes the production policy"
    (call-with-temporary-database
     (lambda (database-path)
       (initialize-sqlite-database! database-path)

       (call-with-production-connection
        database-path
        (lambda (connection)
          (check-production-pragmas connection)
          (check-equal?
           (db:query-rows
            connection
            "SELECT version, name FROM pos_schema_migrations ORDER BY version")
           expected-migration-history))))))

  (test-case "canonical initialization converts a compatible database to WAL"
    (call-with-temporary-database
     (lambda (database-path)
       (call-with-raw-connection
        database-path
        'create
        (lambda (connection)
          (check-equal?
           (db:query-value connection "PRAGMA journal_mode")
           "delete")
          (migrate-pos-database! connection)
          (define append-result
            (append-transaction-events!
             connection
             "txn-before-wal"
             0
             (list (transaction-started "txn-before-wal"))))
          (check-pred journal-append-succeeded? append-result)))

       (initialize-sqlite-database! database-path)

       (call-with-production-connection
        database-path
        (lambda (connection)
          (check-production-pragmas connection)
          (check-equal?
           (db:query-rows
            connection
            "SELECT version, name FROM pos_schema_migrations ORDER BY version")
           expected-migration-history)
          (define loaded
            (load-transaction-events connection "txn-before-wal"))
          (check-pred journal-load-succeeded? loaded)
          (check-equal?
           (journal-load-succeeded-events loaded)
           (list (transaction-started "txn-before-wal"))))))))

  (test-case "normal production opening rejects a database not initialized for WAL"
    (call-with-temporary-database
     (lambda (database-path)
       (call-with-raw-connection
        database-path
        'create
        (lambda (connection)
          (db:query-exec connection "CREATE TABLE probe (value INTEGER)")))

       (check-exn
        #rx"journal mode.*WAL"
        (lambda ()
          (open-pos-sqlite-connection database-path 'read/write)))
       (call-with-raw-connection
        database-path
        'read/write
        (lambda (connection)
          (check-equal?
           (db:query-value connection "PRAGMA journal_mode")
           "delete"))))))

  (test-case "WAL establishment failure disconnects and uses explicit busy settings"
    (define opened-connection #f)
    (define observed-limit #f)
    (define observed-delay #f)
    (define (recording-connect
             #:database _database
             #:mode _mode
             #:busy-retry-limit busy-retry-limit
             #:busy-retry-delay busy-retry-delay)
      (set! observed-limit busy-retry-limit)
      (set! observed-delay busy-retry-delay)
      ;; An in-memory database cannot satisfy the required WAL policy, which
      ;; creates a real post-open verification failure without monkey-patching
      ;; the PRAGMA implementation.
      (set! opened-connection
            (db:sqlite3-connect #:database 'memory))
      opened-connection)

    (check-exn
     #rx"journal mode.*WAL"
     (lambda ()
       (open-pos-sqlite-connection
        "unused-by-recording-connector.sqlite"
        'create
        #:sqlite3-connect recording-connect)))
    (check-equal? observed-limit pos-sqlite-busy-retry-limit)
    (check-equal? observed-delay pos-sqlite-busy-retry-delay)
    (check-pred db:connection? opened-connection)
    (check-false (db:connected? opened-connection)))

  (test-case "connection policy rejects invalid construction arguments"
    (check-exn
     exn:fail:contract?
     (lambda () (open-pos-sqlite-connection "" 'create)))
    (check-exn
     exn:fail:contract?
     (lambda () (open-pos-sqlite-connection "pos.db" 'read-only)))
    (check-exn
     exn:fail:contract?
     (lambda ()
       (open-pos-sqlite-connection
        "pos.db"
        'create
        #:sqlite3-connect 'not-a-procedure)))))
