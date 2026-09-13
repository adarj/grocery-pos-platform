#lang racket

(require (prefix-in db: db)
         json
         racket/file
         racket/string
         "../../pos-backend-racket/pos/application/register-operations-service.rkt"
         "../../pos-backend-racket/pos/application/transaction-command-receipt.rkt"
         "../../pos-backend-racket/pos/application/transaction-command.rkt"
         "../../pos-backend-racket/pos/application/transaction-service.rkt"
         "../../pos-backend-racket/pos/domain/fake-catalog.rkt"
         "../../pos-backend-racket/pos/domain/money.rkt"
         "../../pos-backend-racket/pos/domain/register-operations.rkt"
         "../../pos-backend-racket/pos/domain/shift-cash-accountability.rkt"
         "../../pos-backend-racket/pos/persistence/operational-configuration-snapshot-codec.rkt"
         "../../pos-backend-racket/pos/persistence/pos-database-migrations.rkt"
         "../../pos-backend-racket/pos/persistence/sqlite-connection.rkt"
         "../../pos-backend-racket/pos/persistence/sqlite-maintenance.rkt"
         "../../pos-backend-racket/pos/persistence/sqlite-register-operations.rkt"
         "../../pos-backend-racket/pos/persistence/transaction-command-unit-of-work.rkt"
         "../../pos-backend-racket/pos/runtime.rkt")

(define configuration-json
  "{\"schema_version\":1,\"register\":{\"register_id\":\"acceptance-register\",\"display_name\":\"Acceptance Register\"},\"cashiers\":[{\"cashier_id\":\"acceptance-cashier\",\"display_name\":\"Acceptance Cashier\",\"active\":true}]}")

(define (configuration)
  (define decoded
    (json-string->operational-configuration-snapshot configuration-json))
  (unless (operational-configuration-decode-success? decoded)
    (error 'm6-soak "acceptance configuration did not decode"))
  (operational-configuration-decode-success-snapshot decoded))

(define (parse-iterations arguments)
  (define value
    (cond
      [(null? arguments) 1000]
      [(null? (cdr arguments)) (string->number (car arguments))]
      [else #f]))
  (unless (exact-positive-integer? value)
    (raise-user-error 'm6-soak "expected one positive iteration count"))
  value)

(define (next-clock clock)
  (set-box! clock (add1 (unbox clock)))
  (unbox clock))

(define (open-connection database-path)
  (open-pos-sqlite-connection database-path 'read/write))

(define (close-connection! connection)
  (when (and connection (db:connected? connection))
    (db:disconnect connection)))

(define (execute-accepted! service command)
  (define result (transaction-service-execute-command service command))
  (unless (transaction-service-command-resolved? result)
    (error 'm6-soak "command did not resolve: ~a" command))
  (define receipt (transaction-service-command-resolved-receipt result))
  (unless (eq? (transaction-command-receipt-outcome-kind receipt) 'accepted)
    (error 'm6-soak "command was not accepted: ~a" receipt))
  receipt)

(define (wal-size database-path)
  (define path
    (bytes->path (bytes-append (path->bytes database-path) #"-wal")))
  (if (file-exists? path) (file-size path) 0))

(define (assert-equal label actual expected)
  (unless (equal? actual expected)
    (error 'm6-soak "~a: expected ~a, received ~a" label expected actual)))

(define (run-soak iterations)
  (define started-at (current-inexact-milliseconds))
  (define directory
    (make-temporary-file "grocery-pos-m6-soak-~a" 'directory))
  (dynamic-wind
    void
    (lambda ()
      (define database-path (build-path directory "pos.db"))
      (initialize-sqlite-database! database-path)
      (define clock (box 1000000))
      (define connection (open-connection database-path))
      (define restart-count 0)
      (define backup-count 0)
      (define maximum-wal-bytes 0)
      (define last-backup-bytes 0)

      (define (transaction-service)
        (make-transaction-service
         connection
         #:catalog-lookup fake-catalog-lookup
         #:current-epoch-ms (lambda () (next-clock clock))))

      (define (register-service)
        (make-register-operations-service
         connection
         #:current-epoch-ms (lambda () (next-clock clock))
         #:generate-shift-id (lambda () "acceptance-shift")))

      (dynamic-wind
        void
        (lambda ()
          (activate-operational-configuration! connection (configuration))
          (define opened
            (register-operations-open-shift
             (register-service) "acceptance-cashier" (money 10000)))
          (unless (register-shift-opened? opened)
            (error 'm6-soak "acceptance shift did not open"))

          (for ([iteration (in-range 1 (add1 iterations))])
            (define transaction-id (format "acceptance-txn-~a" iteration))
            (define prefix (format "acceptance-~a" iteration))
            (define service (transaction-service))
            (execute-accepted!
             service
             (start-transaction-command
              (string-append prefix "-start") transaction-id 0))
            (execute-accepted!
             service
             (scan-barcode-command
              (string-append prefix "-scan")
              transaction-id
              1
              "049000001234"))
            (execute-accepted!
             service
             (tender-cash-command
              (string-append prefix "-tender")
              transaction-id
              2
              (money 500)))
            (define completion
              (complete-transaction-command
               (string-append prefix "-complete") transaction-id 3))
            (define original-completion
              (execute-accepted! service completion))
            (set! maximum-wal-bytes
                  (max maximum-wal-bytes (wal-size database-path)))

            ;; Reconstruct every service/connection before retrying the exact
            ;; completion command. This repeatedly exercises durable receipt
            ;; recovery rather than an in-memory result cache.
            (close-connection! connection)
            (set! connection (open-connection database-path))
            (set! restart-count (add1 restart-count))
            (define retried-completion
              (execute-accepted! (transaction-service) completion))
            (assert-equal "same-ID completion receipt"
                          retried-completion
                          original-completion)

            (when (or (= iteration iterations)
                      (zero? (remainder iteration 100)))
              (define backup-path
                (build-path directory (format "snapshot-~a.db" iteration)))
              (define created
                (create-pos-sqlite-backup! database-path backup-path))
              (unless
                  (sqlite-backup-validation-valid?
                   (sqlite-backup-created-validation created))
                (error 'm6-soak "published soak backup did not validate"))
              (set! backup-count (add1 backup-count))
              (set! last-backup-bytes (file-size backup-path))))

          (define expected-cash (+ 10000 (* iterations 199)))
          (define summary-result
            (register-operations-load-cash-summary
             (register-service) "acceptance-shift"))
          (unless (shift-cash-summary-found? summary-result)
            (error 'm6-soak "shift cash summary was unavailable"))
          (define summary (shift-cash-summary-found-summary summary-result))
          (assert-equal
           "completed cash sale count"
           (shift-cash-summary-completed-cash-sale-count summary)
           iterations)
          (assert-equal
           "cash sales"
           (money-minor-units (shift-cash-summary-cash-sales summary))
           (* iterations 199))
          (assert-equal
           "expected cash"
           (money-minor-units (shift-cash-summary-expected-cash summary))
           expected-cash)

          (define closed
            (register-operations-close-shift
             (register-service) "acceptance-shift" (money expected-cash)))
          (unless (register-shift-closed? closed)
            (error 'm6-soak "acceptance shift did not close"))
          (define repeated-close
            (register-operations-close-shift
             (register-service) "acceptance-shift" (money 0)))
          (assert-equal "immutable reconciliation"
                        (register-shift-closed-cash-summary repeated-close)
                        (register-shift-closed-cash-summary closed))

          (assert-equal
           "transaction event count"
           (db:query-value connection "SELECT COUNT(*) FROM transaction_events")
           (* iterations 4))
          (assert-equal
           "command receipt count"
           (db:query-value
            connection "SELECT COUNT(*) FROM transaction_command_receipts")
           (* iterations 4))
          (assert-equal
           "cash movement count"
           (db:query-value connection "SELECT COUNT(*) FROM shift_cash_movements")
           (add1 iterations)))
        (lambda () (close-connection! connection)))

      (define integrity (integrity-check-pos-sqlite-database database-path))
      (unless (sqlite-integrity-result-healthy? integrity)
        (error 'm6-soak "final full integrity or foreign-key check failed"))
      (define validation (validate-pos-sqlite-backup database-path))
      (unless (sqlite-backup-validation-valid? validation)
        (error 'm6-soak "final current-schema validation failed"))

      (hasheq
       'ok #t
       'iterations iterations
       'connection_restarts restart-count
       'validated_backups backup-count
       'main_database_bytes (file-size database-path)
       'maximum_observed_wal_bytes maximum-wal-bytes
       'last_backup_bytes last-backup-bytes
       'schema_version current-pos-database-schema-version
       'integrity "ok"
       'foreign_key_violations 0
       'elapsed_milliseconds
       (inexact->exact
        (round (- (current-inexact-milliseconds) started-at)))))
    (lambda () (delete-directory/files directory))))

(module+ main
  (define result
    (run-soak (parse-iterations (vector->list (current-command-line-arguments)))))
  (write-json result)
  (newline))
