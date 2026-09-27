#lang racket

(provide (struct-out transaction-command-actor-attribution))

(define (immutable-non-empty-string type-name field-name value)
  (unless (and (string? value) (positive? (string-length value)))
    (raise-arguments-error
     type-name
     "actor attribution fields must be non-empty strings"
     field-name
     value))
  (string->immutable-string value))

(struct transaction-command-actor-attribution (command-id operator-id)
  #:transparent
  #:guard
  (lambda (command-id operator-id type-name)
    (values
     (immutable-non-empty-string type-name "command ID" command-id)
     (immutable-non-empty-string type-name "operator ID" operator-id))))
