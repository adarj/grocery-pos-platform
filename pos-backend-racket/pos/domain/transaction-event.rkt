#lang racket

(require "money.rkt")

(provide transaction-event?
         (struct-out transaction-started)
         (struct-out sale-item-added)
         (struct-out cash-tendered)
         (struct-out transaction-completed))

(struct transaction-event ()
  #:transparent)

(struct transaction-started transaction-event (transaction-id)
  #:transparent
  #:guard
  (lambda (transaction-id type-name)
    (unless (string? transaction-id)
      (raise-argument-error type-name "string?" transaction-id))
    (string->immutable-string transaction-id)))

(struct sale-item-added transaction-event (barcode description unit-price)
  #:transparent
  #:guard
  (lambda (barcode description unit-price type-name)
    (unless (string? barcode)
      (raise-argument-error type-name "string?" barcode))
    (unless (string? description)
      (raise-argument-error type-name "string?" description))
    (unless (money? unit-price)
      (raise-argument-error type-name "money?" unit-price))
    (values (string->immutable-string barcode)
            (string->immutable-string description)
            unit-price)))

(struct cash-tendered transaction-event (amount)
  #:transparent
  #:guard
  (lambda (amount type-name)
    (unless (money? amount)
      (raise-argument-error type-name "money?" amount))
    amount))

(struct transaction-completed transaction-event ()
  #:transparent)
