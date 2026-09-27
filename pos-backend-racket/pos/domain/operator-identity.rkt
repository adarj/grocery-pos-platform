#lang racket

(provide operator-roles
         operator-role?
         parse-operator-role
         operator-role->string
         (struct-out operator-identity))

(define operator-roles '(cashier supervisor manager))

(define (operator-role? value)
  (and (memq value operator-roles) #t))

(define (parse-operator-role value)
  (and (string? value)
       (for/first ([role (in-list operator-roles)]
                   #:when (string=? value (symbol->string role)))
         role)))

(define (operator-role->string role)
  (unless (operator-role? role)
    (raise-argument-error 'operator-role->string "operator-role?" role))
  (symbol->string role))

(define (immutable-non-empty-string type-name field-name value)
  (unless (and (string? value) (positive? (string-length value)))
    (raise-arguments-error
     type-name
     "operator identity fields must be non-empty strings"
     field-name
     value))
  (string->immutable-string value))

(struct operator-identity
  (operator-id display-name active? role credential-state credential-revision)
  #:transparent
  #:guard
  (lambda (operator-id
           display-name
           active?
           role
           credential-state
           credential-revision
           type-name)
    (unless (boolean? active?)
      (raise-argument-error type-name "boolean?" active?))
    (unless (operator-role? role)
      (raise-argument-error type-name "operator-role?" role))
    (unless (memq credential-state '(enrollment-required enrolled))
      (raise-argument-error
       type-name
       "(or/c 'enrollment-required 'enrolled)"
       credential-state))
    (unless
        (if (eq? credential-state 'enrolled)
            (and (exact-integer? credential-revision)
                 (positive? credential-revision))
            (not credential-revision))
      (raise-arguments-error
       type-name
       "credential state and revision disagree"
       "credential state"
       credential-state
       "credential revision"
       credential-revision))
    (values
     (immutable-non-empty-string type-name "operator ID" operator-id)
     (immutable-non-empty-string type-name "display name" display-name)
     active?
     role
     credential-state
     credential-revision)))
