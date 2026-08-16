#lang racket

(require (prefix-in db: db)
         rackunit
         "../pos/application/transaction-service.rkt"
         "../pos/domain/catalog-item.rkt"
         "../pos/domain/fake-catalog.rkt"
         "../pos/domain/money.rkt"
         "../pos/domain/transaction-event.rkt"
         "../pos/domain/transaction.rkt"
         "../pos/persistence/sqlite-transaction-event-store.rkt"
         "../pos/persistence/transaction-event-codec.rkt"
         "../pos/persistence/transaction-journal-migrations.rkt")

(define test-barcode "049000001234")

(define (call-with-service procedure)
  (define connection
    (db:sqlite3-connect #:database 'memory))
  (dynamic-wind
    void
    (lambda ()
      (migrate-transaction-journal! connection)
      (procedure connection (make-transaction-service connection)))
    (lambda () (db:disconnect connection))))

(define (check-success result expected-version)
  (check-pred transaction-service-success? result)
  (check-equal? (transaction-service-success-version result)
                expected-version)
  (transaction-service-success-transaction result))

(define (start-and-scan service transaction-id)
  (check-success
   (transaction-service-start-transaction service transaction-id)
   1)
  (check-success
   (transaction-service-scan-barcode
    service
    transaction-id
    test-barcode
    fake-catalog-lookup)
   2))

(module+ test
  (test-case "persistent start commits before returning success"
    (call-with-service
     (lambda (connection service)
       (define result
         (transaction-service-start-transaction service "txn-001"))
       (define started (check-success result 1))

       (check-equal? (transaction-id started) "txn-001")
       (check-equal? (transaction-status started) 'open)
       (check-equal? (transaction-line-items started) '())
       (check-equal? (transaction-subtotal started) (money 0))

       (define journal-result
         (load-transaction-events connection "txn-001"))
       (check-pred journal-load-succeeded? journal-result)
       (check-equal? (journal-load-succeeded-events journal-result)
                     (list (transaction-started "txn-001")))

       (define recovered-result
         (transaction-service-load-transaction service "txn-001"))
       (define recovered (check-success recovered-result 1))
       (check-equal? recovered started))))

  (test-case "duplicate start is a service-level already-exists result"
    (call-with-service
     (lambda (connection service)
       (transaction-service-start-transaction service "txn-duplicate")
       (define result
         (transaction-service-start-transaction service "txn-duplicate"))

       (check-pred transaction-service-already-exists? result)
       (check-equal?
        (transaction-service-already-exists-transaction-id result)
        "txn-duplicate")
       (check-equal? (transaction-service-already-exists-version result) 1)

       (define loaded
         (load-transaction-events connection "txn-duplicate"))
       (check-equal? (journal-load-succeeded-version loaded) 1)
       (check-equal? (length (journal-load-succeeded-events loaded)) 1))))

  (test-case "persistent scan snapshots one live lookup and recovery needs none"
    (call-with-service
     (lambda (_connection service)
       (transaction-service-start-transaction service "txn-scan")
       (define lookup-count 0)
       (define result
         (transaction-service-scan-barcode
          service
          "txn-scan"
          test-barcode
          (lambda (barcode)
            (set! lookup-count (add1 lookup-count))
            (fake-catalog-lookup barcode))))
       (define scanned (check-success result 2))

       (check-equal? lookup-count 1)
       (check-equal? (transaction-status scanned) 'open)
       (check-equal? (transaction-subtotal scanned) (money 199))
       (check-equal?
        (transaction-line-item-description
         (first (transaction-line-items scanned)))
        "Test Apples")

       ;; Recovery has no catalog dependency and cannot repeat the lookup.
       (define recovered-result
         (transaction-service-load-transaction service "txn-scan"))
       (define recovered (check-success recovered-result 2))
       (check-equal? recovered scanned)
       (check-equal? lookup-count 1))))

  (test-case "unknown barcode is a domain rejection and appends nothing"
    (call-with-service
     (lambda (connection service)
       (define started
         (check-success
          (transaction-service-start-transaction service "txn-unknown")
          1))
       (define result
         (transaction-service-scan-barcode
          service
          "txn-unknown"
          "000000000000"
          fake-catalog-lookup))

       (check-pred transaction-service-domain-rejected? result)
       (check-equal? (transaction-service-domain-rejected-code result)
                     'unknown-barcode)
       (check-equal? (transaction-service-domain-rejected-transaction result)
                     started)
       (check-equal? (transaction-service-domain-rejected-version result) 1)

       (define loaded
         (load-transaction-events connection "txn-unknown"))
       (check-equal? (journal-load-succeeded-version loaded) 1))))

  (test-case "sufficient cash is committed and recoverable"
    (call-with-service
     (lambda (_connection service)
       (start-and-scan service "txn-tender")
       (define result
         (transaction-service-tender-cash
          service
          "txn-tender"
          (money 500)))
       (define paid (check-success result 3))

       (check-equal? (transaction-status paid) 'paid)
       (check-equal? (transaction-tendered-cash paid) (money 500))
       (check-equal? (transaction-change-due paid) (money 301))

       (define recovered
         (check-success
          (transaction-service-load-transaction service "txn-tender")
          3))
       (check-equal? recovered paid))))

  (test-case "insufficient cash is a domain rejection and preserves version"
    (call-with-service
     (lambda (connection service)
       (define open (start-and-scan service "txn-insufficient"))
       (define result
         (transaction-service-tender-cash
          service
          "txn-insufficient"
          (money 198)))

       (check-pred transaction-service-domain-rejected? result)
       (check-equal? (transaction-service-domain-rejected-code result)
                     'insufficient-tender)
       (check-equal? (transaction-service-domain-rejected-transaction result)
                     open)
       (check-equal? (transaction-service-domain-rejected-version result) 2)

       (define loaded
         (load-transaction-events connection "txn-insufficient"))
       (check-equal? (journal-load-succeeded-version loaded) 2))))

  (test-case "paid completion is committed and recoverable"
    (call-with-service
     (lambda (_connection service)
       (start-and-scan service "txn-complete")
       (transaction-service-tender-cash
        service
        "txn-complete"
        (money 500))
       (define result
         (transaction-service-complete-transaction service "txn-complete"))
       (define completed (check-success result 4))

       (check-equal? (transaction-status completed) 'completed)
       (define recovered
         (check-success
          (transaction-service-load-transaction service "txn-complete")
          4))
       (check-equal? recovered completed))))

  (test-case "invalid completion is a domain rejection and writes nothing"
    (call-with-service
     (lambda (connection service)
       (define open (start-and-scan service "txn-invalid-complete"))
       (define result
         (transaction-service-complete-transaction
          service
          "txn-invalid-complete"))

       (check-pred transaction-service-domain-rejected? result)
       (check-equal? (transaction-service-domain-rejected-code result)
                     'invalid-transaction-state)
       (check-equal? (transaction-service-domain-rejected-transaction result)
                     open)
       (check-equal? (transaction-service-domain-rejected-version result) 2)

       (define loaded
         (load-transaction-events connection "txn-invalid-complete"))
       (check-equal? (journal-load-succeeded-version loaded) 2))))

  (test-case "commands do not implicitly create a missing transaction"
    (call-with-service
     (lambda (connection service)
       (define lookup-called? #f)
       (define scan-result
         (transaction-service-scan-barcode
          service
          "txn-missing"
          test-barcode
          (lambda (_barcode)
            (set! lookup-called? #t)
            (error 'test "missing transaction performed catalog lookup"))))
       (define tender-result
         (transaction-service-tender-cash
          service
          "txn-missing"
          (money 500)))
       (define completion-result
         (transaction-service-complete-transaction
          service
          "txn-missing"))
       (define load-result
         (transaction-service-load-transaction service "txn-missing"))

       (for ([result (in-list (list load-result
                                    scan-result
                                    tender-result
                                    completion-result))])
         (check-pred transaction-service-not-found? result)
         (check-equal? (transaction-service-not-found-transaction-id result)
                       "txn-missing"))
       (check-false lookup-called?)
       (check-equal?
        (db:query-value connection "SELECT COUNT(*) FROM transaction_events")
        0))))

  (test-case "journal corruption stops recovery before domain decision"
    (call-with-service
     (lambda (connection service)
       (transaction-service-start-transaction service "txn-corrupt")
       (db:query-exec
        connection
        #<<SQL
INSERT INTO transaction_events
  (transaction_id, stream_sequence, schema_version, event_type, event_json)
VALUES ('txn-corrupt', 2, 1, 'sale_item_added', '{not-json')
SQL
        )

       (define load-result
         (transaction-service-load-transaction service "txn-corrupt"))
       (check-pred transaction-service-recovery-failed? load-result)
       (check-equal? (transaction-service-recovery-failed-stage load-result)
                     'journal-load)
       (check-equal? (transaction-service-recovery-failed-code load-result)
                     'event-decode-failure)
       (check-equal? (transaction-service-recovery-failed-position load-result)
                     2)
       (check-equal? (transaction-service-recovery-failed-detail load-result)
                     'malformed-json)

       (define lookup-called? #f)
       (define command-result
         (transaction-service-scan-barcode
          service
          "txn-corrupt"
          test-barcode
          (lambda (_barcode)
            (set! lookup-called? #t)
            (error 'test "corrupt recovery performed catalog lookup"))))
       (check-pred transaction-service-recovery-failed? command-result)
       (check-false lookup-called?)
       (check-equal?
        (db:query-value connection "SELECT COUNT(*) FROM transaction_events")
        2))))

  (test-case "semantically invalid journal stops at replay recovery"
    (call-with-service
     (lambda (connection service)
       (append-transaction-events!
        connection
        "txn-invalid-replay"
        0
        (list (transaction-started "txn-invalid-replay")
              (transaction-completed)))

       (define result
         (transaction-service-load-transaction service "txn-invalid-replay"))
       (check-pred transaction-service-recovery-failed? result)
       (check-equal? (transaction-service-recovery-failed-stage result)
                     'replay)
       (check-equal? (transaction-service-recovery-failed-code result)
                     'invalid-transaction-state)
       (check-equal? (transaction-service-recovery-failed-position result) 1)

       (define lookup-called? #f)
       (define command-result
         (transaction-service-scan-barcode
          service
          "txn-invalid-replay"
          test-barcode
          (lambda (_barcode)
            (set! lookup-called? #t)
            (error 'test "invalid replay performed catalog lookup"))))
       (check-pred transaction-service-recovery-failed? command-result)
       (check-false lookup-called?)
       (check-equal?
        (db:query-value connection "SELECT COUNT(*) FROM transaction_events")
        2))))

  (test-case "stream conflict never reports provisional accepted state"
    (call-with-service
     (lambda (connection normal-service)
       (transaction-service-start-transaction normal-service "txn-conflict")
       (define append-call-count 0)
       (define requested-lookup-count 0)
       (define (conflicting-append connection* transaction-id version events)
         (set! append-call-count (add1 append-call-count))
         (append-transaction-events!
          connection*
          transaction-id
          version
          (list (sale-item-added "000000000002"
                                 "Concurrent Bananas"
                                 (money 250))))
         (append-transaction-events!
          connection*
          transaction-id
          version
          events))
       (define conflict-service
         (make-transaction-service
          connection
          #:append-events! conflicting-append))

       (define result
         (transaction-service-scan-barcode
          conflict-service
          "txn-conflict"
          test-barcode
          (lambda (barcode)
            (set! requested-lookup-count (add1 requested-lookup-count))
            (fake-catalog-lookup barcode))))

       (check-pred transaction-service-stream-conflict? result)
       (check-equal?
        (transaction-service-stream-conflict-transaction-id result)
        "txn-conflict")
       (check-equal?
        (transaction-service-stream-conflict-expected-version result)
        1)
       (check-equal?
        (transaction-service-stream-conflict-actual-version result)
        2)
       (check-false (transaction-service-success? result))
       (check-equal? append-call-count 1)
       (check-equal? requested-lookup-count 1)

       (define recovered
         (check-success
          (transaction-service-load-transaction normal-service "txn-conflict")
          2))
       (check-equal? (transaction-subtotal recovered) (money 250))
       (check-equal?
        (transaction-line-item-description
         (first (transaction-line-items recovered)))
        "Concurrent Bananas"))))

  (test-case "non-conflict append rejection is a persistence failure"
    (call-with-service
     (lambda (connection normal-service)
       (transaction-service-start-transaction normal-service "txn-append-fail")
       (define failure-service
         (make-transaction-service
          connection
          #:append-events!
          (lambda (connection* transaction-id version _events)
            (append-transaction-events!
             connection*
             transaction-id
             version
             '()))))

       (define result
         (transaction-service-scan-barcode
          failure-service
          "txn-append-fail"
          test-barcode
          fake-catalog-lookup))
       (check-pred transaction-service-persistence-failed? result)
       (check-equal? (transaction-service-persistence-failed-code result)
                     'empty-event-list)
       (check-false (transaction-service-success? result))

       (define recovered
         (check-success
          (transaction-service-load-transaction
           normal-service
           "txn-append-fail")
          1))
       (check-equal? (transaction-line-items recovered) '()))))

  (test-case "transactions remain isolated through the service"
    (call-with-service
     (lambda (_connection service)
       (transaction-service-start-transaction service "txn-A")
       (transaction-service-start-transaction service "txn-B")
       (transaction-service-scan-barcode
        service "txn-A" test-barcode fake-catalog-lookup)
       (transaction-service-scan-barcode
        service "txn-B" test-barcode fake-catalog-lookup)
       (transaction-service-scan-barcode
        service "txn-B" test-barcode fake-catalog-lookup)
       (transaction-service-tender-cash service "txn-A" (money 500))

       (define transaction-A
         (check-success
          (transaction-service-load-transaction service "txn-A")
          3))
       (define transaction-B
         (check-success
          (transaction-service-load-transaction service "txn-B")
          3))
       (check-equal? (transaction-status transaction-A) 'paid)
       (check-equal? (transaction-subtotal transaction-A) (money 199))
       (check-equal? (transaction-status transaction-B) 'open)
       (check-equal? (transaction-subtotal transaction-B) (money 398))))))
