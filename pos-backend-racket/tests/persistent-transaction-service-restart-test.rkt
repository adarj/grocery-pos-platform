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
         "../pos/persistence/transaction-journal-migrations.rkt")

(define test-barcode "049000001234")

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
          (delete-file database-path))))))
