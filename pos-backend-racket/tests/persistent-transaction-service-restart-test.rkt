#lang racket

(require (prefix-in db: db)
         racket/file
         rackunit
         "../pos/application/transaction-service.rkt"
         "../pos/domain/fake-catalog.rkt"
         "../pos/domain/money.rkt"
         "../pos/domain/transaction-event.rkt"
         "../pos/domain/transaction.rkt"
         "../pos/persistence/sqlite-transaction-event-store.rkt"
         "../pos/persistence/transaction-journal-migrations.rkt")

(define test-barcode "049000001234")

(define (call-with-connection database-path mode procedure)
  (define connection
    (db:sqlite3-connect #:database database-path #:mode mode))
  (dynamic-wind
    void
    (lambda () (procedure connection))
    (lambda () (db:disconnect connection))))

(define (successful-transaction result expected-version)
  (check-pred transaction-service-success? result)
  (check-equal? (transaction-service-success-version result)
                expected-version)
  (transaction-service-success-transaction result))

(module+ test
  (test-case "cash sale survives each durable workflow boundary"
    (define database-path
      (make-temporary-file "grocery-pos-service-~a.sqlite"))
    (dynamic-wind
      void
      (lambda ()
        ;; Connection A creates and scans the transaction.
        (call-with-connection
         database-path
         'create
         (lambda (connection-A)
           (migrate-transaction-journal! connection-A)
           (define service-A
             (make-transaction-service connection-A))
           (successful-transaction
            (transaction-service-start-transaction service-A "txn-001")
            1)
           (define scanned
             (successful-transaction
              (transaction-service-scan-barcode
               service-A
               "txn-001"
               test-barcode
               fake-catalog-lookup)
              2))
           (check-equal? (transaction-status scanned) 'open)
           (check-equal? (transaction-subtotal scanned) (money 199))
           (check-equal? (transaction-total scanned) (money 199))))

        ;; Connection B recovers and tenders the transaction.
        (call-with-connection
         database-path
         'read/write
         (lambda (connection-B)
           (define service-B
             (make-transaction-service connection-B))
           (define recovered-open
             (successful-transaction
              (transaction-service-load-transaction service-B "txn-001")
              2))
           (define line-item
             (first (transaction-line-items recovered-open)))
           (check-equal? (transaction-id recovered-open) "txn-001")
           (check-equal? (transaction-status recovered-open) 'open)
           (check-equal? (transaction-line-item-description line-item)
                         "Test Apples")
           (check-equal? (transaction-subtotal recovered-open) (money 199))
           (check-equal? (transaction-total recovered-open) (money 199))

           (define paid
             (successful-transaction
              (transaction-service-tender-cash
               service-B
               "txn-001"
               (money 500))
              3))
           (check-equal? (transaction-status paid) 'paid)
           (check-equal? (transaction-tendered-cash paid) (money 500))
           (check-equal? (transaction-change-due paid) (money 301))))

        ;; Connection C proves the paid state is durable, then completes it.
        (call-with-connection
         database-path
         'read/write
         (lambda (connection-C)
           (define service-C
             (make-transaction-service connection-C))
           (define recovered-paid
             (successful-transaction
              (transaction-service-load-transaction service-C "txn-001")
              3))
           (check-equal? (transaction-status recovered-paid) 'paid)
           (check-equal? (transaction-subtotal recovered-paid) (money 199))
           (check-equal? (transaction-tendered-cash recovered-paid)
                         (money 500))
           (check-equal? (transaction-change-due recovered-paid) (money 301))

           (define completed
             (successful-transaction
              (transaction-service-complete-transaction
               service-C
               "txn-001")
              4))
           (check-equal? (transaction-status completed) 'completed)
           (check-equal? (transaction-tendered-cash completed) (money 500))
           (check-equal? (transaction-change-due completed) (money 301))))

        ;; Connection D proves final recovery depends only on the journal file.
        (call-with-connection
         database-path
         'read/write
         (lambda (connection-D)
           (define service-D
             (make-transaction-service connection-D))
           (define recovered-final
             (successful-transaction
              (transaction-service-load-transaction service-D "txn-001")
              4))
           (check-equal? (transaction-status recovered-final) 'completed)
           (check-equal? (transaction-subtotal recovered-final) (money 199))
           (check-equal? (transaction-total recovered-final) (money 199))
           (check-equal? (transaction-tendered-cash recovered-final)
                         (money 500))
           (check-equal? (transaction-change-due recovered-final) (money 301))

           (define journal-result
             (load-transaction-events connection-D "txn-001"))
           (define events
             (journal-load-succeeded-events journal-result))
           (check-equal?
            events
            (list (transaction-started "txn-001")
                  (sale-item-added test-barcode
                                   "Test Apples"
                                   (money 199))
                  (cash-tendered (money 500))
                  (transaction-completed)))
           (check-equal?
            (db:query-list
             connection-D
             #<<SQL
SELECT stream_sequence
FROM transaction_events
WHERE transaction_id = 'txn-001'
ORDER BY stream_sequence ASC
SQL
             )
            '(1 2 3 4)))))
      (lambda ()
        (when (file-exists? database-path)
          (delete-file database-path))))))
