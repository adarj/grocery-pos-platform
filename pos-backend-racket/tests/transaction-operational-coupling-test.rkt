#lang racket

(require "support/seed-authenticated-operator.rkt")

(require (prefix-in db: db)
         racket/file
         rackunit
         "../pos/application/authentication-service.rkt"
         "../pos/application/register-operations-service.rkt"
         "../pos/application/transaction-command-receipt.rkt"
         "../pos/application/transaction-command.rkt"
         (rename-in "../pos/application/transaction-service.rkt"
                    [transaction-service-execute-command
                     execute-command/authorized])
         "../pos/domain/catalog-item.rkt"
         "../pos/domain/fake-catalog.rkt"
         "../pos/domain/money.rkt"
         "../pos/domain/register-operations.rkt"
         "../pos/domain/shift-cash-accountability.rkt"
         "../pos/domain/tax.rkt"
         "../pos/domain/transaction-event.rkt"
         "../pos/domain/transaction-void-approval.rkt"
         (prefix-in op: "../pos/domain/transaction-operational-context.rkt")
         "../pos/domain/transaction.rkt"
         "../pos/persistence/operational-configuration-snapshot-codec.rkt"
         "../pos/persistence/pos-database-migrations.rkt"
         "../pos/persistence/sqlite-register-operations.rkt"
         "../pos/persistence/sqlite-shift-cash-accountability.rkt"
         "../pos/persistence/sqlite-transaction-event-store.rkt"
         "../pos/persistence/transaction-command-receipt-store.rkt"
         "../pos/persistence/transaction-command-unit-of-work.rkt"
         "../pos/persistence/transaction-void-approval-store.rkt"
         "../pos/security/transaction-void-approval.rkt")

(define test-approval-capability
  (transaction-void-approval-token->capability
   (string-append "gpos_a1_" (make-string 64 #\b))))

(define cashier-one-principal
  (authenticated-operator "cashier-one" "Alice" 'cashier 1))

(define (transaction-service-execute-command service command)
  (execute-command/authorized
   service cashier-one-principal command
   #:approval-capability
   (and (void-transaction-command? command) test-approval-capability)))

(define configuration-json
  "{\"schema_version\":1,\"register\":{\"register_id\":\"register-one\",\"display_name\":\"Register One\"},\"cashiers\":[{\"cashier_id\":\"cashier-one\",\"display_name\":\"Alice\",\"active\":true}]}")

(define (configuration)
  (operational-configuration-decode-success-snapshot
   (json-string->operational-configuration-snapshot configuration-json)))

(define (activate-and-open! connection)
  (activate-operational-configuration! connection (configuration))
  (seed-authenticated-test-operator! connection "cashier-one" 'cashier)
  (register-operations-open-shift
   (make-register-operations-service
    connection
    #:current-epoch-ms (lambda () 1000)
   #:generate-shift-id (lambda () "shift-one"))
   cashier-one-principal
   (money 10000)))

(define (make-operational-service connection clock
                                  #:catalog-lookup
                                  [catalog-lookup fake-catalog-lookup]
                                  #:commit-command!
                                  [commit-command!
                                   commit-transaction-command-outcome!])
  (make-transaction-service
   connection
   #:catalog-lookup catalog-lookup
   #:current-epoch-ms clock
   #:commit-command! commit-command!
   ;; Preserve business/shift coupling coverage with explicit test approval
   ;; evidence; grant validation is covered by the dedicated approval tests.
   #:approval-consumer
   (lambda (_connection _capability _requester _revision command)
     (transaction-void-approval-consumed
      (transaction-command-approver-attribution
       (transaction-command-command-id command)
       (string-append "test-approval-"
                      (transaction-command-command-id command))
       "test-supervisor" 1 1000)))))

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
       (check-equal?
        (db:query-row
         connection
         #<<SQL
SELECT movement_sequence, movement_type, amount_minor_units,
       transaction_id, recorded_at_epoch_ms
FROM shift_cash_movements
WHERE movement_type = 'cash_sale'
SQL
         )
        #(2 "cash_sale" 199 "txn-one" 3000))
       (define cash-result
         (load-shift-cash-summary connection "shift-one"))
       (check-pred shift-cash-summary-found? cash-result)
       (define cash-summary (shift-cash-summary-found-summary cash-result))
       (check-equal?
        (money-minor-units (shift-cash-summary-opening-cash cash-summary))
        10000)
       (check-equal? (shift-cash-summary-completed-cash-sale-count cash-summary) 1)
       (check-equal?
        (money-minor-units (shift-cash-summary-cash-sales cash-summary))
        199)
       (check-equal?
        (money-minor-units (shift-cash-summary-expected-cash cash-summary))
        10199)
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
        (register-operations-close-shift
         close-service cashier-one-principal "shift-one" (money 10000)))

       (check-equal?
        (resolved-receipt
         (transaction-service-execute-command service start-command))
        original-start)
       (check-equal?
        (resolved-receipt
         (transaction-service-execute-command service completion-command))
        original-completion)
       (check-equal? (length (load-events connection "txn-retry")) 4)
       (check-equal?
        (db:query-value
         connection
         "SELECT COUNT(*) FROM shift_cash_movements WHERE movement_type = 'cash_sale' AND transaction_id = 'txn-retry'")
        1))))

  (test-case "cash movement insertion failure rolls back completion receipt event and slot release"
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
       (resolved-receipt
        (transaction-service-execute-command
         service (start-transaction-command "cmd-start-fail-cash" "txn-fail-cash" 0)))
       (resolved-receipt
        (transaction-service-execute-command
         service (scan-barcode-command "cmd-scan-fail-cash" "txn-fail-cash" 1 "049000001234")))
       (resolved-receipt
        (transaction-service-execute-command
         service (tender-cash-command "cmd-tender-fail-cash" "txn-fail-cash" 2 (money 500))))
       (db:query-exec
        connection
        #<<SQL
CREATE TRIGGER fail_cash_sale_insert
BEFORE INSERT ON shift_cash_movements
WHEN NEW.movement_type = 'cash_sale'
BEGIN
  SELECT RAISE(ABORT, 'simulated cash movement failure');
END
SQL
        )
       (check-exn
        db:exn:fail:sql?
        (lambda ()
          (transaction-service-execute-command
           service
           (complete-transaction-command
            "cmd-complete-fail-cash" "txn-fail-cash" 3))))
       (check-equal? (length (load-events connection "txn-fail-cash")) 3)
       (check-equal?
        (db:query-value connection "SELECT COUNT(*) FROM transaction_command_receipts WHERE command_id = 'cmd-complete-fail-cash'")
        0)
       (check-equal?
        (db:query-value connection "SELECT COUNT(*) FROM shift_cash_movements WHERE movement_type = 'cash_sale'")
        0)
       (check-equal?
        (db:query-value connection "SELECT active_transaction_id FROM register_shifts WHERE shift_id = 'shift-one'")
        "txn-fail-cash"))))

  (test-case "shift release failure rolls back completion movement receipt and event"
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
       (resolved-receipt
        (transaction-service-execute-command
         service (start-transaction-command "cmd-start-fail-release" "txn-fail-release" 0)))
       (resolved-receipt
        (transaction-service-execute-command
         service (scan-barcode-command "cmd-scan-fail-release" "txn-fail-release" 1 "049000001234")))
       (resolved-receipt
        (transaction-service-execute-command
         service (tender-cash-command "cmd-tender-fail-release" "txn-fail-release" 2 (money 500))))
       (db:query-exec
        connection
        #<<SQL
CREATE TRIGGER fail_shift_release
BEFORE UPDATE OF active_transaction_id ON register_shifts
WHEN OLD.active_transaction_id IS NOT NULL
 AND NEW.active_transaction_id IS NULL
BEGIN
  SELECT RAISE(ABORT, 'simulated shift release failure');
END
SQL
        )
       (check-exn
        db:exn:fail:sql?
        (lambda ()
          (transaction-service-execute-command
           service
           (complete-transaction-command
            "cmd-complete-fail-release" "txn-fail-release" 3))))
       (check-equal? (length (load-events connection "txn-fail-release")) 3)
       (check-equal?
        (db:query-value connection "SELECT COUNT(*) FROM transaction_command_receipts WHERE command_id = 'cmd-complete-fail-release'")
        0)
       (check-equal?
        (db:query-value connection "SELECT COUNT(*) FROM shift_cash_movements WHERE movement_type = 'cash_sale'")
        0)
       (check-equal?
        (db:query-value connection "SELECT active_transaction_id FROM register_shifts WHERE shift_id = 'shift-one'")
        "txn-fail-release"))))

  (test-case "void creates no cash movement and zero-total completion still counts"
    (call-with-memory-database
     (lambda (connection)
       (activate-and-open! connection)
       (define times (box '(2000 3000 4000 5000)))
       (define zero-item
         (catalog-item "zero" "Zero Item" (money 0) "zero" (tax-rate 0)))
       (define service
         (make-operational-service
          connection
          (lambda ()
            (define value (first (unbox times)))
            (set-box! times (rest (unbox times)))
            value)
          #:catalog-lookup
          (lambda (barcode) (and (string=? barcode "zero") zero-item))))
       (resolved-receipt
        (transaction-service-execute-command
         service (start-transaction-command "cmd-start-void" "txn-void" 0)))
       (resolved-receipt
        (transaction-service-execute-command
         service (void-transaction-command "cmd-void" "txn-void" 1)))
       (check-equal?
        (db:query-value connection "SELECT COUNT(*) FROM shift_cash_movements WHERE movement_type = 'cash_sale'")
        0)
       (resolved-receipt
        (transaction-service-execute-command
         service (start-transaction-command "cmd-start-zero" "txn-zero" 0)))
       (resolved-receipt
        (transaction-service-execute-command
         service (scan-barcode-command "cmd-scan-zero" "txn-zero" 1 "zero")))
       (resolved-receipt
        (transaction-service-execute-command
         service (tender-cash-command "cmd-tender-zero" "txn-zero" 2 (money 0))))
       (resolved-receipt
        (transaction-service-execute-command
         service (complete-transaction-command "cmd-complete-zero" "txn-zero" 3)))
       (define summary-result (load-shift-cash-summary connection "shift-one"))
       (check-pred shift-cash-summary-found? summary-result)
       (define summary (shift-cash-summary-found-summary summary-result))
       (check-equal? (shift-cash-summary-completed-cash-sale-count summary) 1)
       (check-equal? (money-minor-units (shift-cash-summary-cash-sales summary)) 0))))

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
