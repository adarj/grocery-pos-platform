#lang racket

(require (prefix-in db: db)
         rackunit
         racket/file
         "../pos/runtime-config.rkt"
         "../pos/runtime.rkt"
         "../pos/application/transaction-command-receipt.rkt"
         "../pos/application/transaction-command.rkt"
         "../pos/application/transaction-service.rkt"
         "../pos/domain/fake-catalog.rkt"
         "../pos/domain/transaction-event.rkt"
         "../pos/persistence/sqlite-transaction-event-store.rkt")

(define (call-with-temporary-database proc)
  (define directory
    (make-temporary-file "grocery-pos-runtime-~a" 'directory))
  (define database-path
    (build-path directory "pos.db"))
  (dynamic-wind
    void
    (lambda () (proc database-path directory))
    (lambda () (delete-directory/files directory))))

(define (runtime-config database-path)
  (pos-runtime-config "127.0.0.1" 7340 database-path))

(define (execute service command)
  (transaction-service-execute-command service command))

(define (resolved-receipt result)
  (check-true (transaction-service-command-resolved? result))
  (transaction-service-command-resolved-receipt result))

(define (with-connection database-path proc)
  (define connection
    (db:sqlite3-connect #:database database-path #:mode 'read/write))
  (dynamic-wind
    void
    (lambda () (proc connection))
    (lambda () (db:disconnect connection))))

(define (migration-history database-path)
  (with-connection
   database-path
   (lambda (connection)
     (db:query-rows
      connection
      "SELECT version, name FROM pos_schema_migrations ORDER BY version"))))

(module+ test
  (test-case "startup migration connection is disconnected on success and failure"
    (call-with-temporary-database
     (lambda (database-path _directory)
       (define successful-connection #f)
       (initialize-sqlite-database!
        database-path
        #:connect
        (lambda (path mode)
          (set! successful-connection
                (db:sqlite3-connect #:database path #:mode mode))
          successful-connection))
       (check-false (db:connected? successful-connection))

       (define failing-connection #f)
       (check-exn
        exn:fail?
        (lambda ()
          (initialize-sqlite-database!
           database-path
           #:connect
           (lambda (path mode)
             (set! failing-connection
                   (db:sqlite3-connect #:database path #:mode mode))
             failing-connection)
           #:migrate!
           (lambda (_connection)
             (error 'test-migration "simulated migration failure")))))
       (check-false (db:connected? failing-connection)))))

  (test-case "fresh runtime migrates schema and executes a durable command"
    (call-with-temporary-database
     (lambda (database-path _directory)
       (define runtime
         (start-pos-runtime (runtime-config database-path)))
       (dynamic-wind
         void
         (lambda ()
           (check-equal?
            (migration-history database-path)
            (list (vector 1 "create_transaction_events")
                  (vector 2 "create_transaction_command_receipts")
                  (vector 3 "create_catalog")))
           (with-connection
            database-path
            (lambda (connection)
              (check-equal?
               (db:query-list
                connection
                #<<SQL
SELECT name
FROM sqlite_schema
WHERE type = 'table'
  AND name IN (
    'transaction_events',
    'transaction_command_receipts',
    'catalog_items',
    'catalog_barcodes'
  )
ORDER BY name
SQL
                )
               '("catalog_barcodes"
                 "catalog_items"
                 "transaction_command_receipts"
                 "transaction_events"))))

           (define receipt
             (resolved-receipt
              (execute
               (pos-runtime-transaction-service runtime)
               (start-transaction-command "cmd-start" "txn-001" 0))))
           (check-equal?
            (transaction-command-receipt-outcome-kind receipt)
            'accepted)
           (check-equal?
            (transaction-command-receipt-outcome-stream-version receipt)
            1))
         (lambda ()
           (stop-pos-runtime! runtime))))))

  (test-case "runtime separates startup/request connections and owns shutdown"
    (call-with-temporary-database
     (lambda (database-path _directory)
       (define opened '())
       (define (recording-connect path mode)
         (define connection
           (db:sqlite3-connect #:database path #:mode mode))
         (set! opened (append opened (list (cons mode connection))))
         connection)

       (define runtime
         (start-pos-runtime
          (runtime-config database-path)
          #:connect recording-connect))
       (check-equal? (map car opened) '(create))
       (check-false (db:connected? (cdar opened)))

       (resolved-receipt
        (execute
         (pos-runtime-transaction-service runtime)
         (start-transaction-command "cmd-start" "txn-owned" 0)))
       (check-equal? (map car opened) '(create read/write))
       (define request-connection (cdr (second opened)))
       (check-true (db:connected? request-connection))

       (stop-pos-runtime! runtime)
       (check-true (pos-runtime-stopped? runtime))
       (check-false (db:connected? request-connection))
       (stop-pos-runtime! runtime))))

  (test-case "existing database startup preserves history and same-ID retry"
    (call-with-temporary-database
     (lambda (database-path _directory)
       (define catalog-lookups 0)
       (define (counted-catalog barcode)
         (set! catalog-lookups (add1 catalog-lookups))
         (fake-catalog-lookup barcode))
       (define start-command
         (start-transaction-command "cmd-start" "txn-001" 0))
       (define scan-command
         (scan-barcode-command
          "cmd-scan" "txn-001" 1 "049000001234"))

       (define runtime-A
         (start-pos-runtime
          (runtime-config database-path)
          #:catalog-lookup counted-catalog))
       (define original-receipt
         (dynamic-wind
           void
           (lambda ()
             (define service
               (pos-runtime-transaction-service runtime-A))
             (resolved-receipt (execute service start-command))
             (resolved-receipt (execute service scan-command)))
           (lambda ()
             (stop-pos-runtime! runtime-A))))
       (check-equal? catalog-lookups 1)

       (define runtime-B
         (start-pos-runtime
          (runtime-config database-path)
          #:catalog-lookup counted-catalog))
       (dynamic-wind
         void
         (lambda ()
           (check-equal?
            (migration-history database-path)
            (list (vector 1 "create_transaction_events")
                  (vector 2 "create_transaction_command_receipts")
                  (vector 3 "create_catalog")))
           (define service
             (pos-runtime-transaction-service runtime-B))
           (define retry-receipt
             (resolved-receipt (execute service scan-command)))
           (check-equal? retry-receipt original-receipt)
           (check-equal? catalog-lookups 1)
           (define recovered
             (transaction-service-load-transaction service "txn-001"))
           (check-true (transaction-service-success? recovered))
           (check-equal? (transaction-service-success-version recovered) 2)
           (with-connection
            database-path
            (lambda (connection)
              (check-equal?
               (db:query-value
                connection
                "SELECT COUNT(*) FROM transaction_events")
               2)
              (check-equal?
               (db:query-value
                connection
                "SELECT COUNT(*) FROM transaction_command_receipts")
               2))))
         (lambda ()
           (stop-pos-runtime! runtime-B)
           (stop-pos-runtime! runtime-B))))))

  (test-case "migration failure prevents runtime construction"
    (call-with-temporary-database
     (lambda (database-path _directory)
       (define connection
         (db:sqlite3-connect #:database database-path #:mode 'create))
       (dynamic-wind
         void
         (lambda ()
           (db:query-exec
            connection
            "CREATE TABLE pos_schema_migrations (version INTEGER PRIMARY KEY, name TEXT NOT NULL)")
           (db:query-exec
            connection
            "INSERT INTO pos_schema_migrations (version, name) VALUES (99, 'unknown')"))
         (lambda ()
           (db:disconnect connection)))
       (check-exn
        exn:fail?
        (lambda ()
          (start-pos-runtime (runtime-config database-path)))))))

  (test-case "missing configured database parent fails without creating it"
    (call-with-temporary-database
     (lambda (_database-path directory)
       (define missing-parent
         (build-path directory "missing"))
       (define nested-database
         (build-path missing-parent "pos.db"))
       (check-exn
        exn:fail:contract?
        (lambda ()
          (start-pos-runtime (runtime-config nested-database))))
       (check-false (directory-exists? missing-parent)))))

  (test-case "shared runtime service remains correct across request threads"
    (call-with-temporary-database
     (lambda (database-path _directory)
       (define runtime
         (start-pos-runtime (runtime-config database-path)))
       (dynamic-wind
         void
         (lambda ()
           (define service
             (pos-runtime-transaction-service runtime))
           (resolved-receipt
            (execute
             service
             (start-transaction-command "cmd-start" "txn-threads" 0)))

           (define gate (make-semaphore 0))
           (define results (make-channel))
           (define commands
             (list
              (scan-barcode-command
               "cmd-scan-a" "txn-threads" 1 "049000001234")
              (scan-barcode-command
               "cmd-scan-b" "txn-threads" 1 "049000001234")))
           (define workers
             (for/list ([command (in-list commands)])
               (thread
                (lambda ()
                  (semaphore-wait gate)
                  (channel-put
                   results
                   (with-handlers ([exn:fail? values])
                     (execute service command)))))))
           (for ([worker (in-list workers)])
             (semaphore-post gate))
           (define outcomes
             (for/list ([worker (in-list workers)])
               (channel-get results)))
           (for ([worker (in-list workers)])
             (thread-wait worker))
           (for ([outcome (in-list outcomes)])
             (unless (transaction-service-command-resolved? outcome)
               (raise outcome)))

           (define receipts
             (map transaction-service-command-resolved-receipt outcomes))
           (check-equal?
            (count (lambda (receipt)
                     (eq? (transaction-command-receipt-outcome-kind receipt)
                          'accepted))
                   receipts)
            1)
           (check-equal?
            (count (lambda (receipt)
                     (eq? (transaction-command-receipt-outcome-kind receipt)
                          'version-conflict))
                   receipts)
            1)
           (check-not-false
            (member
             (transaction-command-receipt-outcome-code
              (findf
               (lambda (receipt)
                 (eq? (transaction-command-receipt-outcome-kind receipt)
                      'version-conflict))
               receipts))
             '("stale_expected_version" "stream_version_conflict")))

           (with-connection
            database-path
            (lambda (connection)
              (define loaded
                (load-transaction-events connection "txn-threads"))
              (check-true (journal-load-succeeded? loaded))
              (check-equal? (journal-load-succeeded-version loaded) 2)
              (check-equal?
               (length (journal-load-succeeded-events loaded))
               2)
              (check-true
               (sale-item-added?
                (second (journal-load-succeeded-events loaded))))
              (check-equal?
               (db:query-value
                connection
                "SELECT COUNT(*) FROM transaction_command_receipts WHERE transaction_id = 'txn-threads'")
               3))))
         (lambda ()
           (stop-pos-runtime! runtime))))))

  (test-case "request connections never recreate a missing initialized database"
    (call-with-temporary-database
     (lambda (database-path directory)
       (define runtime
         (start-pos-runtime (runtime-config database-path)))
       (define relocated-path
         (build-path directory "relocated.db"))
       (dynamic-wind
         void
         (lambda ()
           ;; No request-time connection has been opened yet. Moving the
           ;; initialized file makes the factory's read/write-only policy
           ;; observable without reaching into pool internals.
           (rename-file-or-directory database-path relocated-path)
           (check-exn
            exn:fail?
            (lambda ()
              (execute
               (pos-runtime-transaction-service runtime)
               (start-transaction-command "cmd-start" "txn-001" 0))))
           (check-false (file-exists? database-path)))
         (lambda ()
           (stop-pos-runtime! runtime))))))
)
