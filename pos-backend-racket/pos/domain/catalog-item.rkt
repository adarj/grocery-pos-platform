#lang racket

(require "money.rkt"
         "tax.rkt")

(provide (struct-out catalog-item))

(struct catalog-item (barcode description unit-price tax-category-id tax-rate)
  #:transparent
  #:guard
  (lambda (barcode description unit-price tax-category-id tax-rate type-name)
    (unless (string? barcode)
      (raise-argument-error type-name "string?" barcode))
    (unless (string? description)
      (raise-argument-error type-name "string?" description))
    (unless (money? unit-price)
      (raise-argument-error type-name "money?" unit-price))
    (unless (and (string? tax-category-id)
                 (positive? (string-length tax-category-id)))
      (raise-argument-error
       type-name "non-empty string?" tax-category-id))
    (unless (tax-rate? tax-rate)
      (raise-argument-error type-name "tax-rate?" tax-rate))
    (values (string->immutable-string barcode)
            (string->immutable-string description)
            unit-price
            (string->immutable-string tax-category-id)
            tax-rate)))
