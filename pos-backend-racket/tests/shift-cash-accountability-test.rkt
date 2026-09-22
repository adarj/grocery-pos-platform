#lang racket

(require (prefix-in db: db)
         rackunit
         "../pos/application/authentication-service.rkt"
         (rename-in "../pos/application/register-operations-service.rkt"
                    [register-operations-open-shift open-shift/authorized]
                    [register-operations-close-shift close-shift/authorized])
         "../pos/domain/money.rkt"
         "../pos/domain/register-operations.rkt"
         "../pos/domain/shift-cash-accountability.rkt"
         "../pos/persistence/operational-configuration-snapshot-codec.rkt"
         "../pos/persistence/pos-database-migrations.rkt"
         "../pos/persistence/sqlite-register-operations.rkt")

(define cashier-one-principal
  (authenticated-operator "cashier-one" "Alice" 'cashier))

(define (register-operations-open-shift service _cashier-id opening-cash)
  (open-shift/authorized service cashier-one-principal opening-cash))

(define (register-operations-close-shift service shift-id counted-cash)
  (close-shift/authorized
   service cashier-one-principal shift-id counted-cash))

(define configuration-json
  "{\"schema_version\":1,\"register\":{\"register_id\":\"register-one\",\"display_name\":\"Register One\"},\"cashiers\":[{\"cashier_id\":\"cashier-one\",\"display_name\":\"Alice\",\"active\":true}]}")

(define (configuration)
  (operational-configuration-decode-success-snapshot
   (json-string->operational-configuration-snapshot configuration-json)))

(define (call-with-database procedure)
  (define connection (db:sqlite3-connect #:database 'memory))
  (dynamic-wind
    (lambda ()
      (migrate-pos-database! connection)
      (activate-operational-configuration! connection (configuration)))
    (lambda () (procedure connection))
    (lambda () (db:disconnect connection))))

(define (make-service connection times)
  (define remaining-times (box times))
  (make-register-operations-service
   connection
   #:current-epoch-ms
   (lambda ()
     (define value (first (unbox remaining-times)))
     (set-box! remaining-times (rest (unbox remaining-times)))
     value)
   #:generate-shift-id (lambda () "shift-one")))

(define (found-summary result)
  (check-pred shift-cash-summary-found? result)
  (shift-cash-summary-found-summary result))

(module+ test
  (test-case "new shift atomically records one exact opening float"
    (call-with-database
     (lambda (connection)
       (define service (make-service connection '(1000)))
       (define opened
         (register-operations-open-shift
          service "cashier-one" (money 10000)))
       (check-pred register-shift-opened? opened)
       (check-equal?
        (db:query-rows
         connection
         #<<SQL
SELECT shift_id, movement_sequence, movement_type, amount_minor_units,
       transaction_id, recorded_at_epoch_ms
FROM shift_cash_movements
SQL
         )
        (list (vector "shift-one" 1 "opening_float" 10000 db:sql-null 1000)))
       (define summary
         (register-shift-opened-cash-summary opened))
       (check-equal? (shift-cash-summary-status summary) 'open)
       (check-equal? (shift-cash-summary-opening-cash summary) (money 10000))
       (check-equal? (shift-cash-summary-cash-sales summary) (money 0))
       (check-equal? (shift-cash-summary-expected-cash summary) (money 10000))
       (check-equal? (shift-cash-summary-completed-cash-sale-count summary) 0)
       (check-false (shift-cash-summary-counted-cash summary))
       (check-false (shift-cash-summary-over-short-minor-units summary)))))

  (test-case "zero opening is valid and repeated open cannot rewrite it"
    (call-with-database
     (lambda (connection)
       (define service (make-service connection '(1000)))
       (define first
         (register-operations-open-shift service "cashier-one" (money 0)))
       (define repeated
         (register-operations-open-shift service "cashier-one" (money 9999)))
       (check-equal? (register-shift-opened-shift repeated)
                     (register-shift-opened-shift first))
       (check-equal?
        (shift-cash-summary-opening-cash
         (register-shift-opened-cash-summary repeated))
        (money 0))
       (check-equal?
        (db:query-value connection "SELECT COUNT(*) FROM shift_cash_movements")
        1))))

  (test-case "opening movement failure rolls back the new shift"
    (call-with-database
     (lambda (connection)
       (define service (make-service connection '(1000)))
       (db:query-exec
        connection
        #<<SQL
CREATE TRIGGER fail_opening_float_insert
BEFORE INSERT ON shift_cash_movements
WHEN NEW.movement_type = 'opening_float'
BEGIN
  SELECT RAISE(ABORT, 'simulated opening movement failure');
END
SQL
        )
       (check-exn
        db:exn:fail:sql?
        (lambda ()
          (register-operations-open-shift
           service "cashier-one" (money 10000))))
       (check-equal?
        (db:query-value connection "SELECT COUNT(*) FROM register_shifts")
        0)
       (check-equal?
        (db:query-value connection "SELECT COUNT(*) FROM shift_cash_movements")
        0))))

  (test-case "close atomically preserves exact positive negative and zero variance"
    (for ([counted (in-list '(10000 10025 9975))]
          [variance (in-list '(0 25 -25))])
      (call-with-database
       (lambda (connection)
         (define service (make-service connection '(1000 2000)))
         (register-operations-open-shift
          service "cashier-one" (money 10000))
         (define closed
           (register-operations-close-shift
            service "shift-one" (money counted)))
         (check-pred register-shift-closed? closed)
         (define summary (register-shift-closed-cash-summary closed))
         (check-equal? (shift-cash-summary-status summary) 'closed)
         (check-equal? (shift-cash-summary-expected-cash summary)
                       (money 10000))
         (check-equal? (shift-cash-summary-counted-cash summary)
                       (money counted))
         (check-equal? (shift-cash-summary-over-short-minor-units summary)
                       variance)
         (check-equal?
          (db:query-row
           connection
           "SELECT expected_cash_minor_units, counted_cash_minor_units, over_short_minor_units FROM shift_cash_reconciliations")
          (vector 10000 counted variance))))))

  (test-case "repeated close returns first immutable reconciliation"
    (call-with-database
     (lambda (connection)
       (define service (make-service connection '(1000 2000)))
       (register-operations-open-shift
        service "cashier-one" (money 10000))
       (define first
         (register-operations-close-shift
          service "shift-one" (money 9975)))
       (define repeated
         (register-operations-close-shift
          service "shift-one" (money 50000)))
       (check-equal? (register-shift-closed-shift repeated)
                     (register-shift-closed-shift first))
       (check-equal? (register-shift-closed-cash-summary repeated)
                     (register-shift-closed-cash-summary first))
       (check-equal?
        (money-minor-units
         (shift-cash-summary-counted-cash
          (register-shift-closed-cash-summary repeated)))
        9975)
       (check-equal?
        (db:query-value
         connection "SELECT COUNT(*) FROM shift_cash_reconciliations")
        1))))

  (test-case "reconciliation insertion failure leaves the shift open"
    (call-with-database
     (lambda (connection)
       (define service (make-service connection '(1000 2000)))
       (register-operations-open-shift
        service "cashier-one" (money 10000))
       (db:query-exec
        connection
        #<<SQL
CREATE TRIGGER fail_reconciliation_insert
BEFORE INSERT ON shift_cash_reconciliations
BEGIN
  SELECT RAISE(ABORT, 'simulated reconciliation failure');
END
SQL
        )
       (check-exn
        db:exn:fail:sql?
        (lambda ()
          (register-operations-close-shift
           service "shift-one" (money 10000))))
       (check-pred
        db:sql-null?
        (db:query-value
         connection
         "SELECT closed_at_epoch_ms FROM register_shifts WHERE shift_id = 'shift-one'"))
       (check-equal?
        (db:query-value
         connection "SELECT COUNT(*) FROM shift_cash_reconciliations")
        0))))

  (test-case "close-time update failure rolls back reconciliation"
    (call-with-database
     (lambda (connection)
       (define service (make-service connection '(1000 2000)))
       (register-operations-open-shift
        service "cashier-one" (money 10000))
       (db:query-exec
        connection
        #<<SQL
CREATE TRIGGER fail_shift_close_update
BEFORE UPDATE OF closed_at_epoch_ms ON register_shifts
WHEN NEW.closed_at_epoch_ms IS NOT NULL
BEGIN
  SELECT RAISE(ABORT, 'simulated shift close failure');
END
SQL
        )
       (check-exn
        db:exn:fail:sql?
        (lambda ()
          (register-operations-close-shift
           service "shift-one" (money 10000))))
       (check-pred
        db:sql-null?
        (db:query-value
         connection
         "SELECT closed_at_epoch_ms FROM register_shifts WHERE shift_id = 'shift-one'"))
       (check-equal?
        (db:query-value
         connection "SELECT COUNT(*) FROM shift_cash_reconciliations")
        0))))

  (test-case "legacy closed shift has no fabricated cash accounting"
    (call-with-database
     (lambda (connection)
       (db:query-exec
        connection
        #<<SQL
INSERT INTO register_shifts
  (shift_id, register_id, register_display_name, cashier_id,
   cashier_display_name, opened_at_epoch_ms, closed_at_epoch_ms,
   active_transaction_id)
VALUES ('legacy-shift', 'register-one', 'Register One', 'cashier-one',
        'Alice', 100, 200, NULL)
SQL
        )
       (define result
         (load-shift-cash-summary connection "legacy-shift"))
       (check-pred shift-cash-summary-unavailable? result))))

  (test-case "missing opening and noncontiguous sequence fail closed"
    (call-with-database
     (lambda (connection)
       (define service (make-service connection '(1000)))
       (register-operations-open-shift
        service "cashier-one" (money 10000))
       (db:query-exec connection "DELETE FROM shift_cash_movements")
       (check-exn
        exn:fail?
        (lambda ()
          (load-shift-cash-summary connection "shift-one")))))
    (call-with-database
     (lambda (connection)
       (define service (make-service connection '(1000)))
       (register-operations-open-shift
        service "cashier-one" (money 10000))
       (db:query-exec connection "PRAGMA ignore_check_constraints = ON")
       (db:query-exec connection "DROP INDEX shift_cash_movements_shift_sequence_unique")
       (db:query-exec
        connection
        "UPDATE shift_cash_movements SET movement_sequence = 2")
       (check-exn
        exn:fail?
        (lambda ()
          (load-shift-cash-summary connection "shift-one")))))))
