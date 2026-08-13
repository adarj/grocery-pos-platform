#lang racket

(require "money.rkt")

(provide (struct-out catalog-item))

(struct catalog-item (barcode description unit-price)
  #:transparent
  #:guard
  (lambda (barcode description unit-price type-name)
    (unless (string? barcode)
      (raise-argument-error type-name "string?" barcode))
    (unless (string? description)
      (raise-argument-error type-name "string?" description))
    (unless (money? unit-price)
      (raise-argument-error type-name "money?" unit-price))
    (values barcode description unit-price)))
