#lang racket

(require (prefix-in db: db)
         rackunit
         "../pos/application/register-operations-service.rkt"
         "../pos/domain/register-operations.rkt"
         "../pos/persistence/operational-configuration-snapshot-codec.rkt"
         "../pos/persistence/pos-database-migrations.rkt"
         "../pos/persistence/sqlite-register-operations.rkt")

(define config-json
  #<<JSON
{
  "schema_version": 1,
  "register": {
    "register_id": "register-front-01",
    "display_name": "Front Register 1"
  },
  "cashiers": [
    {"cashier_id":"cashier-alice","display_name":"Alice","active":true},
    {"cashier_id":"cashier-bob","display_name":"Bob","active":true},
    {"cashier_id":"cashier-old","display_name":"Old Cashier","active":false}
  ]
}
JSON
  )

(define replacement-json
  #<<JSON
{
  "schema_version": 1,
  "register": {
    "register_id": "register-front-01",
    "display_name": "Front Register Renamed"
  },
  "cashiers": [
    {"cashier_id":"cashier-alice","display_name":"Alice Smith","active":true}
  ]
}
JSON
  )

(define (snapshot text)
  (define decoded (json-string->operational-configuration-snapshot text))
  (check-pred operational-configuration-decode-success? decoded)
  (operational-configuration-decode-success-snapshot decoded))

(define (call-with-database proc)
  (define connection (db:sqlite3-connect #:database 'memory))
  (dynamic-wind
    (lambda () (migrate-pos-database! connection))
    (lambda () (proc connection))
    (lambda () (db:disconnect connection))))

(define (make-service connection times ids)
  (define remaining-times (box times))
  (define remaining-ids (box ids))
  (make-register-operations-service
   connection
   #:current-epoch-ms
   (lambda ()
     (define values (unbox remaining-times))
     (when (null? values) (error 'test-clock "no timestamp remains"))
     (set-box! remaining-times (rest values))
     (first values))
   #:generate-shift-id
   (lambda ()
     (define values (unbox remaining-ids))
     (when (null? values) (error 'test-id "no shift ID remains"))
     (set-box! remaining-ids (rest values))
     (first values))))

(module+ test
  (test-case "configuration activation is atomic replacement and preserves shifts"
    (call-with-database
     (lambda (connection)
       (define first
         (activate-operational-configuration!
          connection (snapshot config-json)))
       (check-pred operational-configuration-activation-succeeded? first)
       (check-equal?
        (db:query-value connection "SELECT register_id FROM register_configuration")
        "register-front-01")
       (check-equal? (db:query-value connection "SELECT COUNT(*) FROM cashiers") 3)

       (define service (make-service connection '(1000 2000) '("shift_one")))
       (define opened
         (register-operations-open-shift service "cashier-alice"))
       (check-pred register-shift-opened? opened)
       (define shift (register-shift-opened-shift opened))
       (check-equal? (register-shift-shift-id shift) "shift_one")
       (check-equal? (register-shift-register-display-name shift)
                     "Front Register 1")
       (check-equal? (register-shift-cashier-display-name shift) "Alice")
       (check-equal? (register-shift-opened-at-epoch-ms shift) 1000)

       (define blocked
         (activate-operational-configuration!
          connection (snapshot replacement-json)))
       (check-pred operational-configuration-activation-rejected? blocked)
       (check-equal?
        (operational-configuration-activation-rejected-code blocked)
        'shift-open)
       (check-equal?
        (db:query-value connection "SELECT display_name FROM register_configuration")
        "Front Register 1")

       (check-pred
        register-shift-closed?
        (register-operations-close-shift service "shift_one"))
       (check-pred
        operational-configuration-activation-succeeded?
        (activate-operational-configuration!
         connection (snapshot replacement-json)))
       (check-equal?
        (db:query-list connection "SELECT cashier_id FROM cashiers ORDER BY cashier_id")
        '("cashier-alice"))
       (check-equal?
        (db:query-row
         connection
         "SELECT register_display_name, cashier_display_name FROM register_shifts WHERE shift_id = 'shift_one'")
        #("Front Register 1" "Alice")))))

  (test-case "unconfigured unknown and inactive open attempts reject safely"
    (call-with-database
     (lambda (connection)
       (define service (make-service connection '(1000) '("unused")))
       (define unconfigured
         (register-operations-open-shift service "cashier-alice"))
       (check-equal? (register-shift-open-rejected-code unconfigured)
                     'register-not-configured)
       (activate-operational-configuration! connection (snapshot config-json))
       (check-equal?
        (register-shift-open-rejected-code
         (register-operations-open-shift service "cashier-missing"))
        'cashier-not-found)
       (check-equal?
        (register-shift-open-rejected-code
         (register-operations-open-shift service "cashier-old"))
        'cashier-inactive))))

  (test-case "open is same-cashier idempotent and different-cashier exclusive"
    (call-with-database
     (lambda (connection)
       (activate-operational-configuration! connection (snapshot config-json))
       (define service (make-service connection '(1000) '("shift_exact")))
       (define first
         (register-operations-open-shift service "cashier-alice"))
       (define repeated
         (register-operations-open-shift service "cashier-alice"))
       (check-pred register-shift-opened? repeated)
       (check-equal? (register-shift-opened-shift repeated)
                     (register-shift-opened-shift first))
       (define conflict
         (register-operations-open-shift service "cashier-bob"))
       (check-pred register-shift-open-rejected? conflict)
       (check-equal? (register-shift-open-rejected-code conflict)
                     'shift-already-open)
       (check-equal?
        (db:query-value connection "SELECT COUNT(*) FROM register_shifts")
        1))))

  (test-case "close is exact repeatable and refuses an active transaction"
    (call-with-database
     (lambda (connection)
       (activate-operational-configuration! connection (snapshot config-json))
       (define service
         (make-service connection '(1000 2000) '("shift_close")))
       (register-operations-open-shift service "cashier-alice")
       (db:query-exec
        connection
        "UPDATE register_shifts SET active_transaction_id = 'txn-active' WHERE shift_id = 'shift_close'")
       (define blocked
         (register-operations-close-shift service "shift_close"))
       (check-pred register-shift-close-rejected? blocked)
       (check-equal? (register-shift-close-rejected-code blocked)
                     'shift-has-active-transaction)
       (db:query-exec
        connection
        "UPDATE register_shifts SET active_transaction_id = NULL WHERE shift_id = 'shift_close'")
       (define closed
         (register-operations-close-shift service "shift_close"))
       (check-pred register-shift-closed? closed)
       (check-equal?
        (register-shift-closed-at-epoch-ms
         (register-shift-closed-shift closed))
        2000)
       (define repeated
         (register-operations-close-shift service "shift_close"))
       (check-pred register-shift-closed? repeated)
       (check-equal? (register-shift-closed-shift repeated)
                     (register-shift-closed-shift closed))
       (check-equal?
        (register-shift-close-rejected-code
         (register-operations-close-shift service "missing"))
        'shift-not-found))))

  (test-case "register context and active cashier list expose current state only"
    (call-with-database
     (lambda (connection)
       (define service (make-service connection '(1000) '("shift_context")))
       (define before (register-operations-load-context service))
       (check-false (register-context-configured? before))
       (check-false (register-context-register before))
       (check-false (register-context-active-shift before))
       (activate-operational-configuration! connection (snapshot config-json))
       (check-equal?
        (map cashier-identity-cashier-id
             (register-operations-list-active-cashiers service))
        '("cashier-alice" "cashier-bob"))
       (register-operations-open-shift service "cashier-alice")
       (define active (register-operations-load-context service))
       (check-true (register-context-configured? active))
       (check-equal?
        (register-identity-display-name (register-context-register active))
        "Front Register 1")
       (check-equal?
        (register-shift-shift-id (register-context-active-shift active))
        "shift_context")))))
