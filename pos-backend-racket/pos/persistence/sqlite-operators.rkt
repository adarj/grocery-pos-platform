#lang racket

(require (prefix-in db: db)
         "../domain/operator-identity.rkt"
         "../domain/security-audit-event.rkt"
         "transaction-void-approval-store.rkt")

(provide (struct-out operator-create-succeeded)
         (struct-out operator-create-rejected)
         (struct-out operator-update-succeeded)
         (struct-out operator-update-rejected)
         (struct-out operator-pin-record)
         (struct-out operator-pin-store-succeeded)
         (struct-out operator-pin-store-rejected)
         (struct-out operator-pin-rotation-succeeded)
         (struct-out operator-pin-rotation-rejected)
         load-operator
         list-operators
         create-operator!
         set-operator-role!
         set-operator-active!
         load-operator-pin-record
         store-initial-operator-pin!
         rotate-operator-pin!)

(struct operator-create-succeeded (operator) #:transparent)
(struct operator-create-rejected (code) #:transparent)
(struct operator-update-succeeded (operator) #:transparent)
(struct operator-update-rejected (code) #:transparent)
;; This persistence-only representation must not be returned by ordinary
;; operator listing or UI-facing domain code.
(struct operator-pin-record (password-hash credential-revision) #:transparent)
(struct operator-pin-store-succeeded (credential-revision) #:transparent)
(struct operator-pin-store-rejected (code) #:transparent)
(struct operator-pin-rotation-succeeded (credential-revision) #:transparent)
(struct operator-pin-rotation-rejected (code) #:transparent)

(define maximum-sqlite-integer 9223372036854775807)

(define (check-connection who connection)
  (unless (db:connection? connection)
    (raise-argument-error who "connection?" connection)))

(define operator-select-sql
  #<<SQL
SELECT operator.operator_id,
       operator.display_name,
       operator.active,
       assignment.role,
       credential.credential_revision
FROM operators AS operator
JOIN operator_roles AS assignment
  ON assignment.operator_id = operator.operator_id
LEFT JOIN operator_pin_credentials AS credential
  ON credential.operator_id = operator.operator_id
SQL
  )

(define (row->operator row)
  (define revision
    (and (not (db:sql-null? (vector-ref row 4)))
         (vector-ref row 4)))
  (operator-identity
   (vector-ref row 0)
   (vector-ref row 1)
   (= (vector-ref row 2) 1)
   (or (parse-operator-role (vector-ref row 3))
       (error 'load-operator "stored operator role is invalid"))
   (if revision 'enrolled 'enrollment-required)
   revision))

(define (load-operator connection operator-id)
  (check-connection 'load-operator connection)
  (unless (and (string? operator-id) (positive? (string-length operator-id)))
    (raise-argument-error 'load-operator "non-empty-string?" operator-id))
  (define row
    (db:query-maybe-row
     connection
     (string-append operator-select-sql " WHERE operator.operator_id = ?")
     operator-id))
  (and row (row->operator row)))

(define (list-operators connection)
  (check-connection 'list-operators connection)
  (for/list ([row (in-list
                   (db:query-rows
                    connection
                    (string-append operator-select-sql
                                   " ORDER BY operator.operator_id")))])
    (row->operator row)))

(define (create-operator! connection operator-id display-name role
                          #:audit-append! audit-append!)
  (check-connection 'create-operator! connection)
  ;; Constructing the safe domain representation validates inputs before SQL.
  (define proposed
    (operator-identity
     operator-id display-name #t role 'enrollment-required #f))
  (db:call-with-transaction
   connection
   (lambda ()
     (if (db:query-maybe-value
          connection
          "SELECT 1 FROM operators WHERE operator_id = ?"
          operator-id)
         (operator-create-rejected 'operator-already-exists)
         (begin
           (db:query-exec
            connection
            #<<SQL
INSERT INTO operators (operator_id, display_name, active)
VALUES (?, ?, 1)
SQL
            operator-id display-name)
           (db:query-exec
            connection
            "INSERT INTO operator_roles (operator_id, role) VALUES (?, ?)"
            operator-id
            (operator-role->string role))
           (audit-append!
            connection (operator-created-event operator-id role))
           (operator-create-succeeded proposed))))
   #:option 'immediate))

(define (update-operator! who connection operator-id update! event-maker
                          audit-append!)
  (check-connection who connection)
  (unless (and (string? operator-id) (positive? (string-length operator-id)))
    (raise-argument-error who "non-empty-string?" operator-id))
  (db:call-with-transaction
   connection
   (lambda ()
     (define before (load-operator connection operator-id))
     (if (not before)
         (operator-update-rejected 'operator-not-found)
         (let* ([_updated (update!)]
                [after (load-operator connection operator-id)]
                [audit-event (event-maker before after)])
           (when audit-event
             (revoke-transaction-void-approval-grants-for-operator!/in-transaction!
              connection operator-id)
             (audit-append! connection audit-event))
           (operator-update-succeeded after))))
   #:option 'immediate))

(define (set-operator-role! connection operator-id role
                            #:audit-append! audit-append!)
  (unless (operator-role? role)
    (raise-argument-error 'set-operator-role! "operator-role?" role))
  (update-operator!
   'set-operator-role!
   connection
   operator-id
   (lambda ()
     (db:query-exec
      connection
      "UPDATE operator_roles SET role = ? WHERE operator_id = ?"
      (operator-role->string role)
      operator-id))
   (lambda (before after)
     (and (not (eq? (operator-identity-role before)
                    (operator-identity-role after)))
          (operator-role-changed-event
           operator-id (operator-identity-role before)
           (operator-identity-role after))))
   audit-append!))

(define (set-operator-active! connection operator-id active?
                              #:audit-append! audit-append!)
  (unless (boolean? active?)
    (raise-argument-error 'set-operator-active! "boolean?" active?))
  (update-operator!
   'set-operator-active!
   connection
   operator-id
   (lambda ()
     (db:query-exec
      connection
      "UPDATE operators SET active = ? WHERE operator_id = ?"
      (if active? 1 0)
      operator-id))
   (lambda (before after)
     (and (not (eq? (operator-identity-active? before)
                    (operator-identity-active? after)))
          (operator-active-changed-event
           operator-id (operator-identity-active? before)
           (operator-identity-active? after))))
   audit-append!))

(define (load-operator-pin-record connection operator-id)
  (check-connection 'load-operator-pin-record connection)
  (unless (and (string? operator-id) (positive? (string-length operator-id)))
    (raise-argument-error
     'load-operator-pin-record "non-empty-string?" operator-id))
  (define row
    (db:query-maybe-row
     connection
     #<<SQL
SELECT password_hash, credential_revision
FROM operator_pin_credentials
WHERE operator_id = ?
SQL
     operator-id))
  (and row (operator-pin-record (vector-ref row 0) (vector-ref row 1))))

(define (store-initial-operator-pin! connection operator-id password-hash
                                     #:audit-append! audit-append!)
  (check-connection 'store-initial-operator-pin! connection)
  (unless (and (string? operator-id) (positive? (string-length operator-id)))
    (raise-argument-error
     'store-initial-operator-pin! "non-empty-string?" operator-id))
  (unless (and (string? password-hash)
               (string-prefix? password-hash "$argon2id$"))
    (raise-argument-error
     'store-initial-operator-pin! "argon2id-password-hash-string?" password-hash))
  (db:call-with-transaction
   connection
   (lambda ()
     (cond
       [(not (db:query-maybe-value
              connection
              "SELECT 1 FROM operators WHERE operator_id = ?"
              operator-id))
        (operator-pin-store-rejected 'operator-not-found)]
       [(load-operator-pin-record connection operator-id)
        (operator-pin-store-rejected 'credential-already-enrolled)]
       [else
        (db:query-exec
         connection
         #<<SQL
INSERT INTO operator_pin_credentials
  (operator_id, password_hash, credential_revision)
VALUES (?, ?, 1)
SQL
         operator-id password-hash)
        (db:query-exec
         connection
         "DELETE FROM operator_login_throttle WHERE operator_id = ?"
         operator-id)
        (audit-append! connection (operator-pin-enrolled-event operator-id 1))
        (operator-pin-store-succeeded 1)]))
   #:option 'immediate))

;; Both authenticated self-change and root recovery use this final SQLite
;; arbiter. Argon2 hashing is performed by their callers before entry.
(define (rotate-operator-pin!
         connection operator-id expected-revision new-password-hash
         #:expected-password-hash [expected-password-hash #f]
         #:require-active? [require-active? #f]
         #:audit-event-maker audit-event-maker
         #:audit-append! audit-append!)
  (define who 'rotate-operator-pin!)
  (check-connection who connection)
  (unless (and (string? operator-id) (positive? (string-length operator-id)))
    (raise-argument-error who "non-empty-string?" operator-id))
  (unless (and (exact-integer? expected-revision)
               (>= expected-revision 1)
               (<= expected-revision maximum-sqlite-integer))
    (raise-argument-error who "positive SQLite integer?" expected-revision))
  (unless (and (string? new-password-hash)
               (string-prefix? new-password-hash "$argon2id$"))
    (raise-argument-error who "argon2id-password-hash-string?"
                          new-password-hash))
  (when expected-password-hash
    (unless (string? expected-password-hash)
      (raise-argument-error who "string?" expected-password-hash)))
  (unless (boolean? require-active?)
    (raise-argument-error who "boolean?" require-active?))
  (db:call-with-transaction
   connection
   (lambda ()
     (define operator (load-operator connection operator-id))
     (define credential (and operator
                             (load-operator-pin-record connection operator-id)))
     (cond
       [(not operator) (operator-pin-rotation-rejected 'operator-not-found)]
       [(not credential)
        (operator-pin-rotation-rejected 'credential-enrollment-required)]
       [(and require-active? (not (operator-identity-active? operator)))
        (operator-pin-rotation-rejected 'operator-inactive)]
       [(or (not (= (operator-pin-record-credential-revision credential)
                    expected-revision))
            (and expected-password-hash
                 (not (string=?
                       (operator-pin-record-password-hash credential)
                       expected-password-hash))))
        (operator-pin-rotation-rejected 'credential-concurrently-changed)]
       [(= expected-revision maximum-sqlite-integer)
        (operator-pin-rotation-rejected 'credential-revision-exhausted)]
       [else
        (define next-revision (add1 expected-revision))
        (db:query-exec
         connection
         #<<SQL
UPDATE operator_pin_credentials
SET password_hash = ?, credential_revision = ?
WHERE operator_id = ? AND credential_revision = ?
SQL
         new-password-hash next-revision operator-id expected-revision)
        (unless (= (db:query-value connection "SELECT changes()") 1)
          (error who "credential changed during writer transaction"))
        (db:query-exec
         connection
         "DELETE FROM operator_login_throttle WHERE operator_id = ?"
         operator-id)
        (revoke-transaction-void-approval-grants-for-operator!/in-transaction!
         connection operator-id)
        (audit-append!
         connection
         (audit-event-maker operator-id expected-revision next-revision))
        (operator-pin-rotation-succeeded next-revision)]))
   #:option 'immediate))
