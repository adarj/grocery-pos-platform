#lang racket

(require (prefix-in db: db)
         rackunit
         "../pos/application/authentication-service.rkt"
         "../pos/application/register-operations-service.rkt"
         "../pos/domain/money.rkt"
         "../pos/domain/register-operations.rkt"
         "../pos/domain/shift-cash-accountability.rkt"
         "../pos/persistence/pos-database-migrations.rkt")

(define alice (authenticated-operator "Alice" "Alice" 'cashier))
(define bob (authenticated-operator "Bob" "Bob" 'cashier))
(define sam (authenticated-operator "Sam" "Sam" 'supervisor))
(define morgan (authenticated-operator "Morgan" "Morgan" 'manager))
(define unconfigured-manager
  (authenticated-operator "Manager-Only" "Manager Only" 'manager))

(define (call-with-service proc)
  (define connection (db:sqlite3-connect #:database 'memory))
  (define next-shift 0)
  (dynamic-wind
    (lambda ()
      (db:query-exec connection "PRAGMA foreign_keys = ON")
      (migrate-pos-database! connection)
      (db:query-exec
       connection
       "INSERT INTO register_configuration VALUES (1, 'register-1', 'Register 1')")
      (for ([entry (in-list '(("Alice" "Alice" "cashier")
                              ("Bob" "Bob" "cashier")
                              ("Sam" "Sam" "supervisor")
                              ("Morgan" "Morgan" "manager")
                              ("Manager-Only" "Manager Only" "manager")))])
        (db:query-exec connection "INSERT INTO operators VALUES (?, ?, 1)"
                       (first entry) (second entry))
        (db:query-exec connection "INSERT INTO operator_roles VALUES (?, ?)"
                       (first entry) (third entry)))
      (for ([entry (in-list '(("Alice" "Alice")
                              ("Bob" "Bob")
                              ("Sam" "Sam")
                              ("Morgan" "Morgan")))])
        (db:query-exec connection "INSERT INTO cashiers VALUES (?, ?, 1)"
                       (first entry) (second entry))))
    (lambda ()
      (proc
       connection
       (make-register-operations-service
        connection
        #:current-epoch-ms (lambda () 2000)
        #:generate-shift-id
        (lambda ()
          (set! next-shift (add1 next-shift))
          (format "shift-~a" next-shift)))))
    (lambda () (db:disconnect connection))))

(module+ test
  (test-case "required shift audit failure rolls back opening and closing"
    (call-with-service
     (lambda (connection ordinary)
       (define failing
         (make-register-operations-service
          connection
          #:current-epoch-ms (lambda () 2000)
          #:generate-shift-id (lambda () "shift-audit-fail")
          #:audit-append!
          (lambda (_connection _event)
            (error 'test "simulated audit insertion failure"))))
       (check-exn exn:fail?
                  (lambda ()
                    (register-operations-open-shift
                     failing alice (money 12345))))
       (check-equal?
        (db:query-value connection "SELECT COUNT(*) FROM register_shifts") 0)
       (check-equal?
        (db:query-value connection "SELECT COUNT(*) FROM shift_cash_movements") 0)
       (register-operations-open-shift ordinary alice (money 12345))
       (check-exn exn:fail?
                  (lambda ()
                    (register-operations-close-shift
                     failing alice "shift-1" (money 12345))))
       (check-equal?
        (db:query-value connection
                        "SELECT COUNT(*) FROM shift_cash_reconciliations") 0)
       (check-equal?
        (db:query-value connection
                        "SELECT COUNT(*) FROM register_shifts WHERE closed_at_epoch_ms IS NULL") 1))))

  (test-case "shift opening derives exact authenticated operator identity"
    (call-with-service
     (lambda (_connection service)
       (define unconfigured
         (register-operations-open-shift
          service unconfigured-manager (money 1000)))
       (check-pred register-shift-open-rejected? unconfigured)
       (check-equal?
        (register-shift-open-rejected-code unconfigured)
        'cashier-not-found)
       (define opened
         (register-operations-open-shift service alice (money 1000)))
       (check-pred register-shift-opened? opened)
       (check-equal?
        (register-shift-cashier-id (register-shift-opened-shift opened))
        "Alice")
       )))

  (test-case "only manager may close another operator shift"
    (for ([principal (in-list (list bob sam))])
      (call-with-service
       (lambda (connection service)
         (register-operations-open-shift service alice (money 1000))
         (define result
           (register-operations-close-shift
            service principal "shift-1" (money 1000)))
         (check-pred register-shift-close-rejected? result)
         (check-equal? (register-shift-close-rejected-code result)
                       'authorization-denied)
         (check-equal?
          (db:query-value
           connection
           "SELECT COUNT(*) FROM security_audit_events WHERE event_type = 'authorization.denied'")
          1))))
    (call-with-service
     (lambda (_connection service)
       (register-operations-open-shift service alice (money 1000))
       (check-pred
        register-shift-closed?
        (register-operations-close-shift
         service morgan "shift-1" (money 1000))))))

  (test-case "foreign manager role is rechecked inside final writer boundary"
    (call-with-service
     (lambda (connection service)
       (register-operations-open-shift service alice (money 1000))
       (db:query-exec
        connection
        "UPDATE operator_roles SET role = 'supervisor' WHERE operator_id = 'Morgan'")
       (define result
         (register-operations-close-shift
          service morgan "shift-1" (money 1000)))
       (check-pred register-shift-close-rejected? result)
       (check-equal? (register-shift-close-rejected-code result)
                     'authorization-denied))))

  (test-case "manager close-any cannot bypass an occupied transaction slot"
    (call-with-service
     (lambda (connection service)
       (register-operations-open-shift service alice (money 1000))
       (db:query-exec
        connection
        "UPDATE register_shifts SET active_transaction_id = 'txn-open' WHERE shift_id = 'shift-1'")
       (define result
         (register-operations-close-shift
          service morgan "shift-1" (money 1000)))
       (check-pred register-shift-close-rejected? result)
       (check-equal?
        (register-shift-close-rejected-code result)
        'shift-has-active-transaction))))

  (test-case "open own cash summary is limited while read-any is full"
    (call-with-service
     (lambda (connection service)
       (register-operations-open-shift service alice (money 12345))
       (define own-open
         (register-operations-load-cash-summary service alice "shift-1"))
       (check-pred register-cash-summary-limited? own-open)
       (check-equal? (register-cash-summary-limited-status own-open) 'open)
       (check-pred
        register-cash-summary-authorization-denied?
        (register-operations-load-cash-summary service bob "shift-1"))
       (check-equal?
        (db:query-value
         connection
         "SELECT COUNT(*) FROM security_audit_events WHERE event_type = 'authorization.denied'")
        1)
       (for ([principal (in-list (list sam morgan))])
         (define broad
           (register-operations-load-cash-summary
            service principal "shift-1"))
         (check-pred register-cash-summary-full? broad)
         (check-equal?
          (money-minor-units
           (shift-cash-summary-expected-cash
            (register-cash-summary-full-summary broad)))
          12345))
       (register-operations-close-shift
        service alice "shift-1" (money 12345))
       (check-pred
        register-cash-summary-full?
        (register-operations-load-cash-summary service alice "shift-1"))))))
