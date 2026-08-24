#lang racket

(provide (struct-out transaction-operational-context))

(define (immutable-non-empty-string type-name field-name value)
  (unless (and (string? value) (positive? (string-length value)))
    (raise-arguments-error
     type-name
     "operational identity fields must be non-empty strings"
     field-name
     value))
  (string->immutable-string value))

(struct transaction-operational-context
  (register-id
   register-display-name
   cashier-id
   cashier-display-name
   shift-id
   started-at-epoch-ms)
  #:transparent
  #:guard
  (lambda (register-id
           register-display-name
           cashier-id
           cashier-display-name
           shift-id
           started-at-epoch-ms
           type-name)
    (unless (and (exact-integer? started-at-epoch-ms)
                 (>= started-at-epoch-ms 0))
      (raise-argument-error
       type-name "exact-nonnegative-integer?" started-at-epoch-ms))
    (values
     (immutable-non-empty-string type-name "register ID" register-id)
     (immutable-non-empty-string
      type-name "register display name" register-display-name)
     (immutable-non-empty-string type-name "cashier ID" cashier-id)
     (immutable-non-empty-string
      type-name "cashier display name" cashier-display-name)
     (immutable-non-empty-string type-name "shift ID" shift-id)
     started-at-epoch-ms)))
