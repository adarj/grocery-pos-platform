#lang racket

(require (prefix-in db: db)
         "../domain/transaction-command-actor-attribution.rkt")

(provide insert-transaction-command-actor-attribution!
         load-transaction-command-actor-attribution
         transaction-command-receipt-legacy-unattributed?)

(define (check-connection who connection)
  (unless (db:connection? connection)
    (raise-argument-error who "connection?" connection)))

(define (check-command-id who command-id)
  (unless (and (string? command-id) (positive? (string-length command-id)))
    (raise-argument-error who "non-empty string?" command-id)))

(define (insert-transaction-command-actor-attribution! connection attribution)
  (define who 'insert-transaction-command-actor-attribution!)
  (check-connection who connection)
  (unless (transaction-command-actor-attribution? attribution)
    (raise-argument-error
     who "transaction-command-actor-attribution?" attribution))
  (db:query-exec
   connection
   #<<SQL
INSERT INTO transaction_command_actor_attributions (command_id, operator_id)
VALUES (?, ?)
SQL
   (transaction-command-actor-attribution-command-id attribution)
   (transaction-command-actor-attribution-operator-id attribution))
  (unless (= (db:query-value connection "SELECT changes()") 1)
    (error who "actor attribution insert changed an unexpected row count"))
  (void))

(define (load-transaction-command-actor-attribution connection command-id)
  (define who 'load-transaction-command-actor-attribution)
  (check-connection who connection)
  (check-command-id who command-id)
  (define row
    (db:query-maybe-row
     connection
     #<<SQL
SELECT command_id, typeof(command_id), operator_id, typeof(operator_id)
FROM transaction_command_actor_attributions
WHERE command_id = ?
SQL
     command-id))
  (cond
    [(not row) #f]
    [(and (equal? (vector-ref row 1) "text")
          (string? (vector-ref row 0))
          (positive? (string-length (vector-ref row 0)))
          (equal? (vector-ref row 3) "text")
          (string? (vector-ref row 2))
          (positive? (string-length (vector-ref row 2))))
     (transaction-command-actor-attribution
      (vector-ref row 0) (vector-ref row 2))]
    [else
     (error who "stored command actor attribution is malformed")]))

(define (transaction-command-receipt-legacy-unattributed?
         connection command-id)
  (define who 'transaction-command-receipt-legacy-unattributed?)
  (check-connection who connection)
  (check-command-id who command-id)
  (= 1
     (db:query-value
      connection
      #<<SQL
SELECT EXISTS (
  SELECT 1
  FROM transaction_command_legacy_unattributed_receipts
  WHERE command_id = ?
)
SQL
      command-id)))
