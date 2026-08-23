#lang racket

(require (prefix-in db: db)
         racket/file
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

(define (call-with-connection database-path mode procedure)
  (define connection
    (db:sqlite3-connect #:database database-path #:mode mode))
  (dynamic-wind
    void
    (lambda () (procedure connection))
    (lambda () (db:disconnect connection))))

(define (call-with-two-connections procedure)
  (define database-path
    (make-temporary-file "grocery-pos-command-race-~a.sqlite"))
  (define connection-A #f)
  (define connection-B #f)
  (dynamic-wind
    void
    (lambda ()
      (set! connection-A
            (db:sqlite3-connect
             #:database database-path
             #:mode 'create))
      (migrate-pos-database! connection-A)
      (set! connection-B
            (db:sqlite3-connect
             #:database database-path
             #:mode 'read/write))
      (migrate-pos-database! connection-B)
      (procedure database-path connection-A connection-B))
    (lambda ()
      (when (and connection-B (db:connected? connection-B))
        (db:disconnect connection-B))
      (when (and connection-A (db:connected? connection-A))
        (db:disconnect connection-A))
      (when (file-exists? database-path)
        (delete-file database-path)))))

(define (resolved-receipt result)
  (check-pred transaction-service-command-resolved? result)
  (transaction-service-command-resolved-receipt result))

(define (make-service connection catalog-lookup
                      #:commit-command!
                      [commit-command! commit-transaction-command-outcome!])
  (make-transaction-service
   connection
   #:catalog-lookup catalog-lookup
   #:commit-command! commit-command!))

(define (quiet-catalog _barcode)
  (error 'test "this command must not consult the catalog"))

(define (start-transaction! service transaction-id command-id)
  (resolved-receipt
   (transaction-service-execute-command
    service
    (start-transaction-command command-id transaction-id 0))))

(define (loaded-events connection transaction-id)
  (define result
    (load-transaction-events connection transaction-id))
  (check-pred journal-load-succeeded? result)
  (journal-load-succeeded-events result))

(define (receipt-count connection command-id)
  (db:query-value
   connection
   #<<SQL
SELECT COUNT(*)
FROM transaction_command_receipts
WHERE command_id = ?
SQL
   command-id))

(define (loaded-receipt connection command-id)
  (define result
    (load-transaction-command-receipt connection command-id))
  (check-pred receipt-load-found? result)
  (receipt-load-found-receipt result))

;; Each wrapper is invoked only after its service has performed early receipt
;; lookup, journal recovery, expected-version validation, and domain decision.
;; The channel proves that the provisional plan exists; the semaphore gives the
;; test explicit control over final BEGIN IMMEDIATE ordering.
(define (make-controlled-commit label arrivals release)
  (lambda (connection plan)
    (channel-put arrivals (cons label plan))
    (semaphore-wait release)
    (commit-transaction-command-outcome! connection plan)))

(define (start-command-thread label service command results)
  (thread
   (lambda ()
     (with-handlers ([exn?
                      (lambda (exception)
                        (channel-put
                         results
                         (vector label 'exception exception)))])
       (channel-put
        results
        (vector
         label
         'result
         (transaction-service-execute-command service command)))))))

(define (receive-with-timeout channel description)
  (define value (sync/timeout 10 channel))
  (unless value
    (error 'receive-with-timeout "timed out waiting for ~a" description))
  value)

(define (await-both-provisional-plans arrivals)
  (define first-arrival
    (receive-with-timeout arrivals "first provisional command plan"))
  (define second-arrival
    (receive-with-timeout arrivals "second provisional command plan"))
  (define plans
    (hash (car first-arrival) (cdr first-arrival)
          (car second-arrival) (cdr second-arrival)))
  (check-equal? (sort (hash-keys plans) symbol<?) '(A B))
  plans)

(define (release-and-await label release results)
  (semaphore-post release)
  (define outcome
    (receive-with-timeout results (format "caller ~a result" label)))
  (check-equal? (vector-ref outcome 0) label)
  (when (eq? (vector-ref outcome 1) 'exception)
    (raise (vector-ref outcome 2)))
  (check-equal? (vector-ref outcome 1) 'result)
  (vector-ref outcome 2))

(define (call-with-controlled-race
         connection-A
         connection-B
         catalog-lookup-A
         catalog-lookup-B
         command-A
         command-B
         procedure)
  (define arrivals (make-channel))
  (define results (make-channel))
  (define release-A (make-semaphore 0))
  (define release-B (make-semaphore 0))
  (define service-A
    (make-service
     connection-A
     catalog-lookup-A
     #:commit-command!
     (make-controlled-commit 'A arrivals release-A)))
  (define service-B
    (make-service
     connection-B
     catalog-lookup-B
     #:commit-command!
     (make-controlled-commit 'B arrivals release-B)))
  (define thread-A
    (start-command-thread 'A service-A command-A results))
  (define thread-B
    (start-command-thread 'B service-B command-B results))
  (define plans (await-both-provisional-plans arrivals))
  (define result-A (release-and-await 'A release-A results))
  (define result-B (release-and-await 'B release-B results))
  (thread-wait thread-A)
  (thread-wait thread-B)
  (procedure service-A service-B plans result-A result-B))

(module+ test
  (test-case "same command race converges on one receipt and one sale fact"
    (call-with-two-connections
     (lambda (_database-path connection-A connection-B)
       (define setup-service
         (make-service connection-A quiet-catalog))
       (start-transaction! setup-service "txn-same" "cmd-same-start")

       (define lookup-count 0)
       (define lookup-lock (make-semaphore 1))
       (define (counting-catalog barcode)
         (call-with-semaphore
          lookup-lock
          (lambda () (set! lookup-count (add1 lookup-count))))
         (fake-catalog-lookup barcode))
       (define command
         (scan-barcode-command
          "cmd-same" "txn-same" 1 test-barcode))

       (call-with-controlled-race
        connection-A
        connection-B
        counting-catalog
        counting-catalog
        command
        command
        (lambda (service-A _service-B plans result-A result-B)
          (check-equal?
           (transaction-command-commit-plan-outcome-kind
            (hash-ref plans 'A))
           'accepted)
          (check-equal?
           (transaction-command-commit-plan-outcome-kind
            (hash-ref plans 'B))
           'accepted)
          (define receipt-A (resolved-receipt result-A))
          (define receipt-B (resolved-receipt result-B))
          (check-equal? receipt-A receipt-B)
          (check-equal?
           receipt-A
           (transaction-command-receipt
            command 'accepted "accepted" 2))
          (check-equal? (receipt-count connection-A "cmd-same") 1)
          (check-equal?
           (loaded-events connection-A "txn-same")
           (list (transaction-started "txn-same")
                 test-sale-item-event))
          (define recovered
            (transaction-service-load-transaction
             service-A "txn-same"))
          (check-pred transaction-service-success? recovered)
          (check-equal? (transaction-service-success-version recovered) 2)
          (check-equal?
           (transaction-subtotal
            (transaction-service-success-transaction recovered))
           (money 199))

          ;; Both first submissions deliberately reached their provisional
          ;; plans. Once the receipt exists, a later retry must do no catalog
          ;; work and must return the original version-2 outcome.
          (check-equal? lookup-count 2)
          (define lookups-before-retry lookup-count)
          (check-equal?
           (resolved-receipt
            (transaction-service-execute-command service-A command))
           receipt-A)
          (check-equal? lookup-count lookups-before-retry))))))

  (test-case "same ID with different commands race preserves the winner only"
    (call-with-two-connections
     (lambda (_database-path connection-A connection-B)
       (define command-A
         (start-transaction-command "cmd-reused" "txn-winner" 0))
       (define command-B
         (start-transaction-command "cmd-reused" "txn-loser" 0))

       (call-with-controlled-race
        connection-A
        connection-B
        quiet-catalog
        quiet-catalog
        command-A
        command-B
        (lambda (_service-A _service-B plans result-A result-B)
          (check-equal?
           (transaction-command-commit-plan-outcome-kind
            (hash-ref plans 'A))
           'accepted)
          (check-equal?
           (transaction-command-commit-plan-outcome-kind
            (hash-ref plans 'B))
           'accepted)
          (define receipt-A (resolved-receipt result-A))
          (check-equal?
           receipt-A
           (transaction-command-receipt
            command-A 'accepted "accepted" 1))
          (check-pred transaction-service-command-id-reused? result-B)
          (check-equal?
           (transaction-service-command-id-reused-command-id result-B)
           "cmd-reused")
          (check-equal? (receipt-count connection-A "cmd-reused") 1)
          (check-equal? (loaded-receipt connection-A "cmd-reused")
                        receipt-A)
          (check-equal?
           (loaded-events connection-A "txn-winner")
           (list (transaction-started "txn-winner")))
          (check-equal? (loaded-events connection-A "txn-loser") '()))))))

  (test-case "different IDs at one expected version produce one sale and one conflict"
    (call-with-two-connections
     (lambda (database-path connection-A connection-B)
       (define setup-service
         (make-service connection-A quiet-catalog))
       (start-transaction! setup-service "txn-version-race" "cmd-race-start")

       (define lookup-count 0)
       (define lookup-lock (make-semaphore 1))
       (define (counting-catalog barcode)
         (call-with-semaphore
          lookup-lock
          (lambda () (set! lookup-count (add1 lookup-count))))
         (fake-catalog-lookup barcode))
       (define command-A
         (scan-barcode-command
          "cmd-race-A" "txn-version-race" 1 test-barcode))
       (define command-B
         (scan-barcode-command
          "cmd-race-B" "txn-version-race" 1 test-barcode))

       (define conflict-receipt #f)

       (call-with-controlled-race
        connection-A
        connection-B
        counting-catalog
        counting-catalog
        command-A
        command-B
        (lambda (_service-A service-B plans result-A result-B)
          (for ([label (in-list '(A B))])
            (define plan (hash-ref plans label))
            (check-equal?
             (transaction-command-commit-plan-decision-stream-version plan)
             1)
            (check-equal?
             (transaction-command-commit-plan-outcome-kind plan)
             'accepted))
          (define receipt-A (resolved-receipt result-A))
          (define receipt-B (resolved-receipt result-B))
          (set! conflict-receipt receipt-B)
          (check-equal?
           receipt-A
           (transaction-command-receipt
            command-A 'accepted "accepted" 2))
          (check-equal?
           receipt-B
           (transaction-command-receipt
            command-B
            'version-conflict
            "stream_version_conflict"
            2))
          (check-equal? lookup-count 2)
          (check-equal? (receipt-count connection-A "cmd-race-A") 1)
          (check-equal? (receipt-count connection-A "cmd-race-B") 1)
          (check-equal?
           (loaded-events connection-A "txn-version-race")
           (list (transaction-started "txn-version-race")
                 test-sale-item-event))

          (define lookups-before-retry lookup-count)
          (check-equal?
           (resolved-receipt
            (transaction-service-execute-command service-B command-B))
           receipt-B)
          (check-equal? lookup-count lookups-before-retry)))

       ;; A fresh connection proves that the losing command's conflict is a
       ;; durable original outcome, not merely an in-memory race result.
       (call-with-connection
        database-path
        'read/write
        (lambda (verification-connection)
          (migrate-pos-database! verification-connection)
          (check-equal?
           (loaded-receipt verification-connection "cmd-race-B")
           conflict-receipt)
          (check-equal?
           (loaded-events verification-connection "txn-version-race")
           (list (transaction-started "txn-version-race")
                 test-sale-item-event))
          (define retry-service
            (make-service verification-connection quiet-catalog))
          (check-equal?
           (resolved-receipt
            (transaction-service-execute-command
             retry-service command-B))
           conflict-receipt))))))

  (test-case "obsolete domain rejection becomes a final stream conflict"
    (call-with-two-connections
     (lambda (_database-path connection-A connection-B)
       (define setup-service
         (make-service connection-A quiet-catalog))
       (start-transaction! setup-service "txn-rejection-race" "cmd-reject-start")

       (define command-A
         (scan-barcode-command
          "cmd-reject-winner" "txn-rejection-race" 1 test-barcode))
       (define command-B
         (tender-cash-command
          "cmd-reject-loser" "txn-rejection-race" 1 (money 500)))

       (call-with-controlled-race
        connection-A
        connection-B
        fake-catalog-lookup
        quiet-catalog
        command-A
        command-B
        (lambda (_service-A _service-B plans result-A result-B)
          (check-equal?
           (transaction-command-commit-plan-outcome-kind
            (hash-ref plans 'A))
           'accepted)
          (check-equal?
           (transaction-command-commit-plan-outcome-kind
            (hash-ref plans 'B))
           'domain-rejected)
          (check-equal?
           (transaction-command-commit-plan-outcome-code
            (hash-ref plans 'B))
           "empty_transaction")
          (check-equal?
           (resolved-receipt result-A)
           (transaction-command-receipt
            command-A 'accepted "accepted" 2))
          (check-equal?
           (resolved-receipt result-B)
           (transaction-command-receipt
            command-B
            'version-conflict
            "stream_version_conflict"
            2))
          (check-equal?
           (loaded-events connection-A "txn-rejection-race")
           (list (transaction-started "txn-rejection-race")
                 test-sale-item-event))
          (check-equal? (receipt-count connection-A "cmd-reject-loser") 1))))))

  (test-case "SQLite writer contention cannot produce false durable success"
    (call-with-two-connections
     (lambda (_database-path connection-A connection-B)
       ;; Fail immediately instead of waiting for the test-held writer. The
       ;; exact SQLite error text is deliberately not part of the assertion.
       (db:query-exec connection-B "PRAGMA busy_timeout = 0")
       (define lock-acquired (make-channel))
       (define release-lock (make-semaphore 0))
       (define lock-result (make-channel))
       (define lock-released? #f)
       (define lock-thread
         (thread
          (lambda ()
            (with-handlers ([exn?
                             (lambda (exception)
                               (channel-put
                                lock-result
                                (cons 'exception exception)))])
              (db:call-with-transaction
               connection-A
               (lambda ()
                 (channel-put lock-acquired 'held)
                 (semaphore-wait release-lock))
               #:option 'immediate)
              (channel-put lock-result (cons 'result 'released))))))

       (define (release-writer!)
         (unless lock-released?
           (set! lock-released? #t)
           (semaphore-post release-lock)))

       (dynamic-wind
         void
         (lambda ()
           (check-equal?
            (receive-with-timeout lock-acquired "SQLite writer reservation")
            'held)
           (define command
             (start-transaction-command
              "cmd-busy" "txn-busy" 0))
           (define service
             (make-service connection-B quiet-catalog))

           (check-exn
            db:exn:fail:sql?
            (lambda ()
              (transaction-service-execute-command service command)))
           (check-pred
            receipt-load-not-found?
            (load-transaction-command-receipt connection-B "cmd-busy"))
           (check-equal? (loaded-events connection-B "txn-busy") '())

           (release-writer!)
           (define released
             (receive-with-timeout lock-result "SQLite writer release"))
           (when (eq? (car released) 'exception)
             (raise (cdr released)))
           (check-equal? released (cons 'result 'released))
           (thread-wait lock-thread)

           ;; No receipt was frozen for the infrastructure failure, so the
           ;; exact same command ID can execute once the writer is available.
           (check-equal?
            (resolved-receipt
             (transaction-service-execute-command service command))
            (transaction-command-receipt
             command 'accepted "accepted" 1))
           (check-equal?
            (loaded-events connection-B "txn-busy")
            (list (transaction-started "txn-busy")))
           (check-equal? (receipt-count connection-B "cmd-busy") 1))
         (lambda ()
           (release-writer!)
           (unless (thread-dead? lock-thread)
             (sync/timeout 10 lock-thread)))))))
)
