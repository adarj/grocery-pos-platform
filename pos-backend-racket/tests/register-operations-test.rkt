#lang racket

(require (prefix-in db: db)
         racket/file
         rackunit
         "../pos/application/authentication-service.rkt"
         (rename-in "../pos/application/register-operations-service.rkt"
                    [register-operations-open-shift open-shift/authorized]
                    [register-operations-close-shift close-shift/authorized])
         "../pos/domain/money.rkt"
         "../pos/domain/register-operations.rkt"
         "../pos/persistence/operational-configuration-snapshot-codec.rkt"
         "../pos/persistence/pos-database-migrations.rkt"
         "../pos/persistence/security-audit-event-codec.rkt"
         "../pos/persistence/security-audit-store.rkt"
         "../pos/persistence/sqlite-connection.rkt"
         "../pos/persistence/sqlite-register-operations.rkt")

(define (cashier-principal cashier-id)
  (authenticated-operator cashier-id cashier-id 'cashier))

(define (register-operations-open-shift service cashier-id opening-cash)
  (open-shift/authorized service (cashier-principal cashier-id) opening-cash))

(define (register-operations-close-shift service shift-id counted-cash)
  (close-shift/authorized
   service (cashier-principal "cashier-alice") shift-id counted-cash))

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

(define security-seam-replacement-json
  #<<JSON
{
  "schema_version": 1,
  "register": {
    "register_id": "register-front-01",
    "display_name": "Front Register 1"
  },
  "cashiers": [
    {"cashier_id":"cashier-alice","display_name":"Operational Alice","active":true},
    {"cashier_id":"cashier-new","display_name":"New Cashier","active":false}
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
         (register-operations-open-shift service "cashier-alice" (money 0)))
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
        (register-operations-close-shift service "shift_one" (money 0)))
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

  (test-case "configuration replacement preserves security principals and credentials"
    (call-with-database
     (lambda (connection)
       (activate-operational-configuration! connection (snapshot config-json))
       (db:query-exec
        connection
        "UPDATE operators SET display_name = 'Security Alice', active = 0 WHERE operator_id = 'cashier-alice'")
       (db:query-exec
        connection
        "UPDATE operator_roles SET role = 'manager' WHERE operator_id = 'cashier-alice'")
       (db:query-exec
        connection
        #<<SQL
INSERT INTO operator_pin_credentials
  (operator_id, password_hash, credential_revision)
VALUES ('cashier-alice', '$argon2id$v=19$m=19456,t=2,p=1$c2FsdA$aGFzaA', 4)
SQL
        )

       (activate-operational-configuration!
        connection (snapshot security-seam-replacement-json))

       (check-equal?
        (db:query-rows
         connection
         "SELECT cashier_id, display_name, active FROM cashiers ORDER BY cashier_id")
        (list #("cashier-alice" "Operational Alice" 1)
              #("cashier-new" "New Cashier" 0)))
       (check-equal?
        (db:query-row
         connection
         #<<SQL
SELECT operator.display_name, operator.active, assignment.role,
       credential.password_hash, credential.credential_revision
FROM operators AS operator
JOIN operator_roles AS assignment USING (operator_id)
JOIN operator_pin_credentials AS credential USING (operator_id)
WHERE operator.operator_id = 'cashier-alice'
SQL
         )
        #("Security Alice"
          0
          "manager"
          "$argon2id$v=19$m=19456,t=2,p=1$c2FsdA$aGFzaA"
          4))
       (check-equal?
        (db:query-list
         connection
         "SELECT operator_id FROM operators ORDER BY operator_id")
        '("cashier-alice"
          "cashier-bob"
          "cashier-new"
          "cashier-old"))
       (check-equal?
        (db:query-row
         connection
         #<<SQL
SELECT operator.display_name, operator.active, assignment.role
FROM operators AS operator
JOIN operator_roles AS assignment USING (operator_id)
WHERE operator.operator_id = 'cashier-new'
SQL
         )
        #("New Cashier" 0 "cashier"))
       (check-equal?
        (db:query-value
         connection
         "SELECT COUNT(*) FROM operator_pin_credentials WHERE operator_id = 'cashier-new'")
        0))))

  (test-case "configuration activation audits only newly created operator principals"
    (call-with-database
     (lambda (connection)
       (activate-operational-configuration! connection (snapshot config-json))
       (check-equal?
        (for/list ([event-json
                    (in-list
                     (db:query-list
                      connection
                      "SELECT event_json FROM security_audit_events ORDER BY sequence"))])
          (hash-ref
           (decode-security-audit-event-json 'operator.created event-json)
           'operator_id))
        '("cashier-alice" "cashier-bob" "cashier-old"))
       (activate-operational-configuration! connection (snapshot config-json))
       (check-equal?
        (db:query-value
         connection
         "SELECT COUNT(*) FROM security_audit_events WHERE event_type = 'operator.created'")
        3)
       (check-true
        (security-audit-ledger-valid?
         (verify-security-audit-ledger connection))))))

  (test-case "single stub and existing principal keep distinct audit behavior"
    (call-with-database
     (lambda (connection)
       (activate-operational-configuration!
        connection (snapshot replacement-json))
       (check-equal?
        (db:query-value
         connection
         "SELECT COUNT(*) FROM security_audit_events WHERE event_type = 'operator.created'")
        1)
       (db:query-exec
        connection
        "UPDATE operator_roles SET role = 'manager' WHERE operator_id = 'cashier-alice'")
       (activate-operational-configuration!
        connection (snapshot security-seam-replacement-json))
       (check-equal?
        (db:query-list
         connection
         "SELECT event_json FROM security_audit_events WHERE event_type = 'operator.created' ORDER BY sequence")
        (list
         "{\"operator_id\":\"cashier-alice\",\"role\":\"cashier\"}"
         "{\"operator_id\":\"cashier-new\",\"role\":\"cashier\"}"))
       (check-equal?
        (db:query-value
         connection
         "SELECT role FROM operator_roles WHERE operator_id = 'cashier-alice'")
        "manager"))))

  (test-case "configuration audit failure rolls back all stubs and snapshot state"
    (call-with-database
     (lambda (connection)
       (define appends (box 0))
       (check-exn
        exn:fail?
        (lambda ()
          (activate-operational-configuration!
           connection (snapshot config-json)
           #:audit-append!
           (lambda (writer event)
             (append-security-audit-event!/in-transaction!
              writer event
              #:source-kind 'root_cli
              #:source-instance-id "audit_root_cli_rollback"
              #:occurred-at-epoch-ms 100)
             (set-box! appends (add1 (unbox appends)))
             (when (= (unbox appends) 2)
               (error 'test "injected failure after second audit insert"))))))
       (check-equal? (unbox appends) 2)
       (for ([table '(operators operator_roles cashiers
                     register_configuration security_audit_events)])
         (check-equal?
          (db:query-value connection (format "SELECT COUNT(*) FROM ~a" table))
          0))
       (activate-operational-configuration! connection (snapshot config-json))
       (check-equal?
        (db:query-list
         connection
         "SELECT sequence FROM security_audit_events ORDER BY sequence")
        '(1 2 3))
       (check-true
        (security-audit-ledger-valid?
         (verify-security-audit-ledger connection))))))

  (test-case "unconfigured unknown and inactive open attempts reject safely"
    (call-with-database
     (lambda (connection)
       (define service (make-service connection '(1000) '("unused")))
       (define unconfigured
         (register-operations-open-shift service "cashier-alice" (money 0)))
       (check-equal? (register-shift-open-rejected-code unconfigured)
                     'register-not-configured)
       (activate-operational-configuration! connection (snapshot config-json))
       (check-equal?
        (register-shift-open-rejected-code
         (register-operations-open-shift service "cashier-missing" (money 0)))
        'cashier-not-found)
       (check-equal?
        (register-shift-open-rejected-code
         (register-operations-open-shift service "cashier-old" (money 0)))
        'cashier-inactive))))

  (test-case "open is same-cashier idempotent and different-cashier exclusive"
    (call-with-database
     (lambda (connection)
       (activate-operational-configuration! connection (snapshot config-json))
       (define service (make-service connection '(1000) '("shift_exact")))
       (define first
         (register-operations-open-shift service "cashier-alice" (money 0)))
       (define repeated
         (register-operations-open-shift service "cashier-alice" (money 999)))
       (check-pred register-shift-opened? repeated)
       (check-equal? (register-shift-opened-shift repeated)
                     (register-shift-opened-shift first))
       (define conflict
         (register-operations-open-shift service "cashier-bob" (money 0)))
       (check-pred register-shift-open-rejected? conflict)
       (check-equal? (register-shift-open-rejected-code conflict)
                     'shift-already-open)
       (check-equal?
        (db:query-value connection "SELECT COUNT(*) FROM register_shifts")
        1)
       (check-equal?
        (db:query-value connection
                        "SELECT COUNT(*) FROM security_audit_events WHERE event_type = 'shift.opened'")
        1))))

  (test-case "close is exact repeatable and refuses an active transaction"
    (call-with-database
     (lambda (connection)
       (activate-operational-configuration! connection (snapshot config-json))
       (define service
         (make-service connection '(1000 2000) '("shift_close")))
       (register-operations-open-shift service "cashier-alice" (money 0))
       (db:query-exec
        connection
        "UPDATE register_shifts SET active_transaction_id = 'txn-active' WHERE shift_id = 'shift_close'")
       (define blocked
         (register-operations-close-shift service "shift_close" (money 0)))
       (check-pred register-shift-close-rejected? blocked)
       (check-equal? (register-shift-close-rejected-code blocked)
                     'shift-has-active-transaction)
       (db:query-exec
        connection
        "UPDATE register_shifts SET active_transaction_id = NULL WHERE shift_id = 'shift_close'")
       (define closed
         (register-operations-close-shift service "shift_close" (money 0)))
       (check-pred register-shift-closed? closed)
       (check-equal?
        (register-shift-closed-at-epoch-ms
         (register-shift-closed-shift closed))
        2000)
       (define repeated
         (register-operations-close-shift service "shift_close" (money 5)))
       (check-pred register-shift-closed? repeated)
       (check-equal? (register-shift-closed-shift repeated)
                     (register-shift-closed-shift closed))
       (check-equal?
        (db:query-value connection
                        "SELECT COUNT(*) FROM security_audit_events WHERE event_type = 'shift.closed'")
        1)
       (check-equal?
        (register-shift-close-rejected-code
         (register-operations-close-shift service "missing" (money 0)))
        'shift-not-found))))

  (test-case "shift open and close recovery after reconnect never duplicate audit or cash state"
    (define directory (make-temporary-file "shift-audit-retry-~a" 'directory))
    (define database-path (build-path directory "pos.db"))
    (dynamic-wind
      void
      (lambda ()
        (define initial-connection
          (open-pos-sqlite-connection database-path 'create))
        (migrate-pos-database! initial-connection)
        (db:disconnect initial-connection)
        (define first-connection
          (open-pos-sqlite-connection database-path 'read/write))
        (dynamic-wind
          void
          (lambda ()
            (activate-operational-configuration!
             first-connection (snapshot config-json))
            (define first-service
              (make-service first-connection '(1000) '("shift_reconnect")))
            (define opened
              (register-operations-open-shift
               first-service "cashier-alice" (money 500)))
            (check-pred register-shift-opened? opened)
            (check-pred
             register-shift-opened?
             (register-operations-open-shift
              first-service "cashier-alice" (money 999))))
          (lambda () (db:disconnect first-connection)))
        (define second-connection
          (open-pos-sqlite-connection database-path 'read/write))
        (dynamic-wind
          void
          (lambda ()
            (define second-service
              (make-service second-connection '(2000) '("unused")))
            (check-pred
             register-shift-opened?
             (register-operations-open-shift
              second-service "cashier-alice" (money 1234)))
            (check-pred
             register-shift-closed?
             (register-operations-close-shift
              second-service "shift_reconnect" (money 500)))
            (check-pred
             register-shift-closed?
             (register-operations-close-shift
              second-service "shift_reconnect" (money 999))))
          (lambda () (db:disconnect second-connection)))
        (define third-connection
          (open-pos-sqlite-connection database-path 'read/write))
        (dynamic-wind
          void
          (lambda ()
            (define third-service (make-service third-connection '() '()))
            (check-pred
             register-shift-closed?
             (register-operations-close-shift
              third-service "shift_reconnect" (money 999)))
            (for ([table '(shift_cash_movements shift_cash_reconciliations)])
              (check-equal?
               (db:query-value
                third-connection (format "SELECT COUNT(*) FROM ~a" table))
               1))
            (for ([kind '("shift.opened" "shift.closed")])
              (check-equal?
               (db:query-value
                third-connection
                "SELECT COUNT(*) FROM security_audit_events WHERE event_type = ?"
                kind)
               1))
            (check-true
             (security-audit-ledger-valid?
              (verify-security-audit-ledger third-connection))))
          (lambda () (db:disconnect third-connection))))
      (lambda () (delete-directory/files directory))))

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
       (register-operations-open-shift service "cashier-alice" (money 0))
       (define active (register-operations-load-context service))
       (check-true (register-context-configured? active))
       (check-equal?
        (register-identity-display-name (register-context-register active))
        "Front Register 1")
       (check-equal?
        (register-shift-shift-id (register-context-active-shift active))
        "shift_context")))))
