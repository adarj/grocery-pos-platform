#lang racket

(require (prefix-in db: db)
         file/sha1
         racket/random
         "../domain/security-audit-event.rkt"
         "../domain/money.rkt"
         "../domain/register-operations.rkt"
         "../domain/shift-cash-accountability.rkt"
         "../domain/transaction-operational-context.rkt"
         "../security/authorization-policy.rkt"
         "operational-configuration-snapshot-codec.rkt"
         "security-audit-store.rkt"
         "sqlite-shift-cash-accountability.rkt")

(provide (struct-out operational-configuration-activation-succeeded)
         (struct-out operational-configuration-activation-rejected)
         activate-operational-configuration!
         load-register-context
         load-shift-by-id
         load-active-cashiers
         open-register-shift!
         close-register-shift!
         load-shift-cash-summary
         (struct-out shift-transaction-slot-claimed)
         (struct-out shift-transaction-slot-released)
         (struct-out shift-transaction-slot-rejected)
         (struct-out shift-transaction-slot-failed)
         claim-shift-transaction-slot/in-transaction!
         release-shift-transaction-slot/in-transaction!)

(struct operational-configuration-activation-succeeded
  (cashier-count active-cashier-count)
  #:transparent)
(struct operational-configuration-activation-rejected (code) #:transparent)
(struct shift-transaction-slot-claimed () #:transparent)
(struct shift-transaction-slot-released () #:transparent)
(struct shift-transaction-slot-rejected (code) #:transparent)
(struct shift-transaction-slot-failed (code message) #:transparent)

(define (check-connection who connection)
  (unless (db:connection? connection)
    (raise-argument-error who "connection?" connection)))

(define (check-procedure who value name)
  (unless (and (procedure? value) (procedure-arity-includes? value 0))
    (raise-arguments-error who "expected a zero-argument procedure" name value)))

(define (sql-null->false value)
  (if (db:sql-null? value) #f value))

(define shift-select-fields
  #<<SQL
shift_id,
register_id,
register_display_name,
cashier_id,
cashier_display_name,
opened_at_epoch_ms,
closed_at_epoch_ms,
active_transaction_id
SQL
  )

(define (row->shift row)
  (register-shift
   (vector-ref row 0)
   (vector-ref row 1)
   (vector-ref row 2)
   (vector-ref row 3)
   (vector-ref row 4)
   (vector-ref row 5)
   (sql-null->false (vector-ref row 6))
   (sql-null->false (vector-ref row 7))))

(define (load-shift-by-id connection shift-id)
  (define row
    (db:query-maybe-row
     connection
     (string-append
      "SELECT " shift-select-fields
      " FROM register_shifts WHERE shift_id = ?")
     shift-id))
  (and row (row->shift row)))

(define (load-open-shift connection register-id)
  (define rows
    (db:query-rows
     connection
     (string-append
      "SELECT " shift-select-fields
      " FROM register_shifts"
      " WHERE register_id = ? AND closed_at_epoch_ms IS NULL")
     register-id))
  (cond
    [(null? rows) #f]
    [(null? (rest rows)) (row->shift (first rows))]
    [else
     (error 'load-register-context
            "operational state contains multiple open shifts")]))

(define (activate-operational-configuration! connection snapshot
                                             #:audit-append! [audit-append! #f])
  (define who 'activate-operational-configuration!)
  (check-connection who connection)
  (unless (operational-configuration-snapshot? snapshot)
    (raise-argument-error who "operational-configuration-snapshot?" snapshot))
  ;; Provisioning and the root configuration CLI both create cashier/operator
  ;; stubs through this boundary. Give each activation its own non-secret root
  ;; source identity; callers may inject the append primitive for failure tests.
  (define source-instance-id
    (string-append "audit_root_cli_"
                   (bytes->hex-string (crypto-random-bytes 16))))
  (define effective-audit-append!
    (or audit-append!
        (lambda (writer-connection event)
          (append-security-audit-event!/in-transaction!
           writer-connection event
           #:source-kind 'root_cli
           #:source-instance-id source-instance-id
           #:occurred-at-epoch-ms
           (inexact->exact (floor (current-inexact-milliseconds)))))))
  (unless (and (procedure? effective-audit-append!)
               (procedure-arity-includes? effective-audit-append! 2))
    (raise-argument-error who "two-argument audit append procedure?"
                          effective-audit-append!))

  (db:call-with-transaction
   connection
   (lambda ()
     (cond
       [(positive?
         (db:query-value
          connection
          "SELECT COUNT(*) FROM register_shifts WHERE closed_at_epoch_ms IS NULL"))
        (operational-configuration-activation-rejected 'shift-open)]
       [else
        (db:query-exec connection "DELETE FROM cashiers")
        (db:query-exec connection "DELETE FROM register_configuration")
        (define register
          (operational-configuration-snapshot-register snapshot))
        (db:query-exec
         connection
         #<<SQL
INSERT INTO register_configuration (singleton_id, register_id, display_name)
VALUES (1, ?, ?)
SQL
         (operational-configuration-register-register-id register)
         (operational-configuration-register-display-name register))
        (for ([cashier
               (in-list
                (operational-configuration-snapshot-cashiers snapshot))])
          ;; Cashier snapshots are operational configuration, not the
          ;; security-principal authority. Create a same-ID stub only when the
          ;; operator is genuinely new; conflict handling deliberately leaves
          ;; an existing role, credential, identity activation state, and
          ;; display name untouched.
          (db:query-exec
           connection
           #<<SQL
INSERT INTO operators (operator_id, display_name, active)
VALUES (?, ?, ?)
ON CONFLICT(operator_id) DO NOTHING
SQL
           (operational-configuration-cashier-cashier-id cashier)
           (operational-configuration-cashier-display-name cashier)
           (if (operational-configuration-cashier-active? cashier) 1 0))
          (define created? (= (db:query-value connection "SELECT changes()") 1))
          (db:query-exec
           connection
           #<<SQL
INSERT INTO operator_roles (operator_id, role)
VALUES (?, 'cashier')
ON CONFLICT(operator_id) DO NOTHING
SQL
           (operational-configuration-cashier-cashier-id cashier))
          (when created?
            (effective-audit-append!
             connection
             (operator-created-event
              (operational-configuration-cashier-cashier-id cashier)
              'cashier)))
          (db:query-exec
           connection
           #<<SQL
INSERT INTO cashiers (cashier_id, display_name, active)
VALUES (?, ?, ?)
SQL
           (operational-configuration-cashier-cashier-id cashier)
           (operational-configuration-cashier-display-name cashier)
           (if (operational-configuration-cashier-active? cashier) 1 0)))
        (define expected-count
          (length (operational-configuration-snapshot-cashiers snapshot)))
        (define actual-count
          (db:query-value connection "SELECT COUNT(*) FROM cashiers"))
        (unless (= expected-count actual-count)
          (error who "cashier count changed during configuration activation"))
        (operational-configuration-activation-succeeded
         actual-count
         (db:query-value
          connection "SELECT COUNT(*) FROM cashiers WHERE active = 1"))]))
   #:option 'immediate))

(define (load-register-context connection)
  (define who 'load-register-context)
  (check-connection who connection)
  (define rows
    (db:query-rows
     connection
     "SELECT register_id, display_name FROM register_configuration WHERE singleton_id = 1"))
  (cond
    [(null? rows)
     (when (positive?
            (db:query-value
             connection
             "SELECT COUNT(*) FROM register_shifts WHERE closed_at_epoch_ms IS NULL"))
       (error who "an open shift exists without current register configuration"))
     (register-context #f #f #f)]
    [(null? (rest rows))
     (define row (first rows))
     (define register (register-identity (vector-ref row 0) (vector-ref row 1)))
     (register-context
      #t
      register
      (load-open-shift connection (register-identity-register-id register)))]
    [else (error who "multiple current register configuration rows exist")]))

(define (load-active-cashiers connection)
  (define who 'load-active-cashiers)
  (check-connection who connection)
  (for/list ([row
              (in-list
               (db:query-rows
                connection
                #<<SQL
SELECT cashier_id, display_name
FROM cashiers
WHERE active = 1
ORDER BY cashier_id
SQL
                ))])
    (cashier-identity (vector-ref row 0) (vector-ref row 1))))

(define (open-register-shift!
         connection cashier-id opening-cash current-epoch-ms generate-shift-id
         #:audit-append! audit-append!)
  (define who 'open-register-shift!)
  (check-connection who connection)
  (unless (and (string? cashier-id) (positive? (string-length cashier-id)))
    (raise-argument-error who "non-empty-string?" cashier-id))
  (unless (money? opening-cash)
    (raise-argument-error who "money?" opening-cash))
  (check-procedure who current-epoch-ms "current-epoch-ms")
  (check-procedure who generate-shift-id "generate-shift-id")
  (unless (and (procedure? audit-append!)
               (procedure-arity-includes? audit-append! 2))
    (raise-argument-error who "two-argument audit append procedure?"
                          audit-append!))

  (db:call-with-transaction
   connection
   (lambda ()
     (define context (load-register-context connection))
     (cond
       [(not (register-context-configured? context))
        (register-shift-open-rejected 'register-not-configured)]
       [(register-context-active-shift context)
        => (lambda (existing)
             (if (string=? (register-shift-cashier-id existing) cashier-id)
                 (let ([summary
                        (load-shift-cash-summary
                         connection (register-shift-shift-id existing))])
                   (unless (shift-cash-summary-found? summary)
                     (error who "existing open shift has no cash summary"))
                   (register-shift-opened
                    existing
                    (shift-cash-summary-found-summary summary)))
                 (register-shift-open-rejected 'shift-already-open)))]
       [else
        (define cashier-row
          (db:query-maybe-row
           connection
           "SELECT display_name, active FROM cashiers WHERE cashier_id = ?"
           cashier-id))
        (cond
          [(not cashier-row)
           (register-shift-open-rejected 'cashier-not-found)]
          [(not (= (vector-ref cashier-row 1) 1))
           (register-shift-open-rejected 'cashier-inactive)]
          [else
           (define shift-id (generate-shift-id))
           (define opened-at (current-epoch-ms))
           (unless (and (string? shift-id)
                        (positive? (string-length shift-id)))
             (error who "shift ID generator returned an invalid value"))
           (unless (and (exact-integer? opened-at) (>= opened-at 0))
             (error who "clock returned an invalid epoch millisecond value"))
           (define register (register-context-register context))
           (db:query-exec
            connection
            #<<SQL
INSERT INTO register_shifts
  (shift_id,
   register_id,
   register_display_name,
   cashier_id,
   cashier_display_name,
   opened_at_epoch_ms,
   closed_at_epoch_ms,
   active_transaction_id)
VALUES (?, ?, ?, ?, ?, ?, NULL, NULL)
SQL
            shift-id
            (register-identity-register-id register)
            (register-identity-display-name register)
            cashier-id
            (vector-ref cashier-row 0)
            opened-at)
           (record-opening-float/in-transaction!
            connection shift-id opening-cash opened-at)
           (audit-append! connection (shift-opened-event cashier-id shift-id))
           (define summary (load-shift-cash-summary connection shift-id))
           (unless (shift-cash-summary-found? summary)
             (error who "new shift opening cash could not be recovered"))
           (register-shift-opened
            (load-shift-by-id connection shift-id)
            (shift-cash-summary-found-summary summary))])]))
   #:option 'immediate))

(define (close-register-shift!
         connection shift-id counted-cash current-epoch-ms
         actor-operator-id actor-role
         #:audit-append! audit-append!)
  (define who 'close-register-shift!)
  (check-connection who connection)
  (unless (and (string? shift-id) (positive? (string-length shift-id)))
    (raise-argument-error who "non-empty-string?" shift-id))
  (unless (money? counted-cash)
    (raise-argument-error who "money?" counted-cash))
  (unless (and (string? actor-operator-id)
               (positive? (string-length actor-operator-id)))
    (raise-argument-error who "non-empty-string?" actor-operator-id))
  (check-procedure who current-epoch-ms "current-epoch-ms")
  (unless (and (procedure? audit-append!)
               (procedure-arity-includes? audit-append! 2))
    (raise-argument-error who "two-argument audit append procedure?"
                          audit-append!))

  (db:call-with-transaction
   connection
   (lambda ()
     (define shift (load-shift-by-id connection shift-id))
     (cond
       [(not shift) (register-shift-close-rejected 'shift-not-found)]
       [(not
         (if (operator-owns-resource?
              actor-operator-id (register-shift-cashier-id shift))
             (operator-role-authorized? actor-role 'shift.close.own)
             (and
              (operator-role-authorized? actor-role 'shift.close.any)
              (= 1
                 (db:query-value
                  connection
                  #<<SQL
SELECT COUNT(*)
FROM operators AS operator
JOIN operator_roles AS assignment
  ON assignment.operator_id = operator.operator_id
WHERE operator.operator_id = ?
  AND operator.active = 1
  AND assignment.role = 'manager'
SQL
                  actor-operator-id)))))
        (register-shift-close-rejected 'authorization-denied)]
       [(register-shift-closed-at-epoch-ms shift)
        (define summary (load-shift-cash-summary connection shift-id))
        (cond
          [(shift-cash-summary-found? summary)
           (register-shift-closed
            shift (shift-cash-summary-found-summary summary))]
          [(shift-cash-summary-unavailable? summary)
           (register-shift-close-rejected 'cash-accounting-unavailable)]
          [else (error who "closed shift cash summary could not be recovered")])]
       [(register-shift-active-transaction-id shift)
        (register-shift-close-rejected 'shift-has-active-transaction)]
       [else
        (define open-summary-result
          (load-shift-cash-summary connection shift-id))
        (unless (shift-cash-summary-found? open-summary-result)
          (error who "open shift cash summary could not be recovered"))
        (define open-summary
          (shift-cash-summary-found-summary open-summary-result))
        (define closed-at (current-epoch-ms))
        (unless (and (exact-integer? closed-at)
                     (>= closed-at (register-shift-opened-at-epoch-ms shift)))
          (error who "clock returned an invalid shift close time"))
        (record-shift-cash-reconciliation/in-transaction!
         connection
         shift-id
         (shift-cash-summary-expected-cash open-summary)
         counted-cash)
        (db:query-exec
         connection
         #<<SQL
UPDATE register_shifts
SET closed_at_epoch_ms = ?
WHERE shift_id = ?
  AND closed_at_epoch_ms IS NULL
  AND active_transaction_id IS NULL
SQL
         closed-at
         shift-id)
        (unless (= (db:query-value connection "SELECT changes()") 1)
          (error who "shift state changed during close"))
        (audit-append!
         connection
         (shift-closed-event
          actor-operator-id (register-shift-cashier-id shift) shift-id
          (not (operator-owns-resource?
                actor-operator-id (register-shift-cashier-id shift)))))
        (define closed-summary-result
          (load-shift-cash-summary connection shift-id))
        (unless (shift-cash-summary-found? closed-summary-result)
          (error who "closed cash reconciliation could not be recovered"))
        (register-shift-closed
         (load-shift-by-id connection shift-id)
         (shift-cash-summary-found-summary closed-summary-result))]))
   #:option 'immediate))

(define (ensure-owned-transaction who connection)
  (check-connection who connection)
  (unless (db:in-transaction? connection)
    (raise-arguments-error
     who
     "must run inside the transaction-command writer transaction"
     "connection"
     connection)))

(define (shift-matches-context? shift context)
  (and
   (string=? (register-shift-register-id shift)
             (transaction-operational-context-register-id context))
   (string=? (register-shift-register-display-name shift)
             (transaction-operational-context-register-display-name context))
   (string=? (register-shift-cashier-id shift)
             (transaction-operational-context-cashier-id context))
   (string=? (register-shift-cashier-display-name shift)
             (transaction-operational-context-cashier-display-name context))))

(define (claim-shift-transaction-slot/in-transaction!
         connection context transaction-id)
  (define who 'claim-shift-transaction-slot/in-transaction!)
  (ensure-owned-transaction who connection)
  (unless (transaction-operational-context? context)
    (raise-argument-error who "transaction-operational-context?" context))
  (unless (and (string? transaction-id)
               (positive? (string-length transaction-id)))
    (raise-argument-error who "non-empty-string?" transaction-id))
  (define shift
    (load-shift-by-id
     connection
     (transaction-operational-context-shift-id context)))
  (cond
    [(or (not shift) (register-shift-closed-at-epoch-ms shift))
     (shift-transaction-slot-rejected 'shift-required)]
    [(not (shift-matches-context? shift context))
     (shift-transaction-slot-failed
      'operational-state-corrupt
      "active shift identity differs from the transaction start decision")]
    [(register-shift-active-transaction-id shift)
     (shift-transaction-slot-rejected 'shift-has-active-transaction)]
    [else
     (db:query-exec
      connection
      #<<SQL
UPDATE register_shifts
SET active_transaction_id = ?
WHERE shift_id = ?
  AND closed_at_epoch_ms IS NULL
  AND active_transaction_id IS NULL
SQL
      transaction-id
      (transaction-operational-context-shift-id context))
     (if (= (db:query-value connection "SELECT changes()") 1)
         (shift-transaction-slot-claimed)
         (shift-transaction-slot-failed
          'operational-state-corrupt
          "shift slot changed unexpectedly inside the writer transaction"))]))

(define (release-shift-transaction-slot/in-transaction!
         connection context transaction-id)
  (define who 'release-shift-transaction-slot/in-transaction!)
  (ensure-owned-transaction who connection)
  (unless (transaction-operational-context? context)
    (raise-argument-error who "transaction-operational-context?" context))
  (unless (and (string? transaction-id)
               (positive? (string-length transaction-id)))
    (raise-argument-error who "non-empty-string?" transaction-id))
  (define shift
    (load-shift-by-id
     connection
     (transaction-operational-context-shift-id context)))
  (cond
    [(or (not shift)
         (register-shift-closed-at-epoch-ms shift)
         (not (shift-matches-context? shift context))
         (not (equal? (register-shift-active-transaction-id shift)
                      transaction-id)))
     (shift-transaction-slot-failed
      'operational-state-corrupt
      "shift does not point back to the context-bearing transaction")]
    [else
     (db:query-exec
      connection
      #<<SQL
UPDATE register_shifts
SET active_transaction_id = NULL
WHERE shift_id = ?
  AND closed_at_epoch_ms IS NULL
  AND active_transaction_id = ?
SQL
      (transaction-operational-context-shift-id context)
      transaction-id)
     (if (= (db:query-value connection "SELECT changes()") 1)
         (shift-transaction-slot-released)
         (shift-transaction-slot-failed
          'operational-state-corrupt
          "shift slot changed unexpectedly inside the writer transaction"))]))
