#lang racket

(require (prefix-in db: db)
         "sqlite-auth-throttle.rkt"
         "sqlite-operators.rkt")

(provide (struct-out operator-login-confirmed)
         (struct-out operator-login-confirmation-rejected)
         confirm-operator-login!)

(struct operator-login-confirmed (operator) #:transparent)
(struct operator-login-confirmation-rejected () #:transparent)

;; This short writer transaction is the post-Argon race boundary. It confirms
;; that the exact verifier and revision which were checked are still current,
;; and clears throttle state atomically with that confirmation.
(define (confirm-operator-login! connection
                                 operator-id
                                 expected-password-hash
                                 expected-credential-revision)
  (unless (db:connection? connection)
    (raise-argument-error 'confirm-operator-login! "connection?" connection))
  (db:call-with-transaction
   connection
   (lambda ()
     (define still-current?
       (db:query-maybe-value
        connection
        #<<SQL
SELECT 1
FROM operators AS operator
JOIN operator_roles AS assignment
  ON assignment.operator_id = operator.operator_id
JOIN operator_pin_credentials AS credential
  ON credential.operator_id = operator.operator_id
WHERE operator.operator_id = ?
  AND operator.active = 1
  AND credential.password_hash = ?
  AND credential.credential_revision = ?
SQL
        operator-id
        expected-password-hash
        expected-credential-revision))
     (if still-current?
         (begin
           (clear-operator-login-throttle! connection operator-id)
           (operator-login-confirmed
            (load-operator connection operator-id)))
         (operator-login-confirmation-rejected)))
   #:option 'immediate))

