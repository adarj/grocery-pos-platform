#lang racket

(require (prefix-in db: db)
         racket/file
         rackunit
         "../pos/domain/money.rkt"
         "../pos/domain/transaction-event.rkt"
         "../pos/domain/transaction.rkt"
         "../pos/persistence/sqlite-transaction-event-store.rkt"
         "../pos/persistence/pos-database-migrations.rkt")

(define (call-with-connection database-path mode procedure)
  (define connection
    (db:sqlite3-connect #:database database-path #:mode mode))
  (dynamic-wind
    void
    (lambda () (procedure connection))
    (lambda () (db:disconnect connection))))

(module+ test
  (test-case "persisted decoded events replay the complete cash sale"
    (define database-path
      (make-temporary-file "grocery-pos-journal-~a.sqlite"))
    (dynamic-wind
      void
      (lambda ()
        (call-with-connection
         database-path
         'create
         (lambda (writer)
           (migrate-pos-database! writer)
           (define append-result
             (append-transaction-events!
              writer
              "txn-001"
              0
              (list
               (transaction-started "txn-001")
               (sale-item-added "049000001234"
                                "Test Apples"
                                (money 199))
               (cash-tendered (money 500))
               (transaction-completed))))
           (check-pred journal-append-succeeded? append-result)
           (check-equal? (journal-append-succeeded-new-version append-result)
                         4)))

        ;; Reopen the file so recovery depends only on the SQLite journal.
        (call-with-connection
         database-path
         'read/write
         (lambda (reader)
           (define load-result
             (load-transaction-events reader "txn-001"))
           (check-pred journal-load-succeeded? load-result)

           (define replay-result
             (replay-transaction
              (journal-load-succeeded-events load-result)))
           (check-pred replay-succeeded? replay-result)

           (define recovered
             (replay-succeeded-transaction replay-result))
           (define line-item
             (first (transaction-line-items recovered)))
           (check-equal? (transaction-id recovered) "txn-001")
           (check-equal? (transaction-status recovered) 'completed)
           (check-equal? (transaction-line-item-barcode line-item)
                         "049000001234")
           (check-equal? (transaction-line-item-description line-item)
                         "Test Apples")
           (check-equal? (transaction-subtotal recovered) (money 199))
           (check-equal? (transaction-total recovered) (money 199))
           (check-equal? (transaction-tendered-cash recovered) (money 500))
           (check-equal? (transaction-change-due recovered) (money 301)))))
      (lambda ()
        (when (file-exists? database-path)
          (delete-file database-path))))))
