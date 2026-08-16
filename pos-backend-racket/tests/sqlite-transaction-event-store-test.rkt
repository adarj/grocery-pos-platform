#lang racket

(require db
         rackunit
         "../pos/domain/money.rkt"
         "../pos/domain/transaction-event.rkt"
         "../pos/persistence/sqlite-transaction-event-store.rkt"
         "../pos/persistence/transaction-event-codec.rkt"
         "../pos/persistence/transaction-journal-migrations.rkt")

(define started
  (transaction-started "txn-001"))

(define item-added
  (sale-item-added "049000001234"
                   "Test Apples"
                   (money 199)))

(define tendered
  (cash-tendered (money 500)))

(define completed
  (transaction-completed))

(define (call-with-store procedure)
  (define connection
    (sqlite3-connect #:database 'memory))
  (dynamic-wind
    void
    (lambda ()
      (migrate-transaction-journal! connection)
      (procedure connection))
    (lambda () (disconnect connection))))

(define insert-event-sql
  #<<SQL
INSERT INTO transaction_events
  (transaction_id, stream_sequence, schema_version, event_type, event_json)
VALUES (?, ?, ?, ?, ?)
SQL
  )

(define (insert-event-directly! connection transaction-id sequence event)
  (define representation (transaction-event->jsexpr event))
  (query-exec connection
              insert-event-sql
              transaction-id
              sequence
              (hash-ref representation 'schema_version)
              (hash-ref representation 'event_type)
              (transaction-event->json-string event)))

(define (check-append-rejection result expected-code)
  (check-pred journal-append-rejected? result)
  (check-equal? (journal-append-rejected-code result) expected-code))

(module+ test
  (test-case "new stream append persists the Schema v1 event envelope"
    (call-with-store
     (lambda (connection)
       (define result
         (append-transaction-events! connection "txn-001" 0 (list started)))

       (check-pred journal-append-succeeded? result)
       (check-equal? (journal-append-succeeded-new-version result) 1)

       (define row
         (query-row
          connection
          #<<SQL
SELECT transaction_id,
       stream_sequence,
       schema_version,
       event_type,
       event_json
FROM transaction_events
SQL
          ))
       (check-equal? (vector-ref row 0) "txn-001")
       (check-equal? (vector-ref row 1) 1)
       (check-equal? (vector-ref row 2) 1)
       (check-equal? (vector-ref row 3) "transaction_started")

       (define decoded
         (json-string->transaction-event (vector-ref row 4)))
       (check-pred event-decode-success? decoded)
       (check-equal? (event-decode-success-event decoded) started))))

  (test-case "ordered multi-event append and load preserve stream order"
    (call-with-store
     (lambda (connection)
       (append-transaction-events! connection "txn-001" 0 (list started))
       (define append-result
         (append-transaction-events!
          connection
          "txn-001"
          1
          (list item-added tendered completed)))

       (check-pred journal-append-succeeded? append-result)
       (check-equal? (journal-append-succeeded-new-version append-result) 4)
       (check-equal?
        (query-list
         connection
         #<<SQL
SELECT stream_sequence
FROM transaction_events
WHERE transaction_id = 'txn-001'
ORDER BY stream_sequence ASC
SQL
         )
        '(1 2 3 4))

       (define load-result
         (load-transaction-events connection "txn-001"))
       (check-pred journal-load-succeeded? load-result)
       (check-equal? (journal-load-succeeded-version load-result) 4)
       (check-equal? (journal-load-succeeded-events load-result)
                     (list started item-added tendered completed)))))

  (test-case "a missing stream loads as empty version zero"
    (call-with-store
     (lambda (connection)
       (define result
         (load-transaction-events connection "txn-missing"))

       (check-pred journal-load-succeeded? result)
       (check-equal? (journal-load-succeeded-version result) 0)
       (check-equal? (journal-load-succeeded-events result) '()))))

  (test-case "stale expected version rejects the whole append"
    (call-with-store
     (lambda (connection)
       (append-transaction-events! connection "txn-001" 0 (list started))
       (append-transaction-events! connection "txn-001" 1 (list item-added))

       (define result
         (append-transaction-events! connection "txn-001" 1 (list tendered)))

       (check-append-rejection result 'stream-version-conflict)
       (check-equal? (journal-append-rejected-actual-version result) 2)
       (define loaded
         (load-transaction-events connection "txn-001"))
       (check-equal? (journal-load-succeeded-version loaded) 2)
       (check-equal? (journal-load-succeeded-events loaded)
                     (list started item-added)))))

  (test-case "empty append is rejected instead of succeeding as a no-op"
    (call-with-store
     (lambda (connection)
       (define result
         (append-transaction-events! connection "txn-001" 0 '()))

       (check-append-rejection result 'empty-event-list)
       (check-equal?
        (query-value connection "SELECT COUNT(*) FROM transaction_events")
        0))))

  (test-case "stream identity rules reject invalid transaction starts"
    (call-with-store
     (lambda (connection)
       (check-append-rejection
        (append-transaction-events!
         connection
         "txn-A"
         0
         (list (transaction-started "txn-B")))
        'stream-identity-mismatch)
       (check-append-rejection
        (append-transaction-events! connection "txn-A" 0 (list item-added))
        'first-event-not-transaction-started)

       (append-transaction-events!
        connection
        "txn-A"
        0
        (list (transaction-started "txn-A")))
       (check-append-rejection
        (append-transaction-events!
         connection
         "txn-A"
         1
         (list (transaction-started "txn-A")))
        'transaction-already-started)

       (check-equal?
        (query-value connection "SELECT COUNT(*) FROM transaction_events")
        1))))

  (test-case "a failing later insert rolls back the complete batch"
    (call-with-store
     (lambda (connection)
       (append-transaction-events! connection "txn-001" 0 (list started))
       (query-exec
        connection
        #<<SQL
CREATE TRIGGER reject_test_cash_event
BEFORE INSERT ON transaction_events
WHEN NEW.event_type = 'cash_tendered'
BEGIN
  SELECT RAISE(ABORT, 'deterministic test insertion failure');
END
SQL
        )

       (check-exn
        exn:fail:sql?
        (lambda ()
          (append-transaction-events!
           connection
           "txn-001"
           1
           (list item-added tendered completed))))

       (define loaded
         (load-transaction-events connection "txn-001"))
       (check-pred journal-load-succeeded? loaded)
       (check-equal? (journal-load-succeeded-version loaded) 1)
       (check-equal? (journal-load-succeeded-events loaded) (list started)))))

  (test-case "malformed persisted JSON produces a stable load failure"
    (call-with-store
     (lambda (connection)
       (append-transaction-events! connection "txn-001" 0 (list started))
       (query-exec connection
                   insert-event-sql
                   "txn-001" 2 1 "sale_item_added" "{not-json")

       (define result
         (load-transaction-events connection "txn-001"))
       (check-pred journal-load-failed? result)
       (check-equal? (journal-load-failed-code result)
                     'event-decode-failure)
       (check-equal? (journal-load-failed-stream-sequence result) 2)
       (check-equal? (journal-load-failed-detail result) 'malformed-json))))

  (test-case "malformed journal envelope produces a stable load failure"
    (call-with-store
     (lambda (connection)
       ;; This test deliberately bypasses a CHECK constraint to model damaged
       ;; database content that could not enter through the append API.
       (query-exec connection "PRAGMA ignore_check_constraints = ON")
       (query-exec connection
                   insert-event-sql
                   "txn-001"
                   1
                   "not-an-integer"
                   "transaction_started"
                   (transaction-event->json-string started))

       (define result
         (load-transaction-events connection "txn-001"))
       (check-pred journal-load-failed? result)
       (check-equal? (journal-load-failed-code result) 'invalid-envelope)
       (check-equal? (journal-load-failed-stream-sequence result) 1))))

  (test-case "sequence gaps are rejected without a partial load"
    (call-with-store
     (lambda (connection)
       (append-transaction-events!
        connection
        "txn-001"
        0
        (list started item-added))
       (insert-event-directly! connection "txn-001" 4 completed)

       (define result
         (load-transaction-events connection "txn-001"))
       (check-pred journal-load-failed? result)
       (check-equal? (journal-load-failed-code result) 'sequence-corruption)
       (check-equal? (journal-load-failed-stream-sequence result) 4))))

  (test-case "envelope metadata must agree with encoded event metadata"
    (call-with-store
     (lambda (connection)
       (insert-event-directly! connection "txn-001" 1 started)
       (query-exec connection
                   "UPDATE transaction_events SET event_type = 'sale_item_added'")

       (define type-result
         (load-transaction-events connection "txn-001"))
       (check-pred journal-load-failed? type-result)
       (check-equal? (journal-load-failed-code type-result)
                     'event-type-mismatch)

       (query-exec connection
                   "UPDATE transaction_events SET event_type = 'transaction_started', schema_version = 2")
       (define version-result
         (load-transaction-events connection "txn-001"))
       (check-pred journal-load-failed? version-result)
       (check-equal? (journal-load-failed-code version-result)
                     'schema-version-mismatch))))

  (test-case "corrupt first-event and stream identities are rejected"
    (call-with-store
     (lambda (connection)
       (insert-event-directly! connection "txn-A" 1 item-added)
       (define shape-result
         (load-transaction-events connection "txn-A"))
       (check-pred journal-load-failed? shape-result)
       (check-equal? (journal-load-failed-code shape-result)
                     'invalid-first-event)

       (query-exec connection "DELETE FROM transaction_events")
       (insert-event-directly!
        connection
        "txn-A"
        1
        (transaction-started "txn-B"))
       (define identity-result
         (load-transaction-events connection "txn-A"))
       (check-pred journal-load-failed? identity-result)
       (check-equal? (journal-load-failed-code identity-result)
                     'stream-identity-mismatch))))

  (test-case "interleaved rows remain isolated by transaction stream"
    (call-with-store
     (lambda (connection)
       (define started-A (transaction-started "txn-A"))
       (define started-B (transaction-started "txn-B"))
       (append-transaction-events! connection "txn-A" 0 (list started-A))
       (append-transaction-events! connection "txn-B" 0 (list started-B))
       (append-transaction-events! connection "txn-A" 1 (list item-added))
       (append-transaction-events!
        connection
        "txn-B"
        1
        (list (sale-item-added "000000000002" "Test Bananas" (money 250))))

       (define loaded-A
         (load-transaction-events connection "txn-A"))
       (check-pred journal-load-succeeded? loaded-A)
       (check-equal? (journal-load-succeeded-events loaded-A)
                     (list started-A item-added))))))
