#lang racket

(require (prefix-in db: db)
         rackunit
         "../pos/application/transaction-command-receipt.rkt"
         "../pos/application/transaction-command.rkt"
         "../pos/application/transaction-service.rkt"
         "../pos/domain/fake-catalog.rkt"
         "../pos/domain/money.rkt"
         "../pos/domain/tax.rkt"
         "../pos/domain/transaction-event.rkt"
         "../pos/domain/transaction.rkt"
         "../pos/persistence/sqlite-transaction-event-store.rkt"
         "../pos/persistence/transaction-command-receipt-store.rkt"
         "../pos/persistence/transaction-command-unit-of-work.rkt"
         "../pos/persistence/pos-database-migrations.rkt")

(define test-barcode "049000001234")
(define test-sale-item-event
  (taxed-sale-item-added test-barcode
                         "Test Apples"
                         (money 199)
                         "development-zero-tax"
                         (tax-rate 0)
                         (money 0)))
(define unknown-barcode "000000000000")

(define (call-with-store procedure)
  (define connection
    (db:sqlite3-connect #:database 'memory))
  (dynamic-wind
    void
    (lambda ()
      (migrate-pos-database! connection)
      (procedure connection))
    (lambda () (db:disconnect connection))))

(define (make-test-service connection
                           #:catalog-lookup
                           [catalog-lookup fake-catalog-lookup]
                           #:load-events
                           [load-events load-transaction-events]
                           #:load-receipt
                           [load-receipt load-transaction-command-receipt]
                           #:commit-command!
                           [commit-command! commit-transaction-command-outcome!])
  (make-transaction-service
   connection
   #:catalog-lookup catalog-lookup
   #:load-events load-events
   #:load-receipt load-receipt
   #:commit-command! commit-command!))

(define (resolved-receipt result)
  (check-pred transaction-service-command-resolved? result)
  (transaction-service-command-resolved-receipt result))

(define (check-outcome receipt command kind code version)
  (check-equal? (transaction-command-receipt-command receipt) command)
  (check-equal? (transaction-command-receipt-outcome-kind receipt) kind)
  (check-equal? (transaction-command-receipt-outcome-code receipt) code)
  (check-equal?
   (transaction-command-receipt-outcome-stream-version receipt)
   version))

(define (query-transaction service transaction-id expected-version)
  (define result
    (transaction-service-load-transaction service transaction-id))
  (check-pred transaction-service-success? result)
  (check-equal? (transaction-service-success-version result)
                expected-version)
  (transaction-service-success-transaction result))

(define (journal-events connection transaction-id)
  (define result
    (load-transaction-events connection transaction-id))
  (check-pred journal-load-succeeded? result)
  (journal-load-succeeded-events result))

(define (journal-version connection transaction-id)
  (define result
    (load-transaction-events connection transaction-id))
  (check-pred journal-load-succeeded? result)
  (journal-load-succeeded-version result))

(define (receipt-row-count connection)
  (db:query-value
   connection
   "SELECT COUNT(*) FROM transaction_command_receipts"))

(define (execute-start! service transaction-id command-id
                        #:expected-version [expected-version 0])
  (transaction-service-execute-command
   service
   (start-transaction-command command-id transaction-id expected-version)))

(define (execute-scan! service transaction-id command-id expected-version barcode)
  (transaction-service-execute-command
   service
   (scan-barcode-command
    command-id transaction-id expected-version barcode)))

(define (start-and-scan! service transaction-id command-prefix)
  (resolved-receipt
   (execute-start! service transaction-id (format "~a-start" command-prefix)))
  (resolved-receipt
   (execute-scan! service
                  transaction-id
                  (format "~a-scan" command-prefix)
                  1
                  test-barcode)))

(module+ test
  (test-case "accepted start returns receipt and query returns transaction"
    (call-with-store
     (lambda (connection)
       (define service (make-test-service connection))
       (define command
         (start-transaction-command "cmd-start" "txn-start" 0))
       (define result
         (transaction-service-execute-command service command))
       (define receipt (resolved-receipt result))

       (check-outcome receipt command 'accepted "accepted" 1)
       (check-false (transaction-service-success? result))
       (check-equal? (journal-events connection "txn-start")
                     (list (transaction-started "txn-start")))
       (define transaction
         (query-transaction service "txn-start" 1))
       (check-equal? (transaction-id transaction) "txn-start")
       (check-equal? (transaction-status transaction) 'open)
       (check-equal? (transaction-line-items transaction) '()))))

  (test-case "accepted scan uses one catalog lookup and persists one event"
    (call-with-store
     (lambda (connection)
       (define lookup-count 0)
       (define service
         (make-test-service
          connection
          #:catalog-lookup
          (lambda (barcode)
            (set! lookup-count (add1 lookup-count))
            (fake-catalog-lookup barcode))))
       (execute-start! service "txn-scan" "cmd-scan-start")
       (define command
         (scan-barcode-command
          "cmd-scan" "txn-scan" 1 test-barcode))
       (define receipt
         (resolved-receipt
          (transaction-service-execute-command service command)))

       (check-outcome receipt command 'accepted "accepted" 2)
       (check-equal? lookup-count 1)
       (check-equal?
        (journal-events connection "txn-scan")
        (list (transaction-started "txn-scan")
              test-sale-item-event))
       (define recovered
         (query-transaction service "txn-scan" 2))
       (check-equal? (transaction-subtotal recovered) (money 199))
       (check-equal? lookup-count 1))))

  (test-case "accepted tender persists exactly one cash event"
    (call-with-store
     (lambda (connection)
       (define service (make-test-service connection))
       (start-and-scan! service "txn-tender" "cmd-tender")
       (define command
         (tender-cash-command
          "cmd-cash" "txn-tender" 2 (money 500)))
       (define receipt
         (resolved-receipt
          (transaction-service-execute-command service command)))

       (check-outcome receipt command 'accepted "accepted" 3)
       (check-equal?
        (journal-events connection "txn-tender")
        (list (transaction-started "txn-tender")
              test-sale-item-event
              (cash-tendered (money 500)))))))

  (test-case "accepted completion persists exactly one completion event"
    (call-with-store
     (lambda (connection)
       (define service (make-test-service connection))
       (start-and-scan! service "txn-complete" "cmd-complete")
       (resolved-receipt
        (transaction-service-execute-command
         service
         (tender-cash-command
          "cmd-complete-cash" "txn-complete" 2 (money 500))))
       (define command
         (complete-transaction-command
          "cmd-completion" "txn-complete" 3))
       (define receipt
         (resolved-receipt
          (transaction-service-execute-command service command)))

       (check-outcome receipt command 'accepted "accepted" 4)
       (check-equal?
        (journal-events connection "txn-complete")
        (list (transaction-started "txn-complete")
              test-sale-item-event
              (cash-tendered (money 500))
              (transaction-completed))))))

  (test-case "known accepted scan retry returns original receipt without work"
    (call-with-store
     (lambda (connection)
       (define lookup-count 0)
       (define journal-load-count 0)
       (define commit-count 0)
       (define (counting-load connection* transaction-id)
         (set! journal-load-count (add1 journal-load-count))
         (load-transaction-events connection* transaction-id))
       (define (counting-commit connection* plan)
         (set! commit-count (add1 commit-count))
         (commit-transaction-command-outcome! connection* plan))
       (define service
         (make-test-service
          connection
          #:catalog-lookup
          (lambda (barcode)
            (set! lookup-count (add1 lookup-count))
            (fake-catalog-lookup barcode))
          #:load-events counting-load
          #:commit-command! counting-commit))

       (execute-start! service "txn-retry" "cmd-retry-start")
       (define command-C1
         (scan-barcode-command
          "cmd-C1" "txn-retry" 1 test-barcode))
       (define original
         (resolved-receipt
          (transaction-service-execute-command service command-C1)))
       (resolved-receipt
        (execute-scan! service "txn-retry" "cmd-C2" 2 test-barcode))
       (define loads-before journal-load-count)
       (define commits-before commit-count)
       (define lookups-before lookup-count)

       (define retried
         (resolved-receipt
          (transaction-service-execute-command service command-C1)))

       (check-equal? retried original)
       (check-equal?
        (transaction-command-receipt-outcome-stream-version retried)
        2)
       (check-equal? journal-load-count loads-before)
       (check-equal? commit-count commits-before)
       (check-equal? lookup-count lookups-before)
       (check-equal? (journal-version connection "txn-retry") 3))))

  (test-case "known rejected scan retry does not repeat catalog lookup"
    (call-with-store
     (lambda (connection)
       (define lookup-count 0)
       (define service
         (make-test-service
          connection
          #:catalog-lookup
          (lambda (barcode)
            (set! lookup-count (add1 lookup-count))
            (fake-catalog-lookup barcode))))
       (execute-start! service "txn-rejected-retry" "cmd-rejected-start")
       (define command
         (scan-barcode-command
          "cmd-rejected" "txn-rejected-retry" 1 unknown-barcode))
       (define first-receipt
         (resolved-receipt
          (transaction-service-execute-command service command)))
       (define second-receipt
         (resolved-receipt
          (transaction-service-execute-command service command)))

       (check-outcome
        first-receipt command 'domain-rejected "unknown_barcode" 1)
       (check-equal? second-receipt first-receipt)
       (check-equal? lookup-count 1)
       (check-equal? (journal-version connection "txn-rejected-retry") 1))))

  (test-case "same ID with different typed command is rejected before work"
    (call-with-store
     (lambda (connection)
       (define lookup-count 0)
       (define journal-load-count 0)
       (define commit-count 0)
       (define service
         (make-test-service
          connection
          #:catalog-lookup
          (lambda (barcode)
            (set! lookup-count (add1 lookup-count))
            (fake-catalog-lookup barcode))
          #:load-events
          (lambda (connection* transaction-id)
            (set! journal-load-count (add1 journal-load-count))
            (load-transaction-events connection* transaction-id))
          #:commit-command!
          (lambda (connection* plan)
            (set! commit-count (add1 commit-count))
            (commit-transaction-command-outcome! connection* plan))))
       (execute-start! service "txn-reuse" "cmd-reuse-start")
       (define original-command
         (scan-barcode-command
          "cmd-reuse" "txn-reuse" 1 unknown-barcode))
       (resolved-receipt
        (transaction-service-execute-command service original-command))
       (define loads-before journal-load-count)
       (define lookups-before lookup-count)
       (define commits-before commit-count)
       (define receipt-count-before (receipt-row-count connection))
       (define reused-command
         (scan-barcode-command
          "cmd-reuse" "txn-reuse" 1 test-barcode))

       (define result
         (transaction-service-execute-command service reused-command))

       (check-pred transaction-service-command-id-reused? result)
       (check-equal?
        (transaction-service-command-id-reused-command-id result)
        "cmd-reuse")
       (check-equal? journal-load-count loads-before)
       (check-equal? lookup-count lookups-before)
       (check-equal? commit-count commits-before)
       (check-equal? (receipt-row-count connection) receipt-count-before))))

  (test-case "corrupt known receipt stops before journal catalog and commit"
    (call-with-store
     (lambda (connection)
       (define catalog-count 0)
       (define journal-count 0)
       (define commit-count 0)
       (define service
         (make-test-service
          connection
          #:catalog-lookup
          (lambda (barcode)
            (set! catalog-count (add1 catalog-count))
            (fake-catalog-lookup barcode))
          #:load-events
          (lambda (connection* transaction-id)
            (set! journal-count (add1 journal-count))
            (load-transaction-events connection* transaction-id))
          #:commit-command!
          (lambda (connection* plan)
            (set! commit-count (add1 commit-count))
            (commit-transaction-command-outcome! connection* plan))))
       (execute-start! service "txn-receipt-corrupt" "cmd-corrupt-start")
       (define command
         (scan-barcode-command
          "cmd-corrupt" "txn-receipt-corrupt" 1 unknown-barcode))
       (resolved-receipt
        (transaction-service-execute-command service command))
       (db:query-exec connection "PRAGMA ignore_check_constraints = ON")
       (db:query-exec
        connection
        "UPDATE transaction_command_receipts SET outcome_code = '' WHERE command_id = 'cmd-corrupt'")
       (define catalog-before catalog-count)
       (define journal-before journal-count)
       (define commit-before commit-count)

       (define result
         (transaction-service-execute-command service command))

       (check-pred transaction-service-recovery-failed? result)
       (check-equal? (transaction-service-recovery-failed-stage result)
                     'receipt-load)
       (check-equal? (transaction-service-recovery-failed-code result)
                     'invalid-outcome-code)
       (check-equal? catalog-count catalog-before)
       (check-equal? journal-count journal-before)
       (check-equal? commit-count commit-before))))

  (test-case "start with nonzero expected version persists invalid version"
    (call-with-store
     (lambda (connection)
       (define service (make-test-service connection))
       (define missing-command
         (start-transaction-command "cmd-invalid-missing" "txn-missing" 1))
       (define missing-receipt
         (resolved-receipt
          (transaction-service-execute-command service missing-command)))
       (check-outcome missing-receipt
                      missing-command
                      'version-conflict
                      "invalid_expected_version"
                      0)
       (check-equal? (journal-version connection "txn-missing") 0)

       (execute-start! service "txn-existing-invalid" "cmd-existing-start")
       (define existing-command
         (start-transaction-command
          "cmd-invalid-existing" "txn-existing-invalid" 7))
       (define existing-receipt
         (resolved-receipt
          (transaction-service-execute-command service existing-command)))
       (check-outcome existing-receipt
                      existing-command
                      'version-conflict
                      "invalid_expected_version"
                      1)
       (check-equal? (journal-version connection "txn-existing-invalid") 1))))

  (test-case "start at version zero on existing stream is already exists"
    (call-with-store
     (lambda (connection)
       (define service (make-test-service connection))
       (execute-start! service "txn-already" "cmd-already-first")
       (define command
         (start-transaction-command "cmd-already-second" "txn-already" 0))
       (define receipt
         (resolved-receipt
          (transaction-service-execute-command service command)))

       (check-outcome receipt
                      command
                      'already-exists
                      "transaction_already_exists"
                      1)
       (check-equal? (journal-version connection "txn-already") 1))))

  (test-case "non-start commands against missing transaction are durable not found"
    (call-with-store
     (lambda (connection)
       (define catalog-count 0)
       (define service
         (make-test-service
          connection
          #:catalog-lookup
          (lambda (_barcode)
            (set! catalog-count (add1 catalog-count))
            (error 'test "missing transaction consulted catalog"))))
       (define scan-command
         (scan-barcode-command
          "cmd-missing-scan" "txn-missing-commands" 0 test-barcode))
       (define tender-command
         (tender-cash-command
          "cmd-missing-tender" "txn-missing-commands" 8 (money 500)))

       (check-outcome
        (resolved-receipt
         (transaction-service-execute-command service scan-command))
        scan-command 'not-found "transaction_not_found" 0)
       (check-outcome
        (resolved-receipt
         (transaction-service-execute-command service tender-command))
        tender-command 'not-found "transaction_not_found" 0)
       (check-equal? catalog-count 0)
       (check-equal? (journal-version connection "txn-missing-commands") 0))))

  (test-case "stale scan is rejected before catalog and retry keeps old version"
    (call-with-store
     (lambda (connection)
       (define catalog-count 0)
       (define service
         (make-test-service
          connection
          #:catalog-lookup
          (lambda (barcode)
            (set! catalog-count (add1 catalog-count))
            (fake-catalog-lookup barcode))))
       (execute-start! service "txn-stale" "cmd-stale-start")
       (execute-scan! service "txn-stale" "cmd-stale-scan-1" 1 test-barcode)
       (execute-scan! service "txn-stale" "cmd-stale-scan-2" 2 test-barcode)
       (define stale-command
         (scan-barcode-command
          "cmd-stale" "txn-stale" 2 test-barcode))
       (define lookups-before catalog-count)
       (define stale-receipt
         (resolved-receipt
          (transaction-service-execute-command service stale-command)))

       (check-outcome stale-receipt
                      stale-command
                      'version-conflict
                      "stale_expected_version"
                      3)
       (check-equal? catalog-count lookups-before)
       (execute-scan! service "txn-stale" "cmd-stale-winner" 3 test-barcode)
       (define retry-lookups-before catalog-count)
       (define retried
         (resolved-receipt
          (transaction-service-execute-command service stale-command)))
       (check-equal? retried stale-receipt)
       (check-equal? (transaction-command-receipt-outcome-stream-version retried)
                     3)
       (check-equal? catalog-count retry-lookups-before)
       (check-equal? (journal-version connection "txn-stale") 4))))

  (test-case "cash and lifecycle domain rejections become durable codes"
    (call-with-store
     (lambda (connection)
       (define service (make-test-service connection))

       (execute-start! service "txn-empty" "cmd-empty-start")
       (define empty-command
         (tender-cash-command "cmd-empty" "txn-empty" 1 (money 500)))
       (check-outcome
        (resolved-receipt
         (transaction-service-execute-command service empty-command))
        empty-command 'domain-rejected "empty_transaction" 1)

       (start-and-scan! service "txn-insufficient" "cmd-insufficient")
       (define insufficient-command
         (tender-cash-command
          "cmd-insufficient-cash" "txn-insufficient" 2 (money 198)))
       (check-outcome
        (resolved-receipt
         (transaction-service-execute-command service insufficient-command))
        insufficient-command 'domain-rejected "insufficient_tender" 2)

       (start-and-scan! service "txn-invalid" "cmd-invalid")
       (define invalid-command
         (complete-transaction-command
          "cmd-invalid-complete" "txn-invalid" 2))
       (check-outcome
        (resolved-receipt
         (transaction-service-execute-command service invalid-command))
        invalid-command 'domain-rejected "invalid_transaction_state" 2)

       (check-equal? (journal-version connection "txn-empty") 1)
       (check-equal? (journal-version connection "txn-insufficient") 2)
       (check-equal? (journal-version connection "txn-invalid") 2))))

  (test-case "invalid-state scan rejects before catalog lookup"
    (call-with-store
     (lambda (connection)
       (define catalog-count 0)
       (define service
         (make-test-service
          connection
          #:catalog-lookup
          (lambda (barcode)
            (set! catalog-count (add1 catalog-count))
            (fake-catalog-lookup barcode))))
       (start-and-scan! service "txn-paid-scan" "cmd-paid-scan")
       (resolved-receipt
        (transaction-service-execute-command
         service
         (tender-cash-command
          "cmd-paid-cash" "txn-paid-scan" 2 (money 500))))
       (define command
         (scan-barcode-command
          "cmd-paid-rescan" "txn-paid-scan" 3 test-barcode))
       (define catalog-before catalog-count)
       (define receipt
         (resolved-receipt
          (transaction-service-execute-command service command)))

       (check-outcome receipt
                      command
                      'domain-rejected
                      "invalid_transaction_state"
                      3)
       (check-equal? catalog-count catalog-before)
       (check-equal? (journal-version connection "txn-paid-scan") 3))))

  (test-case "invalid start version is not frozen over corrupt journal"
    (call-with-store
     (lambda (connection)
       (append-transaction-events!
        connection
        "txn-corrupt-start"
        0
        (list (transaction-started "txn-corrupt-start")))
       (db:query-exec
        connection
        #<<SQL
INSERT INTO transaction_events
  (transaction_id, stream_sequence, schema_version, event_type, event_json)
VALUES ('txn-corrupt-start', 2, 1, 'sale_item_added', '{not-json')
SQL
        )
       (define service (make-test-service connection))
       (define command
         (start-transaction-command
          "cmd-corrupt-start" "txn-corrupt-start" 9))

       (define result
         (transaction-service-execute-command service command))

       (check-pred transaction-service-recovery-failed? result)
       (check-equal? (transaction-service-recovery-failed-stage result)
                     'journal-load)
       (check-pred
        receipt-load-not-found?
        (load-transaction-command-receipt
         connection "cmd-corrupt-start")))))

  (test-case "journal and replay corruption prevent command persistence"
    (call-with-store
     (lambda (connection)
       (define catalog-count 0)
       (define commit-count 0)
       (define service
         (make-test-service
          connection
          #:catalog-lookup
          (lambda (_barcode)
            (set! catalog-count (add1 catalog-count))
            (error 'test "corrupt transaction consulted catalog"))
          #:commit-command!
          (lambda (connection* plan)
            (set! commit-count (add1 commit-count))
            (commit-transaction-command-outcome! connection* plan))))
       (append-transaction-events!
        connection "txn-corrupt-json" 0
        (list (transaction-started "txn-corrupt-json")))
       (db:query-exec
        connection
        #<<SQL
INSERT INTO transaction_events
  (transaction_id, stream_sequence, schema_version, event_type, event_json)
VALUES ('txn-corrupt-json', 2, 1, 'sale_item_added', '{not-json')
SQL
        )
       (append-transaction-events!
        connection "txn-corrupt-replay" 0
        (list (transaction-started "txn-corrupt-replay")
              (transaction-completed)))

       (for ([transaction-id (in-list '("txn-corrupt-json"
                                        "txn-corrupt-replay"))]
             [command-id (in-list '("cmd-corrupt-json"
                                    "cmd-corrupt-replay"))]
             [expected-stage (in-list '(journal-load replay))])
         (define result
           (transaction-service-execute-command
            service
            (scan-barcode-command
             command-id transaction-id 1 test-barcode)))
         (check-pred transaction-service-recovery-failed? result)
         (check-equal? (transaction-service-recovery-failed-stage result)
                       expected-stage))
       (check-equal? catalog-count 0)
       (check-equal? commit-count 0)
       (check-equal? (receipt-row-count connection) 0))))

  (test-case "catalog infrastructure failure is retryable with same command ID"
    (call-with-store
     (lambda (connection)
       (define catalog-available? #f)
       (define service
         (make-test-service
          connection
          #:catalog-lookup
          (lambda (barcode)
            (if catalog-available?
                (fake-catalog-lookup barcode)
                (error 'catalog "temporarily unavailable")))))
       (execute-start! service "txn-catalog-retry" "cmd-catalog-start")
       (define command
         (scan-barcode-command
          "cmd-catalog-retry" "txn-catalog-retry" 1 test-barcode))

       (check-exn
        exn:fail?
        (lambda ()
          (transaction-service-execute-command service command)))
       (check-pred
        receipt-load-not-found?
        (load-transaction-command-receipt connection "cmd-catalog-retry"))
       (check-equal? (journal-version connection "txn-catalog-retry") 1)

       (set! catalog-available? #t)
       (define receipt
         (resolved-receipt
          (transaction-service-execute-command service command)))
       (check-outcome receipt command 'accepted "accepted" 2))))

  (test-case "stable unit-of-work failure maps without provisional success"
    (call-with-store
     (lambda (connection)
       (define service
         (make-test-service
          connection
          #:commit-command!
          (lambda (_connection _plan)
            (transaction-command-commit-failed
             'receipt-insert-conflict
             'command-id-conflict
             "test persistence failure"))))
       (define command
         (start-transaction-command "cmd-uow-fail" "txn-uow-fail" 0))
       (define result
         (transaction-service-execute-command service command))

       (check-pred transaction-service-command-persistence-failed? result)
       (check-equal?
        (transaction-service-command-persistence-failed-command-id result)
        "cmd-uow-fail")
       (check-equal?
        (transaction-service-command-persistence-failed-code result)
        'receipt-insert-conflict)
       (check-false (transaction-service-command-resolved? result))
       (check-equal? (journal-version connection "txn-uow-fail") 0))))

  (test-case "final unit-of-work race receipt passes through without redecision"
    (call-with-store
     (lambda (connection)
       (define command
         (start-transaction-command "cmd-final-race" "txn-final-race" 0))
       (define final-receipt
         (transaction-command-receipt
          command
          'version-conflict
          "stream_version_conflict"
          1))
       (define commit-count 0)
       (define service
         (make-test-service
          connection
          #:commit-command!
          (lambda (_connection _plan)
            (set! commit-count (add1 commit-count))
            (transaction-command-commit-resolved final-receipt))))

       (define receipt
         (resolved-receipt
          (transaction-service-execute-command service command)))

       (check-equal? receipt final-receipt)
       (check-equal? commit-count 1)
       (check-equal? (journal-version connection "txn-final-race") 0))))

  (test-case "transaction query remains independent of corrupt receipts"
    (call-with-store
     (lambda (connection)
       (append-transaction-events!
        connection
        "txn-query-only"
        0
        (list (transaction-started "txn-query-only")))
       (insert-transaction-command-receipt!
        connection
        (transaction-command-receipt
         (start-transaction-command "cmd-unrelated" "txn-other" 0)
         'accepted
         "accepted"
         1))
       (db:query-exec connection "PRAGMA ignore_check_constraints = ON")
       (db:query-exec
        connection
        "UPDATE transaction_command_receipts SET outcome_code = '' WHERE command_id = 'cmd-unrelated'")
       (define service (make-test-service connection))

       (define transaction
         (query-transaction service "txn-query-only" 1))
       (check-equal? (transaction-id transaction) "txn-query-only")
       (check-equal? (transaction-status transaction) 'open))))

  (test-case "SQLite load exceptions remain infrastructure failures"
    (call-with-store
     (lambda (connection)
       (define service
         (make-test-service
          connection
          #:load-events
          (lambda (connection* _transaction-id)
            (db:query-exec connection* "SELECT * FROM missing_load_table"))))
       (check-exn
        db:exn:fail:sql?
        (lambda ()
          (transaction-service-load-transaction service "txn-load-failure"))))))

  (test-case "SQLite command-commit exceptions never become resolved outcomes"
    (call-with-store
     (lambda (connection)
       (define service
         (make-test-service
          connection
          #:commit-command!
          (lambda (connection* _plan)
            (db:query-exec
             connection* "INSERT INTO missing_commit_table VALUES (1)"))))
       (define command
         (start-transaction-command
          "cmd-operational-failure" "txn-operational-failure" 0))

       (check-exn
        db:exn:fail:sql?
        (lambda ()
          (transaction-service-execute-command service command)))
       (check-equal? (journal-version connection "txn-operational-failure") 0)
       (check-pred
        receipt-load-not-found?
        (load-transaction-command-receipt
         connection "cmd-operational-failure")))))

  (test-case "typed commands keep transaction streams isolated"
    (call-with-store
     (lambda (connection)
       (define service (make-test-service connection))
       (execute-start! service "txn-A" "cmd-A-start")
       (execute-start! service "txn-B" "cmd-B-start")
       (execute-scan! service "txn-A" "cmd-A-scan" 1 test-barcode)
       (execute-scan! service "txn-B" "cmd-B-scan-1" 1 test-barcode)
       (execute-scan! service "txn-B" "cmd-B-scan-2" 2 test-barcode)
       (resolved-receipt
        (transaction-service-execute-command
         service
         (tender-cash-command "cmd-A-cash" "txn-A" 2 (money 500))))

       (define transaction-A (query-transaction service "txn-A" 3))
       (define transaction-B (query-transaction service "txn-B" 3))
       (check-equal? (transaction-status transaction-A) 'paid)
       (check-equal? (transaction-subtotal transaction-A) (money 199))
       (check-equal? (transaction-status transaction-B) 'open)
       (check-equal? (transaction-subtotal transaction-B) (money 398))
       (check-equal?
        (journal-events connection "txn-A")
        (list (transaction-started "txn-A")
              test-sale-item-event
              (cash-tendered (money 500))))
       (check-equal?
        (journal-events connection "txn-B")
        (list (transaction-started "txn-B")
              test-sale-item-event
              test-sale-item-event)))))

  (test-case "accepted remove appends one correction and same-ID retry is inert"
    (call-with-store
     (lambda (connection)
       (define lookup-count 0)
       (define service
         (make-test-service
          connection
          #:catalog-lookup
          (lambda (barcode)
            (set! lookup-count (add1 lookup-count))
            (fake-catalog-lookup barcode))))
       (execute-start! service "txn-remove" "cmd-remove-start")
       (for ([index (in-range 3)])
         (execute-scan! service
                        "txn-remove"
                        (format "cmd-remove-scan-~a" index)
                        (add1 index)
                        test-barcode))
       (define command
         (remove-line-item-command
          "cmd-remove-once" "txn-remove" 4 1))
       (define lookups-before lookup-count)
       (define original
         (resolved-receipt
          (transaction-service-execute-command service command)))
       (define retried
         (resolved-receipt
          (transaction-service-execute-command service command)))

       (check-equal? original retried)
       (check-outcome original command 'accepted "accepted" 5)
       (check-equal? lookup-count lookups-before)
       (check-equal?
        (journal-events connection "txn-remove")
        (list (transaction-started "txn-remove")
              test-sale-item-event
              test-sale-item-event
              test-sale-item-event
              (sale-line-removed 1)))
       (define transaction
         (query-transaction service "txn-remove" 5))
       (check-equal? (length (transaction-line-items transaction)) 2)
       (check-equal? (transaction-subtotal transaction) (money 398)))))

  (test-case "out-of-range removal is durable and does no catalog work"
    (call-with-store
     (lambda (connection)
       (define lookup-count 0)
       (define service
         (make-test-service
          connection
          #:catalog-lookup
          (lambda (barcode)
            (set! lookup-count (add1 lookup-count))
            (fake-catalog-lookup barcode))))
       (execute-start! service "txn-remove-miss" "cmd-remove-miss-start")
       (define command
         (remove-line-item-command
          "cmd-remove-miss" "txn-remove-miss" 1 0))
       (define receipt
         (resolved-receipt
          (transaction-service-execute-command service command)))

       (check-outcome
        receipt command 'domain-rejected "line_item_not_found" 1)
       (check-equal? lookup-count 0)
       (check-equal?
        (journal-events connection "txn-remove-miss")
        (list (transaction-started "txn-remove-miss"))))))

  (test-case "stale line index is never interpreted against a newer basket"
    (call-with-store
     (lambda (connection)
       (define service (make-test-service connection))
       (execute-start! service "txn-stale-remove" "cmd-stale-remove-start")
       (for ([index (in-range 3)])
         (execute-scan! service
                        "txn-stale-remove"
                        (format "cmd-stale-remove-scan-~a" index)
                        (add1 index)
                        test-barcode))
       (define stale-command
         (remove-line-item-command
          "cmd-stale-remove" "txn-stale-remove" 4 1))
       (execute-scan! service
                      "txn-stale-remove"
                      "cmd-advance-before-remove"
                      4
                      test-barcode)
       (define receipt
         (resolved-receipt
          (transaction-service-execute-command service stale-command)))

       (check-outcome
        receipt stale-command 'version-conflict "stale_expected_version" 5)
       (define transaction
         (query-transaction service "txn-stale-remove" 5))
       (check-equal? (length (transaction-line-items transaction)) 4)
       (check-false
        (ormap sale-line-removed?
               (journal-events connection "txn-stale-remove"))))))

  (test-case "void is durable, terminal, catalog-independent, and idempotent"
    (call-with-store
     (lambda (connection)
       (define lookup-count 0)
       (define service
         (make-test-service
          connection
          #:catalog-lookup
          (lambda (barcode)
            (set! lookup-count (add1 lookup-count))
            (fake-catalog-lookup barcode))))
       (start-and-scan! service "txn-void" "cmd-void")
       (define command
         (void-transaction-command "cmd-void-once" "txn-void" 2))
       (define lookups-before lookup-count)
       (define original
         (resolved-receipt
          (transaction-service-execute-command service command)))
       (define retried
         (resolved-receipt
          (transaction-service-execute-command service command)))

       (check-equal? original retried)
       (check-outcome original command 'accepted "accepted" 3)
       (check-equal? lookup-count lookups-before)
       (check-equal?
        (journal-events connection "txn-void")
        (list (transaction-started "txn-void")
              test-sale-item-event
              (transaction-voided)))
       (define transaction (query-transaction service "txn-void" 3))
       (check-equal? (transaction-status transaction) 'voided)
       (check-equal? (transaction-subtotal transaction) (money 199)))))

  (test-case "same command ID cannot change correction identity"
    (call-with-store
     (lambda (connection)
       (define service (make-test-service connection))
       (start-and-scan! service "txn-reuse-correction" "cmd-reuse-correction")
       (define original
         (remove-line-item-command
          "cmd-correction-reuse" "txn-reuse-correction" 2 0))
       (resolved-receipt
        (transaction-service-execute-command service original))

       (for ([different
              (in-list
               (list
                (remove-line-item-command
                 "cmd-correction-reuse" "txn-reuse-correction" 2 1)
                (void-transaction-command
                 "cmd-correction-reuse" "txn-reuse-correction" 2)))])
         (check-pred
          transaction-service-command-id-reused?
          (transaction-service-execute-command service different))))))

  (test-case "unsafe identity-free mutation functions are no longer exported"
    (for ([name (in-list '(transaction-service-start-transaction
                           transaction-service-scan-barcode
                           transaction-service-tender-cash
                           transaction-service-complete-transaction))])
      (check-exn
       exn:fail?
       (lambda ()
         (dynamic-require
          "../pos/application/transaction-service.rkt"
          name)))))
)
