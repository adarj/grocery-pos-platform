#lang racket

(require (prefix-in db: db)
         "../domain/money.rkt"
         "../domain/shift-cash-accountability.rkt"
         "../domain/transaction.rkt"
         (prefix-in op: "../domain/transaction-operational-context.rkt")
         "sqlite-transaction-event-store.rkt")

(provide record-opening-float/in-transaction!
         record-completed-cash-sale/in-transaction!
         record-shift-cash-reconciliation/in-transaction!
         load-shift-cash-summary)

(struct persisted-cash-movement
  (sequence type amount transaction-id recorded-at-epoch-ms)
  #:transparent)

(define (check-connection who connection)
  (unless (db:connection? connection)
    (raise-argument-error who "connection?" connection)))

(define (check-owned-transaction who connection)
  (check-connection who connection)
  (unless (db:in-transaction? connection)
    (raise-arguments-error
     who
     "must run inside a caller-owned SQLite transaction"
     "connection"
     connection)))

(define (check-non-empty-string who value)
  (unless (and (string? value) (positive? (string-length value)))
    (raise-argument-error who "non-empty-string?" value)))

(define (check-epoch-ms who value)
  (unless (and (exact-integer? value) (>= value 0))
    (raise-argument-error who "exact-nonnegative-integer?" value)))

(define (record-opening-float/in-transaction!
         connection shift-id opening-cash opened-at-epoch-ms)
  (define who 'record-opening-float/in-transaction!)
  (check-owned-transaction who connection)
  (check-non-empty-string who shift-id)
  (unless (money? opening-cash)
    (raise-argument-error who "money?" opening-cash))
  (check-epoch-ms who opened-at-epoch-ms)
  (db:query-exec
   connection
   #<<SQL
INSERT INTO shift_cash_movements
  (shift_id, movement_sequence, movement_type, amount_minor_units,
   transaction_id, recorded_at_epoch_ms)
VALUES (?, 1, 'opening_float', ?, NULL, ?)
SQL
   shift-id
   (money-minor-units opening-cash)
   opened-at-epoch-ms)
  (void))

(define (record-completed-cash-sale/in-transaction!
         connection
         shift-id
         transaction-id
         transaction-total
         completed-at-epoch-ms)
  (define who 'record-completed-cash-sale/in-transaction!)
  (check-owned-transaction who connection)
  (check-non-empty-string who shift-id)
  (check-non-empty-string who transaction-id)
  (unless (money? transaction-total)
    (raise-argument-error who "money?" transaction-total))
  (check-epoch-ms who completed-at-epoch-ms)
  (define next-sequence
    (add1
     (db:query-value
      connection
      #<<SQL
SELECT COALESCE(MAX(movement_sequence), 0)
FROM shift_cash_movements
WHERE shift_id = ?
SQL
      shift-id)))
  (when (= next-sequence 1)
    (error who "tracked shift is missing its opening cash movement"))
  (db:query-exec
   connection
   #<<SQL
INSERT INTO shift_cash_movements
  (shift_id, movement_sequence, movement_type, amount_minor_units,
   transaction_id, recorded_at_epoch_ms)
VALUES (?, ?, 'cash_sale', ?, ?, ?)
SQL
   shift-id
   next-sequence
   (money-minor-units transaction-total)
   transaction-id
   completed-at-epoch-ms)
  (void))

(define (record-shift-cash-reconciliation/in-transaction!
         connection shift-id expected-cash counted-cash)
  (define who 'record-shift-cash-reconciliation/in-transaction!)
  (check-owned-transaction who connection)
  (check-non-empty-string who shift-id)
  (unless (money? expected-cash)
    (raise-argument-error who "money?" expected-cash))
  (unless (money? counted-cash)
    (raise-argument-error who "money?" counted-cash))
  (define expected (money-minor-units expected-cash))
  (define counted (money-minor-units counted-cash))
  (db:query-exec
   connection
   #<<SQL
INSERT INTO shift_cash_reconciliations
  (shift_id, expected_cash_minor_units, counted_cash_minor_units,
   over_short_minor_units)
VALUES (?, ?, ?, ?)
SQL
   shift-id expected counted (- counted expected))
  (void))

(define (row->movement row)
  (persisted-cash-movement
   (vector-ref row 0)
   (vector-ref row 1)
   (vector-ref row 2)
   (if (db:sql-null? (vector-ref row 3)) #f (vector-ref row 3))
   (vector-ref row 4)))

(define (load-movements connection shift-id)
  (for/list ([row
              (in-list
               (db:query-rows
                connection
                #<<SQL
SELECT movement_sequence, movement_type, amount_minor_units,
       transaction_id, recorded_at_epoch_ms
FROM shift_cash_movements
WHERE shift_id = ?
ORDER BY movement_sequence
SQL
                shift-id))])
    (row->movement row)))

(define (validate-completed-sale-movement! connection shift-id movement)
  (define transaction-id
    (persisted-cash-movement-transaction-id movement))
  (define journal (load-transaction-events connection transaction-id))
  (unless (journal-load-succeeded? journal)
    (error 'load-shift-cash-summary
           "cash-sale transaction journal could not be recovered"))
  (define replay (replay-transaction (journal-load-succeeded-events journal)))
  (unless (replay-succeeded? replay)
    (error 'load-shift-cash-summary
           "cash-sale transaction could not be replayed"))
  (define transaction (replay-succeeded-transaction replay))
  (define context (transaction-operational-context transaction))
  (unless (and (eq? (transaction-status transaction) 'completed)
               context
               (string=?
                (op:transaction-operational-context-shift-id context)
                shift-id)
               (= (money-minor-units (transaction-total transaction))
                  (persisted-cash-movement-amount movement))
               (equal? (transaction-completed-at-epoch-ms transaction)
                       (persisted-cash-movement-recorded-at-epoch-ms movement)))
    (error 'load-shift-cash-summary
           "cash-sale movement disagrees with authoritative transaction history")))

(define (validate-and-summarize-movements connection shift-id movements)
  (unless (pair? movements)
    (error 'load-shift-cash-summary
           "tracked open shift is missing its opening cash movement"))
  (for ([movement (in-list movements)] [expected-sequence (in-naturals 1)])
    (unless (= (persisted-cash-movement-sequence movement) expected-sequence)
      (error 'load-shift-cash-summary
             "shift cash movement sequence is not contiguous from one")))
  (define opening (first movements))
  (unless (and (string=? (persisted-cash-movement-type opening)
                         "opening_float")
               (not (persisted-cash-movement-transaction-id opening)))
    (error 'load-shift-cash-summary
           "first shift cash movement is not a valid opening float"))
  (define sale-movements (rest movements))
  (for ([movement (in-list sale-movements)])
    (unless (and (string=? (persisted-cash-movement-type movement)
                           "cash_sale")
                 (persisted-cash-movement-transaction-id movement))
      (error 'load-shift-cash-summary
             "shift cash ledger contains an unsupported movement"))
    (validate-completed-sale-movement! connection shift-id movement))
  (values
   (money (persisted-cash-movement-amount opening))
   (length sale-movements)
   (money
    (for/sum ([movement (in-list sale-movements)])
      (persisted-cash-movement-amount movement)))))

(define (load-shift-cash-summary connection shift-id)
  (define who 'load-shift-cash-summary)
  (check-connection who connection)
  (check-non-empty-string who shift-id)
  (define shift-row
    (db:query-maybe-row
     connection
     "SELECT closed_at_epoch_ms FROM register_shifts WHERE shift_id = ?"
     shift-id))
  (cond
    [(not shift-row) (shift-cash-summary-not-found shift-id)]
    [else
     (define closed? (not (db:sql-null? (vector-ref shift-row 0))))
     (define movements (load-movements connection shift-id))
     (cond
       [(null? movements)
        (if closed?
            (shift-cash-summary-unavailable shift-id)
            (error who "open shift is missing cash-accountability facts"))]
       [else
        (define-values (opening sale-count sales)
          (validate-and-summarize-movements connection shift-id movements))
        (define expected
          (money (+ (money-minor-units opening)
                    (money-minor-units sales))))
        (define reconciliation
          (db:query-maybe-row
           connection
           #<<SQL
SELECT expected_cash_minor_units, counted_cash_minor_units,
       over_short_minor_units
FROM shift_cash_reconciliations
WHERE shift_id = ?
SQL
           shift-id))
        (cond
          [(and (not closed?) reconciliation)
           (error who "open shift has an impossible cash reconciliation")]
          [(and closed? (not reconciliation))
           (error who "tracked closed shift is missing cash reconciliation")]
          [else
           (define counted
             (and reconciliation (money (vector-ref reconciliation 1))))
           (define over-short
             (and reconciliation (vector-ref reconciliation 2)))
           (when reconciliation
             (unless (= (vector-ref reconciliation 0)
                        (money-minor-units expected))
               (error who
                      "stored reconciliation expected cash disagrees with ledger")))
           (shift-cash-summary-found
            (shift-cash-summary
             shift-id
             (if closed? 'closed 'open)
             opening
             sale-count
             sales
             expected
             counted
             over-short))])])]))
