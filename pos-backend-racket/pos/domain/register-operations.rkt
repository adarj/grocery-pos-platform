#lang racket

(provide (struct-out register-identity)
         (struct-out cashier-identity)
         (struct-out register-shift)
         (struct-out register-context)
         (struct-out register-shift-opened)
         (struct-out register-shift-open-rejected)
         (struct-out register-shift-closed)
         (struct-out register-shift-close-rejected))

(define (non-empty-string? value)
  (and (string? value) (positive? (string-length value))))

(define (immutable-non-empty-string type-name field-name value)
  (unless (non-empty-string? value)
    (raise-arguments-error
     type-name
     "identity and display fields must be non-empty strings"
     field-name
     value))
  (string->immutable-string value))

(define (epoch-ms? value)
  (and (exact-integer? value) (>= value 0)))

(struct register-identity (register-id display-name)
  #:transparent
  #:guard
  (lambda (register-id display-name type-name)
    (values
     (immutable-non-empty-string type-name "register ID" register-id)
     (immutable-non-empty-string type-name "display name" display-name))))

(struct cashier-identity (cashier-id display-name)
  #:transparent
  #:guard
  (lambda (cashier-id display-name type-name)
    (values
     (immutable-non-empty-string type-name "cashier ID" cashier-id)
     (immutable-non-empty-string type-name "display name" display-name))))

(struct register-shift
  (shift-id
   register-id
   register-display-name
   cashier-id
   cashier-display-name
   opened-at-epoch-ms
   closed-at-epoch-ms
   active-transaction-id)
  #:transparent
  #:guard
  (lambda (shift-id
           register-id
           register-display-name
           cashier-id
           cashier-display-name
           opened-at-epoch-ms
           closed-at-epoch-ms
           active-transaction-id
           type-name)
    (unless (epoch-ms? opened-at-epoch-ms)
      (raise-argument-error
       type-name "exact-nonnegative-integer?" opened-at-epoch-ms))
    (unless (or (not closed-at-epoch-ms)
                (and (epoch-ms? closed-at-epoch-ms)
                     (>= closed-at-epoch-ms opened-at-epoch-ms)))
      (raise-arguments-error
       type-name
       "close time must be absent or no earlier than open time"
       "opened at" opened-at-epoch-ms
       "closed at" closed-at-epoch-ms))
    (unless (or (not active-transaction-id)
                (non-empty-string? active-transaction-id))
      (raise-argument-error
       type-name "(or/c #f non-empty-string?)" active-transaction-id))
    (when (and closed-at-epoch-ms active-transaction-id)
      (raise-arguments-error
       type-name
       "a closed shift cannot retain an active transaction"
       "active transaction ID"
       active-transaction-id))
    (values
     (immutable-non-empty-string type-name "shift ID" shift-id)
     (immutable-non-empty-string type-name "register ID" register-id)
     (immutable-non-empty-string
      type-name "register display name" register-display-name)
     (immutable-non-empty-string type-name "cashier ID" cashier-id)
     (immutable-non-empty-string
      type-name "cashier display name" cashier-display-name)
     opened-at-epoch-ms
     closed-at-epoch-ms
     (and active-transaction-id
          (string->immutable-string active-transaction-id)))))

(struct register-context (configured? register active-shift)
  #:transparent
  #:guard
  (lambda (configured? register active-shift type-name)
    (unless (boolean? configured?)
      (raise-argument-error type-name "boolean?" configured?))
    (unless (or (not register) (register-identity? register))
      (raise-argument-error type-name "(or/c #f register-identity?)" register))
    (unless (or (not active-shift) (register-shift? active-shift))
      (raise-argument-error
       type-name "(or/c #f register-shift?)" active-shift))
    (unless (eq? configured? (and register #t))
      (raise-arguments-error
       type-name
       "configured state and register identity disagree"
       "configured?" configured?
       "register" register))
    (when (and active-shift
               (or (not configured?)
                   (register-shift-closed-at-epoch-ms active-shift)
                   (not (string=?
                         (register-shift-register-id active-shift)
                         (register-identity-register-id register)))))
      (raise-arguments-error
       type-name
       "active shift is inconsistent with current register context"
       "active shift" active-shift))
    (values configured? register active-shift)))

(struct register-shift-opened (shift cash-summary) #:transparent)
(struct register-shift-open-rejected (code) #:transparent)
(struct register-shift-closed (shift cash-summary) #:transparent)
(struct register-shift-close-rejected (code) #:transparent)
