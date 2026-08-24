#lang racket

(require (prefix-in db: db)
         racket/file
         rackunit
         "../pos/application/register-operations-service.rkt"
         "../pos/application/transaction-command-receipt.rkt"
         "../pos/application/transaction-command.rkt"
         "../pos/application/transaction-service.rkt"
         "../pos/domain/fake-catalog.rkt"
         "../pos/domain/money.rkt"
         "../pos/domain/register-operations.rkt"
         "../pos/domain/transaction-event.rkt"
         (prefix-in op: "../pos/domain/transaction-operational-context.rkt")
         "../pos/domain/transaction.rkt"
         "../pos/persistence/operational-configuration-snapshot-codec.rkt"
         "../pos/persistence/pos-database-migrations.rkt"
         "../pos/persistence/sqlite-register-operations.rkt"
         "../pos/persistence/sqlite-transaction-event-store.rkt"
         "../pos/persistence/transaction-command-receipt-store.rkt"
         "../pos/persistence/transaction-command-unit-of-work.rkt")

(define configuration-json
  "{\"schema_version\":1,\"register\":{\"register_id\":\"register-one\",\"display_name\":\"Register One\"},\"cashiers\":[{\"cashier_id\":\"cashier-one\",\"display_name\":\"Alice\",\"active\":true}]}")

(define (configuration)
  (operational-configuration-decode-success-snapshot
   (json-string->operational-configuration-snapshot configuration-json)))

(define (activate-and-open! connection)
  (activate-operational-configuration! connection (configuration))
  (register-operations-open-shift
   (make-register-operations-service
    connection
    #:current-epoch-ms (lambda () 1000)
    #:generate-shift-id (lambda () "shift-one"))
   "cashier-one"))

(define (make-operational-service connection clock
                                  #:commit-command!
                                  [commit-command!
                                   commit-transaction-command-outcome!])
  (make-transaction-service
   connection
   #:catalog-lookup fake-catalog-lookup
   #:current-epoch-ms clock
   #:commit-command! commit-command!))

(define (resolved-receipt result)
  (check-pred transaction-service-command-resolved? result)
  (transaction-service-command-resolved-receipt result))

(define (load-events connection transaction-id)
  (define result (load-transaction-events connection transaction-id))
  (check-pred journal-load-succeeded? result)
  (journal-load-succeeded-events result))

(define (call-with-memory-database procedure)
  (define connection (db:sqlite3-connect #:database 'memory))
  (dynamic-wind
    (lambda () (migrate-pos-database! connection))
    (lambda () (procedure connection))
    (lambda () (db:disconnect connection))))

(module+ test
  (test-case "operational start and completion couple event receipt and shift slot"
    (call-with-memory-database
     (lambda (connection)
       (activate-and-open! connection)
       (define times (box '(2000 2500 3000)))
       (define service
         (make-operational-service
          connection
          (lambda ()
            (define value (first (unbox times)))
            (set-box! times (rest (unbox times)))
            value)))
       (resolved-receipt
        (transaction-service-execute-command
         service
         (start-transaction-command "cmd-start" "txn-one" 0)))
       (define start-event (first (load-events connection "txn-one")))
       (check-pred operational-transaction-started? start-event)
       (define context (operational-transaction-started-context start-event))
       (check-equal? context
                     (op:transaction-operational-context
                      "register-one" "Register One"
                      "cashier-one" "Alice" "shift-one" 2000))
       (check-equal?
        (db:query-value
         connection
         "SELECT active_transaction_id FROM register_shifts WHERE shift_id = 'shift-one'")
        "txn-one")

       (resolved-receipt
        (transaction-service-execute-command
         service
         (scan-barcode-command
          "cmd-scan" "txn-one" 1 "049000001234")))
       (resolved-receipt
        (transaction-service-execute-command
         service
         (tender-cash-command "cmd-tender" "txn-one" 2 (money 500))))
       (define rejected-void
         (resolved-receipt
          (transaction-service-execute-command
           service
           (void-transaction-command "cmd-void-paid" "txn-one" 3))))
       (check-equal?
        (transaction-command-receipt-outcome-code rejected-void)
        "invalid_transaction_state")
       (check-equal?
        (db:query-value
         connection
         "SELECT active_transaction_id FROM register_shifts WHERE shift_id = 'shift-one'")
        "txn-one")
       (resolved-receipt
        (transaction-service-execute-command
         service
         (complete-transaction-command "cmd-complete" "txn-one" 3)))
       (define terminal-event (last (load-events connection "txn-one")))
       (check-equal? terminal-event (timestamped-transaction-completed 3000))
       (check-true
        (db:sql-null?
         (db:query-value
          connection
          "SELECT active_transaction_id FROM register_shifts WHERE shift_id = 'shift-one'"))))) )

  (test-case "receipt insertion failure rolls back shift claim and start event"
    (call-with-memory-database
     (lambda (connection)
       (activate-and-open! connection)
       (define service
         (make-operational-service
          connection
          (lambda () 2000)
          #:commit-command!
          (lambda (connection plan)
            (commit-transaction-command-outcome!
             connection
             plan
             #:insert-receipt!
             (lambda (connection receipt)
               (insert-transaction-command-receipt! connection receipt)
               (insert-transaction-command-receipt! connection receipt))))))
       (define result
         (transaction-service-execute-command
          service
          (start-transaction-command "cmd-fail" "txn-fail" 0)))
       (check-pred transaction-service-command-persistence-failed? result)
       (check-equal? (load-events connection "txn-fail") '())
       (check-true
        (db:sql-null?
         (db:query-value
          connection
          "SELECT active_transaction_id FROM register_shifts WHERE shift_id = 'shift-one'")))
       (check-equal?
        (db:query-value
         connection
         "SELECT COUNT(*) FROM transaction_command_receipts WHERE command_id = 'cmd-fail'")
        0))))

  (test-case "durable start and completion receipts win after slot release and shift close"
    (call-with-memory-database
     (lambda (connection)
       (activate-and-open! connection)
       (define times (box '(2000 3000)))
       (define service
         (make-operational-service
          connection
          (lambda ()
            (define value (first (unbox times)))
            (set-box! times (rest (unbox times)))
            value)))
       (define start-command
         (start-transaction-command "cmd-start-retry" "txn-retry" 0))
       (define original-start
         (resolved-receipt
          (transaction-service-execute-command service start-command)))
       (resolved-receipt
        (transaction-service-execute-command
         service
         (scan-barcode-command
          "cmd-scan-retry" "txn-retry" 1 "049000001234")))
       (resolved-receipt
        (transaction-service-execute-command
         service
         (tender-cash-command
          "cmd-tender-retry" "txn-retry" 2 (money 500))))
       (define completion-command
         (complete-transaction-command
          "cmd-complete-retry" "txn-retry" 3))
       (define original-completion
         (resolved-receipt
          (transaction-service-execute-command
           service completion-command)))
       (define close-service
         (make-register-operations-service
          connection
          #:current-epoch-ms (lambda () 4000)
          #:generate-shift-id (lambda () "unused")))
       (check-pred
        register-shift-closed?
        (register-operations-close-shift close-service "shift-one"))

       (check-equal?
        (resolved-receipt
         (transaction-service-execute-command service start-command))
        original-start)
       (check-equal?
        (resolved-receipt
         (transaction-service-execute-command service completion-command))
        original-completion)
       (check-equal? (length (load-events connection "txn-retry")) 4))))

  (test-case "commit boundary permits only one start to claim an idle shift"
    (define database-path
      (make-temporary-file "grocery-pos-operational-race-~a.sqlite"))
    (define connection-a #f)
    (define connection-b #f)
    (dynamic-wind
      void
      (lambda ()
        (set! connection-a
              (db:sqlite3-connect #:database database-path #:mode 'create))
        (migrate-pos-database! connection-a)
        (activate-and-open! connection-a)
        (set! connection-b
              (db:sqlite3-connect #:database database-path #:mode 'read/write))
        (migrate-pos-database! connection-b)
        (define arrivals (make-channel))
        (define results (make-channel))
        (define release-a (make-semaphore 0))
        (define release-b (make-semaphore 0))
        (define (controlled label release)
          (lambda (connection plan)
            (channel-put arrivals label)
            (semaphore-wait release)
            (commit-transaction-command-outcome! connection plan)))
        (define service-a
          (make-operational-service
           connection-a (lambda () 2000)
           #:commit-command! (controlled 'a release-a)))
        (define service-b
          (make-operational-service
           connection-b (lambda () 2001)
           #:commit-command! (controlled 'b release-b)))
        (define (run label service command)
          (thread
           (lambda ()
             (channel-put results
                          (cons label
                                (transaction-service-execute-command
                                 service command))))))
        (run 'a service-a
             (start-transaction-command "cmd-a" "txn-a" 0))
        (run 'b service-b
             (start-transaction-command "cmd-b" "txn-b" 0))
        (define first (sync/timeout 10 arrivals))
        (define second (sync/timeout 10 arrivals))
        (check-equal? (sort (list first second) symbol<?) '(a b))
        (semaphore-post release-a)
        (define first-result (sync/timeout 10 results))
        (check-equal? (car first-result) 'a)
        (check-equal?
         (transaction-command-receipt-outcome-kind
          (resolved-receipt (cdr first-result)))
         'accepted)
        (semaphore-post release-b)
        (define second-result (sync/timeout 10 results))
        (check-equal? (car second-result) 'b)
        (define second-receipt (resolved-receipt (cdr second-result)))
        (check-equal?
         (transaction-command-receipt-outcome-kind second-receipt)
         'domain-rejected)
        (check-equal?
         (transaction-command-receipt-outcome-code second-receipt)
         "shift_has_active_transaction")
        (check-equal?
         (db:query-value
          connection-a
          "SELECT active_transaction_id FROM register_shifts WHERE shift_id = 'shift-one'")
         "txn-a")
        (check-equal?
         (db:query-value connection-a "SELECT COUNT(*) FROM transaction_events")
         1))
      (lambda ()
        (when (and connection-b (db:connected? connection-b))
          (db:disconnect connection-b))
        (when (and connection-a (db:connected? connection-a))
          (db:disconnect connection-a))
        (when (file-exists? database-path)
          (delete-file database-path))))))
