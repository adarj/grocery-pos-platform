#lang racket

(require (prefix-in db: db)
         rackunit
         "../pos/domain/money.rkt"
         "../pos/domain/transaction-event.rkt"
         "../pos/persistence/sqlite-transaction-event-store.rkt"
         "../pos/persistence/transaction-journal-migrations.rkt")

(define started
  (transaction-started "txn-001"))
(define item-added
  (sale-item-added "049000001234" "Test Apples" (money 199)))
(define tendered
  (cash-tendered (money 500)))
(define completed
  (transaction-completed))

(define (call-with-store procedure)
  (define connection
    (db:sqlite3-connect #:database 'memory))
  (dynamic-wind
    void
    (lambda ()
      (migrate-transaction-journal! connection)
      (procedure connection))
    (lambda () (db:disconnect connection))))

(define (append-in-caller-transaction connection
                                      transaction-id
                                      expected-version
                                      prepared)
  (db:call-with-transaction
   connection
   (lambda ()
     (append-prepared-transaction-events/in-transaction!
      connection transaction-id expected-version prepared))
   #:option 'immediate))

(module+ test
  (test-case "preparation produces only non-empty opaque event batches"
    (check-pred
     prepared-transaction-event-batch?
     (prepare-transaction-events (list started item-added)))
    (check-exn exn:fail:contract?
               (lambda () (prepare-transaction-events '())))
    (check-exn exn:fail:contract?
               (lambda ()
                 (prepare-transaction-events (list started 'not-an-event)))))

  (test-case "transaction-scoped append rejects use without caller transaction"
    (call-with-store
     (lambda (connection)
       (define prepared
         (prepare-transaction-events (list started)))
       (check-exn
        exn:fail:contract?
        (lambda ()
          (append-prepared-transaction-events/in-transaction!
           connection "txn-001" 0 prepared)))
       (check-equal?
        (db:query-value connection "SELECT COUNT(*) FROM transaction_events")
        0))))

  (test-case "transaction-scoped version reads require and observe caller transaction"
    (call-with-store
     (lambda (connection)
       (check-exn
        exn:fail:contract?
        (lambda ()
          (transaction-stream-version/in-transaction
           connection "txn-001")))

       (db:call-with-transaction
        connection
        (lambda ()
          (define version-before
            (transaction-stream-version/in-transaction
             connection "txn-001"))
          (define appended
            (append-prepared-transaction-events/in-transaction!
             connection
             "txn-001"
             0
             (prepare-transaction-events (list started))))
          (define version-after
            (transaction-stream-version/in-transaction
             connection "txn-001"))
          (check-equal? version-before 0)
          (check-pred journal-append-succeeded? appended)
          (check-equal? version-after 1))
        #:option 'immediate))))

  (test-case "transaction-scoped append remains subject to caller rollback"
    (call-with-store
     (lambda (connection)
       (define append-returned? #f)
       (check-exn
        exn:fail?
        (lambda ()
          (db:call-with-transaction
           connection
           (lambda ()
             (define result
               (append-prepared-transaction-events/in-transaction!
                connection
                "txn-001"
                0
                (prepare-transaction-events (list started))))
             (check-pred journal-append-succeeded? result)
             (set! append-returned? #t)
             (error 'test "force caller rollback"))
           #:option 'immediate)))
       (check-true append-returned?)
       (define loaded
         (load-transaction-events connection "txn-001"))
       (check-equal? (journal-load-succeeded-version loaded) 0)
       (check-equal? (journal-load-succeeded-events loaded) '()))))

  (test-case "transaction-scoped append persists when caller commits"
    (call-with-store
     (lambda (connection)
       (define result
         (append-in-caller-transaction
          connection
          "txn-001"
          0
          (prepare-transaction-events (list started))))
       (check-pred journal-append-succeeded? result)
       (check-equal? (journal-append-succeeded-new-version result) 1)

       (define loaded
         (load-transaction-events connection "txn-001"))
       (check-equal? (journal-load-succeeded-version loaded) 1)
       (check-equal? (journal-load-succeeded-events loaded)
                     (list started)))))

  (test-case "transaction-scoped version conflict writes no event"
    (call-with-store
     (lambda (connection)
       (append-transaction-events! connection "txn-001" 0 (list started))
       (define result
         (append-in-caller-transaction
          connection
          "txn-001"
          0
          (prepare-transaction-events (list item-added))))

       (check-pred journal-append-rejected? result)
       (check-equal? (journal-append-rejected-code result)
                     'stream-version-conflict)
       (check-equal? (journal-append-rejected-actual-version result) 1)
       (define loaded
         (load-transaction-events connection "txn-001"))
       (check-equal? (journal-load-succeeded-version loaded) 1)
       (check-equal? (journal-load-succeeded-events loaded)
                     (list started)))))

  (test-case "transaction-scoped identity rejections write no event"
    (call-with-store
     (lambda (connection)
       (define mismatched-start
         (append-in-caller-transaction
          connection
          "txn-A"
          0
          (prepare-transaction-events
           (list (transaction-started "txn-B")))))
       (check-equal? (journal-append-rejected-code mismatched-start)
                     'stream-identity-mismatch)

       (define missing-start
         (append-in-caller-transaction
          connection
          "txn-A"
          0
          (prepare-transaction-events (list item-added))))
       (check-equal? (journal-append-rejected-code missing-start)
                     'first-event-not-transaction-started)
       (check-equal?
        (db:query-value connection "SELECT COUNT(*) FROM transaction_events")
        0)

       (append-transaction-events!
        connection "txn-A" 0 (list (transaction-started "txn-A")))
       (define duplicate-start
         (append-in-caller-transaction
          connection
          "txn-A"
          1
          (prepare-transaction-events
           (list (transaction-started "txn-A")))))
       (check-equal? (journal-append-rejected-code duplicate-start)
                     'transaction-already-started)
       (check-equal?
        (db:query-value connection "SELECT COUNT(*) FROM transaction_events")
        1))))

  (test-case "transaction-scoped multi-event append allocates one sequence"
    (call-with-store
     (lambda (connection)
       (define events (list started item-added tendered completed))
       (define result
         (append-in-caller-transaction
          connection
          "txn-001"
          0
          (prepare-transaction-events events)))

       (check-pred journal-append-succeeded? result)
       (check-equal? (journal-append-succeeded-new-version result) 4)
       (check-equal?
        (db:query-list
         connection
         #<<SQL
SELECT stream_sequence
FROM transaction_events
WHERE transaction_id = 'txn-001'
ORDER BY stream_sequence ASC
SQL
         )
        '(1 2 3 4))
       (define loaded
         (load-transaction-events connection "txn-001"))
       (check-equal? (journal-load-succeeded-events loaded) events)))))
