#lang racket

(require (prefix-in db: db)
         json
         rackunit
         racket/file
         "../pos/runtime-config.rkt"
         "../pos/runtime.rkt"
         "../pos/application/authentication-service.rkt"
         "../pos/application/transaction-command-receipt.rkt"
         "../pos/application/transaction-command.rkt"
         "../pos/application/register-operations-service.rkt"
         "../pos/application/transaction-service.rkt"
         "../pos/application/transaction-void-approval-service.rkt"
         "../pos/domain/fake-catalog.rkt"
         "../pos/domain/money.rkt"
         "../pos/domain/security-audit-event.rkt"
         "../pos/domain/tax.rkt"
         "../pos/domain/transaction-event.rkt"
         "../pos/persistence/catalog-snapshot-codec.rkt"
         "../pos/persistence/operational-configuration-snapshot-codec.rkt"
         "../pos/persistence/sqlite-catalog.rkt"
         "../pos/persistence/sqlite-connection.rkt"
         "../pos/persistence/security-audit-store.rkt"
         "../pos/persistence/sqlite-register-operations.rkt"
         "../pos/persistence/sqlite-transaction-event-store.rkt"
         "../pos/security/operator-pin.rkt"
         "../pos/security/transaction-void-approval.rkt"
         "support/seed-authenticated-operator.rkt")

(define runtime-principal
  (authenticated-operator "runtime-cashier" "Runtime Cashier" 'cashier 1))
(define runtime-approver-pin "80421637")
(define runtime-approver-hash (delay (hash-operator-pin runtime-approver-pin)))

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
  (transaction-service-execute-command service runtime-principal command))

(define (resolved-receipt result)
  (check-pred transaction-service-command-resolved? result)
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

(define persistent-runtime-catalog
  (hasheq
   'schema_version 1
   'items
   (list
    (hasheq 'item_id "item-apples"
            'description "Persistent Test Apples"
            'unit_price_minor_units 199
            'active #t)
    (hasheq 'item_id "item-inactive"
            'description "Inactive Item"
            'unit_price_minor_units 250
            'active #f))
   'barcodes
   (list
    (hasheq 'barcode "049000001234" 'item_id "item-apples")
    (hasheq 'barcode "000000000099" 'item_id "item-inactive"))))

(define (activate-runtime-catalog! database-path catalog-jsexpr)
  (initialize-sqlite-database! database-path)
  (define decoded
    (json-string->catalog-snapshot (jsexpr->string catalog-jsexpr)))
  (check-pred catalog-snapshot-decode-success? decoded)
  (with-connection
   database-path
   (lambda (connection)
     (activate-catalog-snapshot!
      connection
     (catalog-snapshot-decode-success-snapshot decoded)))))

(define runtime-configuration-json
  "{\"schema_version\":1,\"register\":{\"register_id\":\"runtime-register\",\"display_name\":\"Runtime Register\"},\"cashiers\":[{\"cashier_id\":\"runtime-cashier\",\"display_name\":\"Runtime Cashier\",\"active\":true}]}")

(define (prepare-runtime-operations! database-path)
  (initialize-sqlite-database! database-path)
  (define decoded
    (json-string->operational-configuration-snapshot
     runtime-configuration-json))
  (with-connection
   database-path
   (lambda (connection)
     (activate-operational-configuration!
      connection
     (operational-configuration-decode-success-snapshot decoded))
     (db:query-exec connection
                    "INSERT OR IGNORE INTO operator_pin_credentials VALUES ('runtime-cashier', '$argon2id$fixture', 1)")
     (db:query-exec connection
                    "INSERT OR IGNORE INTO operators VALUES ('runtime-supervisor', 'Runtime Supervisor', 1)")
     (db:query-exec connection
                    "INSERT OR IGNORE INTO operator_roles VALUES ('runtime-supervisor', 'supervisor')")
     (db:query-exec connection
                    "INSERT OR IGNORE INTO operator_pin_credentials VALUES ('runtime-supervisor', ?, 1)"
                    (force runtime-approver-hash))
     (register-operations-open-shift
      (make-register-operations-service
       connection
       #:current-epoch-ms (lambda () 1000)
       #:generate-shift-id (lambda () "shift-runtime"))
     runtime-principal
      (money 0)))))

(define (execute-approved-void runtime command)
  (define approval-service
    (pos-runtime-transaction-void-approval-service runtime))
  (define granted
    (transaction-void-approval-service-request
     approval-service
     runtime-principal
     command
     "runtime-supervisor"
     runtime-approver-pin))
  (check-pred transaction-void-approval-granted? granted)
  (define capability
    (transaction-void-approval-token->capability
     (transaction-void-approval-granted-approval-token granted)))
  (transaction-service-execute-command
   (pos-runtime-transaction-service runtime)
   runtime-principal
   command
   #:approval-capability
   capability))

(define (check-command-outcome result kind code)
  (define receipt (resolved-receipt result))
  (check-equal? (transaction-command-receipt-outcome-kind receipt) kind)
  (check-equal? (transaction-command-receipt-outcome-code receipt) code)
  receipt)

(module+ test
  (test-case "fresh v11 runtime and restart append one distinct start boundary each"
    (call-with-temporary-database
     (lambda (database-path _directory)
       (initialize-sqlite-database! database-path)
       (with-connection
        database-path
        (lambda (connection)
          (check-equal?
           (db:query-value connection "SELECT COUNT(*) FROM security_audit_events")
           0)))
       (for ([expected-count '(1 2)])
         (define runtime (start-pos-runtime (runtime-config database-path)))
         (dynamic-wind
           void
           (lambda ()
             (for ([_ (in-range 3)])
               (check-not-exn (lambda () (pos-runtime-readiness runtime))))
             (with-connection
              database-path
              (lambda (connection)
                (check-equal?
                 (db:query-list
                  connection
                  "SELECT sequence FROM security_audit_events WHERE event_type = 'runtime.started' ORDER BY sequence")
                 (build-list expected-count add1)))))
           (lambda () (stop-pos-runtime! runtime))))
       (with-connection
        database-path
        (lambda (connection)
          (define sources
            (db:query-list
             connection
             "SELECT source_instance_id FROM security_audit_events ORDER BY sequence"))
          (check-equal? (length sources) 2)
          (check-false (string=? (first sources) (second sources)))
          (check-true
           (security-audit-ledger-valid?
            (verify-security-audit-ledger connection))))))))

  (test-case "startup fails closed if required runtime audit append fails"
    (call-with-temporary-database
     (lambda (database-path _directory)
       (check-exn
        exn:fail?
        (lambda ()
          (start-pos-runtime
           (runtime-config database-path)
           #:current-epoch-ms (lambda () -1))))
       (with-connection
        database-path
        (lambda (connection)
          (check-equal?
           (db:query-value connection
                           "SELECT COUNT(*) FROM security_audit_events")
           0))))))

  (test-case "startup rejects a damaged chain before appending a restart event"
    (call-with-temporary-database
     (lambda (database-path _directory)
       (initialize-sqlite-database! database-path)
       (with-connection
        database-path
        (lambda (connection)
          (append-security-audit-event!
           connection (runtime-started-event)
           #:source-kind 'pos_core
           #:source-instance-id "audit_runtime_damaged"
           #:occurred-at-epoch-ms 100)
          (db:query-exec connection
                         "DROP TRIGGER security_audit_events_no_update")
          (db:query-exec connection
                         "UPDATE security_audit_events SET occurred_at_epoch_ms = 200 WHERE sequence = 1")))
       (check-exn exn:fail?
                  (lambda ()
                    (start-pos-runtime (runtime-config database-path))))
       (with-connection
        database-path
        (lambda (connection)
          (check-equal?
           (db:query-value connection
                           "SELECT COUNT(*) FROM security_audit_events")
           1))))))

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
                  (vector 3 "create_catalog")
                  (vector 4 "create_tax_categories")
                  (vector 5 "create_register_operations")
                  (vector 6 "create_shift_cash_accountability")
                  (vector 7 "create_operator_identity_credentials")
                  (vector 8 "create_operator_login_throttle")
                  (vector 9 "create_transaction_command_actor_attributions")
                  (vector 10 "create_transaction_void_approvals")
                  (vector 11 "create_security_audit_ledger")
                  (vector 12 "bind_transaction_void_approvals_to_requester_credentials")))
           (with-connection
            database-path
            (lambda (connection)
              (check-equal?
               (db:query-list
                connection
                "SELECT event_type FROM security_audit_events ORDER BY sequence")
               '("runtime.started"))))
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

           (with-connection
            database-path
            (lambda (connection)
              (seed-authenticated-test-operator!
               connection "runtime-cashier" 'cashier)))

           (define receipt
             (resolved-receipt
              (execute
               (pos-runtime-transaction-service runtime)
               (start-transaction-command "cmd-start" "txn-001" 0))))
           (check-equal?
            (transaction-command-receipt-outcome-kind receipt)
            'domain-rejected)
           (check-equal?
            (transaction-command-receipt-outcome-code receipt)
            "register_not_configured")
           (check-equal?
            (transaction-command-receipt-outcome-stream-version receipt)
            0))
         (lambda ()
           (stop-pos-runtime! runtime))))))

  (test-case "default runtime uses only persisted active catalog rows"
    (call-with-temporary-database
     (lambda (database-path _directory)
       (prepare-runtime-operations! database-path)
       (define runtime-empty
         (start-pos-runtime
          (runtime-config database-path)
          #:current-monotonic-ms (lambda () 1000)
          #:current-epoch-ms (lambda () 500000)))
       (dynamic-wind
         void
         (lambda ()
           (define service
             (pos-runtime-transaction-service runtime-empty))
           (check-command-outcome
            (execute service
                     (start-transaction-command
                      "cmd-empty-start" "txn-empty" 0))
            'accepted
            "accepted")
           ;; The old Test Apples fixture must not be implicitly available.
           (check-command-outcome
            (execute service
                     (scan-barcode-command
                      "cmd-empty-scan"
                      "txn-empty"
                      1
                      "049000001234"))
            'domain-rejected
            "unknown_barcode")
           (check-command-outcome
            (execute-approved-void
             runtime-empty
             (void-transaction-command
              "cmd-empty-void" "txn-empty" 1))
            'accepted
            "accepted"))
         (lambda () (stop-pos-runtime! runtime-empty)))

       (activate-runtime-catalog! database-path persistent-runtime-catalog)
       (define runtime-persisted
         (start-pos-runtime
          (runtime-config database-path)
          #:current-monotonic-ms (lambda () 1000)
          #:current-epoch-ms (lambda () 500000)))
       (dynamic-wind
         void
         (lambda ()
           (define service
             (pos-runtime-transaction-service runtime-persisted))
           (check-command-outcome
            (execute service
                     (start-transaction-command
                      "cmd-persisted-start" "txn-persisted" 0))
            'accepted
            "accepted")
           (check-command-outcome
            (execute service
                     (scan-barcode-command
                      "cmd-persisted-scan"
                      "txn-persisted"
                      1
                      "049000001234"))
            'accepted
            "accepted")

           (check-command-outcome
            (execute-approved-void
             runtime-persisted
             (void-transaction-command
              "cmd-persisted-void" "txn-persisted" 2))
            'accepted
            "accepted")

           (check-command-outcome
            (execute service
                     (start-transaction-command
                      "cmd-inactive-start" "txn-inactive" 0))
            'accepted
            "accepted")
           (check-command-outcome
            (execute service
                     (scan-barcode-command
                      "cmd-inactive-scan"
                      "txn-inactive"
                      1
                      "000000000099"))
            'domain-rejected
            "unknown_barcode")
           (check-command-outcome
            (execute-approved-void
             runtime-persisted
             (void-transaction-command
              "cmd-inactive-void" "txn-inactive" 1))
            'accepted
            "accepted")

           (check-command-outcome
            (execute service
                     (start-transaction-command
                      "cmd-unknown-start" "txn-unknown" 0))
            'accepted
            "accepted")
           (check-command-outcome
            (execute service
                     (scan-barcode-command
                      "cmd-unknown-scan"
                      "txn-unknown"
                      1
                      "does-not-exist"))
            'domain-rejected
            "unknown_barcode")
           (check-command-outcome
            (execute-approved-void
             runtime-persisted
             (void-transaction-command
              "cmd-unknown-void" "txn-unknown" 1))
            'accepted
            "accepted")

           (define recovered
             (transaction-service-load-transaction
              service runtime-principal "txn-persisted"))
           (check-pred transaction-service-success? recovered)
           (define events
             (with-connection
              database-path
              (lambda (connection)
                (load-transaction-events connection "txn-persisted"))))
           (check-pred journal-load-succeeded? events)
           (check-equal?
            (second (journal-load-succeeded-events events))
            (taxed-sale-item-added
             "049000001234"
             "Persistent Test Apples"
             (money 199)
             "__legacy_zero_tax__"
             (tax-rate 0)
             (money 0))))
         (lambda () (stop-pos-runtime! runtime-persisted))))))

  (test-case "runtime separates startup/request connections and owns shutdown"
    (call-with-temporary-database
     (lambda (database-path _directory)
       (prepare-runtime-operations! database-path)
       (define opened '())
       (define (recording-connect path mode)
         (define connection
           (open-pos-sqlite-connection path mode))
         (set! opened (append opened (list (cons mode connection))))
         connection)

       (define runtime
         (start-pos-runtime
          (runtime-config database-path)
          #:connect recording-connect))
       (check-equal? (map car opened) '(create read/write))
       (check-false (db:connected? (cdar opened)))
       (check-false (db:connected? (cdr (second opened))))

       (resolved-receipt
        (execute
         (pos-runtime-transaction-service runtime)
         (start-transaction-command "cmd-start" "txn-owned" 0)))
       (check-equal? (map car opened) '(create read/write read/write))
       (define request-connection (cdr (third opened)))
       (check-true (db:connected? request-connection))
       (check-equal?
        (db:query-value request-connection "PRAGMA journal_mode")
        "wal")
       (check-equal?
        (db:query-value request-connection "PRAGMA synchronous")
        2)
       (check-equal?
        (db:query-value request-connection "PRAGMA foreign_keys")
        1)
       (check-equal?
        (db:query-value request-connection "PRAGMA wal_autocheckpoint")
        pos-sqlite-wal-autocheckpoint-pages)

       (stop-pos-runtime! runtime)
       (check-true (pos-runtime-stopped? runtime))
       (check-false (db:connected? request-connection))
       (stop-pos-runtime! runtime))))

  (test-case "existing database startup preserves history and same-ID retry"
    (call-with-temporary-database
     (lambda (database-path _directory)
       (prepare-runtime-operations! database-path)
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
                  (vector 3 "create_catalog")
                  (vector 4 "create_tax_categories")
                  (vector 5 "create_register_operations")
                  (vector 6 "create_shift_cash_accountability")
                  (vector 7 "create_operator_identity_credentials")
                  (vector 8 "create_operator_login_throttle")
                  (vector 9 "create_transaction_command_actor_attributions")
                  (vector 10 "create_transaction_void_approvals")
                  (vector 11 "create_security_audit_ledger")
                  (vector 12 "bind_transaction_void_approvals_to_requester_credentials")))
           (define service
             (pos-runtime-transaction-service runtime-B))
           (define retry-receipt
             (resolved-receipt (execute service scan-command)))
           (check-equal? retry-receipt original-receipt)
           (check-equal? catalog-lookups 1)
           (define recovered
             (transaction-service-load-transaction
              service runtime-principal "txn-001"))
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
       (prepare-runtime-operations! database-path)
       (define runtime
         (start-pos-runtime
          (runtime-config database-path)
          #:catalog-lookup fake-catalog-lookup))
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
               (taxed-sale-item-added?
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
