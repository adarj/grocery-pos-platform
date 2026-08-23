#lang racket

(require "money.rkt"
         "tax.rkt")

(provide transaction-event?
         (struct-out transaction-started)
         (struct-out sale-item-added)
         (struct-out taxed-sale-item-added)
         (struct-out sale-line-removed)
         (struct-out cash-tendered)
         (struct-out transaction-completed)
         (struct-out transaction-voided))

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

(struct taxed-sale-item-added transaction-event
  (barcode description unit-price tax-category-id tax-rate tax-amount)
  #:transparent
  #:guard
  (lambda (barcode
           description
           unit-price
           tax-category-id
           tax-rate
           tax-amount
           type-name)
    (unless (string? barcode)
      (raise-argument-error type-name "string?" barcode))
    (unless (string? description)
      (raise-argument-error type-name "string?" description))
    (unless (money? unit-price)
      (raise-argument-error type-name "money?" unit-price))
    (unless (and (string? tax-category-id)
                 (positive? (string-length tax-category-id)))
      (raise-argument-error type-name "non-empty string?" tax-category-id))
    (unless (tax-rate? tax-rate)
      (raise-argument-error type-name "tax-rate?" tax-rate))
    (unless (money? tax-amount)
      (raise-argument-error type-name "money?" tax-amount))
    (unless (equal? tax-amount (calculate-line-tax unit-price tax-rate))
      (raise-arguments-error
       type-name
       "tax amount does not match the Schema v2 line-tax calculation"
       "unit price" unit-price
       "tax rate" tax-rate
       "tax amount" tax-amount))
    (values (string->immutable-string barcode)
            (string->immutable-string description)
            unit-price
            (string->immutable-string tax-category-id)
            tax-rate
            tax-amount)))

(struct cash-tendered transaction-event (amount)
  #:transparent
  #:guard
  (lambda (amount type-name)
    (unless (money? amount)
      (raise-argument-error type-name "money?" amount))
    amount))

(struct sale-line-removed transaction-event (line-index)
  #:transparent
  #:guard
  (lambda (line-index type-name)
    (unless (and (exact-integer? line-index)
                 (>= line-index 0))
      (raise-argument-error
       type-name
       "exact nonnegative integer"
       line-index))
    line-index))

(struct transaction-completed transaction-event ()
  #:transparent)

(struct transaction-voided transaction-event ()
  #:transparent)
