#lang racket

(require (prefix-in db: db)
         racket/file
         rackunit
         "../pos/application/transaction-command-receipt.rkt"
         "../pos/application/transaction-command.rkt"
         "../pos/application/transaction-service.rkt"
         "../pos/domain/fake-catalog.rkt"
         "../pos/domain/money.rkt"
         "../pos/domain/transaction-event.rkt"
         "../pos/domain/transaction.rkt"
         "../pos/persistence/sqlite-transaction-event-store.rkt"
         "../pos/persistence/transaction-command-receipt-store.rkt"
         "../pos/persistence/transaction-command-unit-of-work.rkt"
         "../pos/persistence/transaction-journal-migrations.rkt")

(define test-barcode "049000001234")
(define unknown-barcode "000000000000")

(define (call-with-connection database-path mode procedure)
  (define connection
    (db:sqlite3-connect #:database database-path #:mode mode))
  (dynamic-wind
    void
    (lambda () (procedure connection))
    (lambda () (db:disconnect connection))))

(define (resolved-receipt result)
  (check-pred transaction-service-command-resolved? result)
  (transaction-service-command-resolved-receipt result))

(define (successful-transaction result expected-version)
  (check-pred transaction-service-success? result)
  (check-equal? (transaction-service-success-version result)
                expected-version)
  (transaction-service-success-transaction result))

(define (journal-events connection transaction-id)
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

(module+ test
  (test-case "same command retry after restart returns original durable outcome"
    (define database-path
      (make-temporary-file "grocery-pos-idempotent-service-~a.sqlite"))
    (define start-command
      (start-transaction-command "cmd-start" "txn-001" 0))
    (define scan-command
      (scan-barcode-command "cmd-scan" "txn-001" 1 test-barcode))
    (define tender-command
      (tender-cash-command "cmd-tender" "txn-001" 2 (money 500)))
    (define completion-command
      (complete-transaction-command "cmd-complete" "txn-001" 3))
    (define scan-receipt #f)
    (define catalog-lookups 0)

    (dynamic-wind
      void
      (lambda ()
        ;; Connection A commits the original start and scan.
        (call-with-connection
         database-path
         'create
         (lambda (connection-A)
           (migrate-transaction-journal! connection-A)
           (define service-A
             (make-transaction-service
              connection-A
              #:catalog-lookup
              (lambda (barcode)
                (set! catalog-lookups (add1 catalog-lookups))
                (fake-catalog-lookup barcode))))
           (define start-receipt
             (resolved-receipt
              (transaction-service-execute-command service-A start-command)))
           (set! scan-receipt
                 (resolved-receipt
                  (transaction-service-execute-command
                   service-A scan-command)))
           (check-equal?
            (transaction-command-receipt-outcome-stream-version start-receipt)
            1)
           (check-equal?
            (transaction-command-receipt-outcome-stream-version scan-receipt)
            2)
           (check-equal? catalog-lookups 1)))

        ;; Connection B proves the retry is resolved from its receipt before
        ;; catalog or transaction recovery, then tenders the current stream.
        (call-with-connection
         database-path
         'read/write
         (lambda (connection-B)
           (migrate-transaction-journal! connection-B)
           (define service-B
             (make-transaction-service
              connection-B
              #:catalog-lookup
              (lambda (_barcode)
                (set! catalog-lookups (add1 catalog-lookups))
                (error 'test "restart retry repeated catalog lookup"))))
           (define retried
             (resolved-receipt
              (transaction-service-execute-command service-B scan-command)))
           (check-equal? retried scan-receipt)
           (check-equal? catalog-lookups 1)
           (check-equal?
            (resolved-receipt
             (transaction-service-execute-command service-B tender-command))
            (transaction-command-receipt
             tender-command 'accepted "accepted" 3))))

        ;; Connection C recovers the paid state and completes it.
        (call-with-connection
         database-path
         'read/write
         (lambda (connection-C)
           (migrate-transaction-journal! connection-C)
           (define service-C
             (make-transaction-service
              connection-C
              #:catalog-lookup
              (lambda (_barcode)
                (error 'test "recovery consulted catalog"))))
           (define paid
             (successful-transaction
              (transaction-service-load-transaction service-C "txn-001")
              3))
           (check-equal? (transaction-status paid) 'paid)
           (check-equal? (transaction-tendered-cash paid) (money 500))
           (check-equal? (transaction-change-due paid) (money 301))
           (check-equal?
            (resolved-receipt
             (transaction-service-execute-command
              service-C completion-command))
            (transaction-command-receipt
             completion-command 'accepted "accepted" 4))))

        ;; Connection D proves final state and exact history are durable.
        (call-with-connection
         database-path
         'read/write
         (lambda (connection-D)
           (migrate-transaction-journal! connection-D)
           (define service-D
             (make-transaction-service
              connection-D
              #:catalog-lookup
              (lambda (_barcode)
                (error 'test "final recovery consulted catalog"))))
           (define recovered
             (successful-transaction
              (transaction-service-load-transaction service-D "txn-001")
              4))
           (check-equal? (transaction-status recovered) 'completed)
           (check-equal? (transaction-subtotal recovered) (money 199))
           (check-equal? (transaction-total recovered) (money 199))
           (check-equal? (transaction-tendered-cash recovered) (money 500))
           (check-equal? (transaction-change-due recovered) (money 301))

           (define loaded
             (load-transaction-events connection-D "txn-001"))
           (check-equal?
            (journal-load-succeeded-events loaded)
            (list (transaction-started "txn-001")
                  (sale-item-added
                   test-barcode "Test Apples" (money 199))
                  (cash-tendered (money 500))
                  (transaction-completed)))
           (define loaded-receipt
             (load-transaction-command-receipt connection-D "cmd-scan"))
           (check-pred receipt-load-found? loaded-receipt)
           (check-equal? (receipt-load-found-receipt loaded-receipt)
                         scan-receipt))))
      (lambda ()
        (when (file-exists? database-path)
          (delete-file database-path)))))

  (test-case "post-commit caller exception is resolved by same-ID retry"
    (define database-path
      (make-temporary-file "grocery-pos-post-commit-local-~a.sqlite"))
    (define scan-command
      (scan-barcode-command
       "cmd-post-commit" "txn-post-commit" 1 test-barcode))
    (define catalog-lookups 0)
    (dynamic-wind
      void
      (lambda ()
        (call-with-connection
         database-path
         'create
         (lambda (connection)
           (migrate-transaction-journal! connection)
           (define setup-service
             (make-transaction-service
              connection
              #:catalog-lookup fake-catalog-lookup))
           (resolved-receipt
            (transaction-service-execute-command
             setup-service
             (start-transaction-command
              "cmd-post-commit-start" "txn-post-commit" 0)))

           (define uncertain-service
             (make-transaction-service
              connection
              #:catalog-lookup
              (lambda (barcode)
                (set! catalog-lookups (add1 catalog-lookups))
                (fake-catalog-lookup barcode))
              #:commit-command!
              (lambda (connection* plan)
                (commit-transaction-command-outcome! connection* plan)
                (error
                 'simulated-post-commit-response-loss
                 "caller did not observe the durable result"))))

           (check-exn
            #rx"caller did not observe the durable result"
            (lambda ()
              (transaction-service-execute-command
               uncertain-service scan-command)))

           ;; The exception was raised only after the real unit of work
           ;; returned, so both durable halves must already exist.
           (check-equal?
            (journal-events connection "txn-post-commit")
            (list (transaction-started "txn-post-commit")
                  (sale-item-added
                   test-barcode "Test Apples" (money 199))))
           (check-equal? (receipt-count connection "cmd-post-commit") 1)
           (define stored
             (load-transaction-command-receipt
              connection "cmd-post-commit"))
           (check-pred receipt-load-found? stored)

           (define retry-service
             (make-transaction-service
              connection
              #:catalog-lookup
              (lambda (_barcode)
                (set! catalog-lookups (add1 catalog-lookups))
                (error 'test "post-commit retry consulted catalog"))))
           (check-equal?
            (resolved-receipt
             (transaction-service-execute-command
              retry-service scan-command))
            (receipt-load-found-receipt stored))
           (check-equal? catalog-lookups 1)
           (check-equal? (receipt-count connection "cmd-post-commit") 1)
           (check-equal?
            (length (journal-events connection "txn-post-commit"))
            2))))
      (lambda ()
        (when (file-exists? database-path)
          (delete-file database-path)))))

  (test-case "post-commit uncertainty resolves after connection restart"
    (define database-path
      (make-temporary-file "grocery-pos-post-commit-restart-~a.sqlite"))
    (define scan-command
      (scan-barcode-command
       "cmd-lost-response" "txn-lost-response" 1 test-barcode))
    (define original-receipt #f)
    (define catalog-lookups 0)
    (dynamic-wind
      void
      (lambda ()
        ;; Connection A durably commits C1, then simulates losing the result.
        (call-with-connection
         database-path
         'create
         (lambda (connection-A)
           (migrate-transaction-journal! connection-A)
           (define setup-service
             (make-transaction-service
              connection-A
              #:catalog-lookup fake-catalog-lookup))
           (resolved-receipt
            (transaction-service-execute-command
             setup-service
             (start-transaction-command
              "cmd-lost-start" "txn-lost-response" 0)))
           (define uncertain-service
             (make-transaction-service
              connection-A
              #:catalog-lookup
              (lambda (barcode)
                (set! catalog-lookups (add1 catalog-lookups))
                (fake-catalog-lookup barcode))
              #:commit-command!
              (lambda (connection* plan)
                (define result
                  (commit-transaction-command-outcome!
                   connection* plan))
                (set!
                 original-receipt
                 (transaction-command-commit-resolved-receipt result))
                (error
                 'simulated-post-commit-response-loss
                 "response was lost after commit"))))
           (check-exn
            #rx"response was lost after commit"
            (lambda ()
              (transaction-service-execute-command
               uncertain-service scan-command)))
           (check-equal? catalog-lookups 1)))

        ;; Connection B has no in-memory outcome. The durable receipt alone
        ;; resolves the retry before catalog or transaction recovery.
        (call-with-connection
         database-path
         'read/write
         (lambda (connection-B)
           (migrate-transaction-journal! connection-B)
           (define retry-service
             (make-transaction-service
              connection-B
              #:catalog-lookup
              (lambda (_barcode)
                (set! catalog-lookups (add1 catalog-lookups))
                (error 'test "restart retry consulted catalog"))))
           (check-equal?
            (resolved-receipt
             (transaction-service-execute-command
              retry-service scan-command))
            original-receipt)
           (check-equal? catalog-lookups 1)
           (check-equal? (receipt-count connection-B "cmd-lost-response") 1)
           (check-equal?
            (journal-events connection-B "txn-lost-response")
            (list (transaction-started "txn-lost-response")
                  (sale-item-added
                   test-barcode "Test Apples" (money 199)))))))
      (lambda ()
        (when (file-exists? database-path)
          (delete-file database-path)))))

  (test-case "failure before atomic commit leaves same ID retryable"
    (define database-path
      (make-temporary-file "grocery-pos-pre-commit-failure-~a.sqlite"))
    (define scan-command
      (scan-barcode-command
       "cmd-pre-commit" "txn-pre-commit" 1 test-barcode))
    (define catalog-lookups 0)
    (dynamic-wind
      void
      (lambda ()
        (call-with-connection
         database-path
         'create
         (lambda (connection)
           (migrate-transaction-journal! connection)
           (define setup-service
             (make-transaction-service
              connection
              #:catalog-lookup fake-catalog-lookup))
           (resolved-receipt
            (transaction-service-execute-command
             setup-service
             (start-transaction-command
              "cmd-pre-commit-start" "txn-pre-commit" 0)))
           (define (counting-catalog barcode)
             (set! catalog-lookups (add1 catalog-lookups))
             (fake-catalog-lookup barcode))
           (define failing-service
             (make-transaction-service
              connection
              #:catalog-lookup counting-catalog
              #:commit-command!
              (lambda (_connection _plan)
                (error
                 'simulated-pre-commit-failure
                 "unit of work was not invoked"))))

           (check-exn
            #rx"unit of work was not invoked"
            (lambda ()
              (transaction-service-execute-command
               failing-service scan-command)))
           (check-pred
            receipt-load-not-found?
            (load-transaction-command-receipt
             connection "cmd-pre-commit"))
           (check-equal?
            (journal-events connection "txn-pre-commit")
            (list (transaction-started "txn-pre-commit")))

           (define retry-service
             (make-transaction-service
              connection
              #:catalog-lookup counting-catalog))
           (check-equal?
            (resolved-receipt
             (transaction-service-execute-command
              retry-service scan-command))
            (transaction-command-receipt
             scan-command 'accepted "accepted" 2))
           (check-equal? catalog-lookups 2)
           (check-equal? (receipt-count connection "cmd-pre-commit") 1)
           (check-equal?
            (journal-events connection "txn-pre-commit")
            (list (transaction-started "txn-pre-commit")
                  (sale-item-added
                   test-barcode "Test Apples" (money 199)))))))
      (lambda ()
        (when (file-exists? database-path)
          (delete-file database-path)))))

  (test-case "domain rejection retry after restart uses its durable receipt"
    (define database-path
      (make-temporary-file "grocery-pos-rejection-restart-~a.sqlite"))
    (define rejected-command
      (scan-barcode-command
       "cmd-rejected-restart"
       "txn-rejected-restart"
       1
       unknown-barcode))
    (define original-receipt #f)
    (define catalog-lookups 0)
    (dynamic-wind
      void
      (lambda ()
        (call-with-connection
         database-path
         'create
         (lambda (connection-A)
           (migrate-transaction-journal! connection-A)
           (define service-A
             (make-transaction-service
              connection-A
              #:catalog-lookup
              (lambda (barcode)
                (set! catalog-lookups (add1 catalog-lookups))
                (fake-catalog-lookup barcode))))
           (resolved-receipt
            (transaction-service-execute-command
             service-A
             (start-transaction-command
              "cmd-rejected-restart-start"
              "txn-rejected-restart"
              0)))
           (set!
            original-receipt
            (resolved-receipt
             (transaction-service-execute-command
              service-A rejected-command)))
           (check-equal?
            original-receipt
            (transaction-command-receipt
             rejected-command
             'domain-rejected
             "unknown_barcode"
             1))
           (check-equal? catalog-lookups 1)))

        (call-with-connection
         database-path
         'read/write
         (lambda (connection-B)
           (migrate-transaction-journal! connection-B)
           (define service-B
             (make-transaction-service
              connection-B
              #:catalog-lookup
              (lambda (_barcode)
                (set! catalog-lookups (add1 catalog-lookups))
                (error 'test "rejected restart retry consulted catalog"))))
           (check-equal?
            (resolved-receipt
             (transaction-service-execute-command
              service-B rejected-command))
            original-receipt)
           (check-equal? catalog-lookups 1)
           (check-equal?
            (journal-events connection-B "txn-rejected-restart")
            (list (transaction-started "txn-rejected-restart")))
           (check-equal?
            (receipt-count connection-B "cmd-rejected-restart")
            1))))
      (lambda ()
        (when (file-exists? database-path)
          (delete-file database-path)))))
)
