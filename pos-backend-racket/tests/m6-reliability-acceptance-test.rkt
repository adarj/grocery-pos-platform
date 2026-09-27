#lang racket

(require "support/seed-authenticated-operator.rkt")

(require (prefix-in db: db)
         racket/file
         rackunit
         "../pos/application/authentication-service.rkt"
         "../pos/application/register-operations-service.rkt"
         "../pos/application/transaction-command-receipt.rkt"
         "../pos/application/transaction-command.rkt"
         "../pos/application/transaction-service.rkt"
         "../pos/domain/fake-catalog.rkt"
         "../pos/domain/money.rkt"
         "../pos/domain/register-operations.rkt"
         "../pos/domain/shift-cash-accountability.rkt"
         "../pos/persistence/operational-configuration-snapshot-codec.rkt"
         "../pos/persistence/sqlite-connection.rkt"
         "../pos/persistence/sqlite-maintenance.rkt"
         "../pos/persistence/sqlite-register-operations.rkt"
         "../pos/persistence/sqlite-restore.rkt"
         "../pos/persistence/transaction-command-unit-of-work.rkt"
         "../pos/runtime.rkt")

(define acceptance-principal
  (authenticated-operator
   "acceptance-cashier" "Acceptance Cashier" 'cashier 1))

(define configuration-json
  "{\"schema_version\":1,\"register\":{\"register_id\":\"acceptance-register\",\"display_name\":\"Acceptance Register\"},\"cashiers\":[{\"cashier_id\":\"acceptance-cashier\",\"display_name\":\"Acceptance Cashier\",\"active\":true}]}")

(define (configuration)
  (operational-configuration-decode-success-snapshot
   (json-string->operational-configuration-snapshot configuration-json)))

(define (call-with-temporary-directory procedure)
  (define directory
    (make-temporary-file "grocery-pos-m6-acceptance-~a" 'directory))
  (dynamic-wind
    void
    (lambda () (procedure directory))
    (lambda () (delete-directory/files directory))))

(define (open-connection database-path)
  (open-pos-sqlite-connection database-path 'read/write))

(define (close-connection! connection)
  (when (and connection (db:connected? connection))
    (db:disconnect connection)))

(define (next-time clock)
  (set-box! clock (add1 (unbox clock)))
  (unbox clock))

(define (make-transaction-service-for connection clock)
  (make-transaction-service
   connection
   #:catalog-lookup fake-catalog-lookup
   #:current-epoch-ms (lambda () (next-time clock))))

(define (execute-accepted! service command)
  (define result
    (transaction-service-execute-command
     service acceptance-principal command))
  (check-pred transaction-service-command-resolved? result)
  (define receipt (transaction-service-command-resolved-receipt result))
  (check-equal? (transaction-command-receipt-outcome-kind receipt) 'accepted)
  receipt)

(define (open-acceptance-shift! connection clock)
  (activate-operational-configuration! connection (configuration))
  (seed-authenticated-test-operator!
   connection "acceptance-cashier" 'cashier)
  (define result
    (register-operations-open-shift
     (make-register-operations-service
      connection
      #:current-epoch-ms (lambda () (next-time clock))
      #:generate-shift-id (lambda () "acceptance-shift"))
     acceptance-principal
     (money 10000)))
  (check-pred register-shift-opened? result))

(define (complete-sale! connection clock number)
  (define service (make-transaction-service-for connection clock))
  (define transaction-id (format "acceptance-txn-~a" number))
  (define prefix (format "acceptance-command-~a" number))
  (execute-accepted!
   service
   (start-transaction-command
    (string-append prefix "-start") transaction-id 0))
  (execute-accepted!
   service
   (scan-barcode-command
    (string-append prefix "-scan") transaction-id 1 "049000001234"))
  (execute-accepted!
   service
   (tender-cash-command
    (string-append prefix "-tender") transaction-id 2 (money 500)))
  (execute-accepted!
   service
   (complete-transaction-command
    (string-append prefix "-complete") transaction-id 3)))

(define (transaction-exists? database-path transaction-id)
  (call-with-pos-sqlite-inspection-connection
   database-path
   (lambda (connection)
     (positive?
      (db:query-value
       connection
       "SELECT COUNT(*) FROM transaction_events WHERE transaction_id = ?"
       transaction-id)))))

(define (cash-summary database-path)
  (define connection (open-connection database-path))
  (dynamic-wind
    void
    (lambda ()
      (define result (load-shift-cash-summary connection "acceptance-shift"))
      (check-pred shift-cash-summary-found? result)
      (shift-cash-summary-found-summary result))
    (lambda () (close-connection! connection))))

(module+ test
  (test-case "repeated valid writes produce independently valid backups under load"
    (call-with-temporary-directory
     (lambda (directory)
       (define database-path (build-path directory "pos.db"))
       (initialize-sqlite-database! database-path)
       (define writer-connection (open-connection database-path))
       (define clock (box 1000000))
       (open-acceptance-shift! writer-connection clock)

       (define writer-started (make-semaphore 0))
       (define writer-result (make-channel))
       (define writer
         (thread
          (lambda ()
            (with-handlers
                ([exn?
                  (lambda (exception)
                    (channel-put writer-result (cons 'failed exception)))])
              (for ([number (in-range 1 21)])
                (when (= number 1) (semaphore-post writer-started))
                (complete-sale! writer-connection clock number)
                ;; Widen the deterministic overlap without relying on a tiny
                ;; commit timing window.
                (sleep 0.005))
              (channel-put writer-result '(passed))))))

       (semaphore-wait writer-started)
       (define backups
         (for/list ([number (in-range 1 4)])
           (define backup-path
             (build-path directory (format "load-snapshot-~a.db" number)))
           (define created
             (create-pos-sqlite-backup! database-path backup-path))
           (check-true
            (sqlite-backup-validation-valid?
             (sqlite-backup-created-validation created)))
           backup-path))

       (define outcome (sync/timeout 30 writer-result))
       (unless outcome
         (kill-thread writer)
         (error 'm6-acceptance "writer timed out"))
       (thread-wait writer)
       (when (eq? (car outcome) 'failed) (raise (cdr outcome)))
       (close-connection! writer-connection)

       (for ([backup (in-list backups)])
         (check-true
          (sqlite-backup-validation-valid?
           (validate-pos-sqlite-backup backup))))
       (check-true
        (sqlite-integrity-result-healthy?
         (integrity-check-pos-sqlite-database database-path)))
       (check-true
        (sqlite-backup-validation-valid?
         (validate-pos-sqlite-backup database-path)))
       (define summary (cash-summary database-path))
       (check-equal?
        (shift-cash-summary-completed-cash-sale-count summary) 20)
       (check-equal?
        (money-minor-units (shift-cash-summary-cash-sales summary)) 3980)
       (check-equal?
        (money-minor-units (shift-cash-summary-expected-cash summary)) 13980))))

  (test-case "selected older recovery point restores only its financial state"
    (call-with-temporary-directory
     (lambda (directory)
       (define database-path (build-path directory "pos.db"))
       (define backup-path (build-path directory "after-sale-a.db"))
       (initialize-sqlite-database! database-path)
       (define connection (open-connection database-path))
       (define clock (box 2000000))
       (open-acceptance-shift! connection clock)
       (complete-sale! connection clock "sale-a")
       (create-pos-sqlite-backup! database-path backup-path)
       (complete-sale! connection clock "sale-b")
       (close-connection! connection)

       (define restored
         (restore-pos-sqlite-database-offline!
          backup-path database-path #:operation-id "round-trip"))
       (check-true (transaction-exists? database-path "acceptance-txn-sale-a"))
       (check-false (transaction-exists? database-path "acceptance-txn-sale-b"))
       (define displaced
         (build-path
          (sqlite-restore-installed-recovery-directory restored)
          "pos.db"))
       (check-true (transaction-exists? displaced "acceptance-txn-sale-a"))
       (check-true (transaction-exists? displaced "acceptance-txn-sale-b"))

       ;; Restore publishes an offline standalone snapshot. Normal startup
       ;; reestablishes WAL before request-style production connections.
       (initialize-sqlite-database! database-path)
       (check-true
        (sqlite-backup-validation-valid?
         (validate-pos-sqlite-backup database-path)))
       (define restored-summary (cash-summary database-path))
       (check-equal?
        (shift-cash-summary-completed-cash-sale-count restored-summary) 1)
       (check-equal?
        (money-minor-units
         (shift-cash-summary-expected-cash restored-summary))
        10199)))))
