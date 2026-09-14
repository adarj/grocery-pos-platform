#lang racket

(require (prefix-in db: db)
         "../domain/operator-identity.rkt")

(provide (struct-out operator-create-succeeded)
         (struct-out operator-create-rejected)
         (struct-out operator-update-succeeded)
         (struct-out operator-update-rejected)
         (struct-out operator-pin-record)
         (struct-out operator-pin-store-succeeded)
         (struct-out operator-pin-store-rejected)
         load-operator
         list-operators
         create-operator!
         set-operator-role!
         set-operator-active!
         load-operator-pin-record
         store-initial-operator-pin!)

(struct operator-create-succeeded (operator) #:transparent)
(struct operator-create-rejected (code) #:transparent)
(struct operator-update-succeeded (operator) #:transparent)
(struct operator-update-rejected (code) #:transparent)
;; This persistence-only representation must not be returned by ordinary
;; operator listing or UI-facing domain code.
(struct operator-pin-record (password-hash credential-revision) #:transparent)
(struct operator-pin-store-succeeded (credential-revision) #:transparent)
(struct operator-pin-store-rejected (code) #:transparent)

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

(define (create-operator! connection operator-id display-name role)
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
           (operator-create-succeeded proposed))))
   #:option 'immediate))

(define (update-operator! who connection operator-id update!)
  (check-connection who connection)
  (unless (and (string? operator-id) (positive? (string-length operator-id)))
    (raise-argument-error who "non-empty-string?" operator-id))
  (db:call-with-transaction
   connection
   (lambda ()
     (if (not (load-operator connection operator-id))
         (operator-update-rejected 'operator-not-found)
         (begin
           (update!)
           (operator-update-succeeded (load-operator connection operator-id)))))
   #:option 'immediate))

(define (set-operator-role! connection operator-id role)
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
      operator-id))))

(define (set-operator-active! connection operator-id active?)
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
      operator-id))))

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

(define (store-initial-operator-pin! connection operator-id password-hash)
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
        (operator-pin-store-succeeded 1)]))
   #:option 'immediate))
