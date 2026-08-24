#lang racket

(require "money.rkt"
         "tax.rkt"
         "transaction-operational-context.rkt")

(provide transaction-event?
         transaction-start-event?
         transaction-start-event-transaction-id
         (struct-out transaction-started)
         (struct-out operational-transaction-started)
         (struct-out sale-item-added)
         (struct-out taxed-sale-item-added)
         (struct-out sale-line-removed)
         (struct-out cash-tendered)
         (struct-out transaction-completed)
         (struct-out timestamped-transaction-completed)
         (struct-out transaction-voided)
         (struct-out timestamped-transaction-voided))

(struct transaction-event ()
  #:transparent)

(struct transaction-started transaction-event (transaction-id)
  #:transparent
  #:guard
  (lambda (transaction-id type-name)
    (unless (string? transaction-id)
      (raise-argument-error type-name "string?" transaction-id))
    (string->immutable-string transaction-id)))

(struct operational-transaction-started transaction-event
  (transaction-id context)
  #:transparent
  #:guard
  (lambda (transaction-id context type-name)
    (unless (and (string? transaction-id)
                 (positive? (string-length transaction-id)))
      (raise-argument-error type-name "non-empty-string?" transaction-id))
    (unless (transaction-operational-context? context)
      (raise-argument-error
       type-name "transaction-operational-context?" context))
    (values (string->immutable-string transaction-id) context)))

(define (transaction-start-event? event)
  (or (transaction-started? event)
      (operational-transaction-started? event)))

(define (transaction-start-event-transaction-id event)
  (cond
    [(transaction-started? event)
     (transaction-started-transaction-id event)]
    [(operational-transaction-started? event)
     (operational-transaction-started-transaction-id event)]
    [else
     (raise-argument-error
      'transaction-start-event-transaction-id
      "transaction-start-event?"
      event)]))

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

(struct timestamped-transaction-completed transaction-event
  (completed-at-epoch-ms)
  #:transparent
  #:guard
  (lambda (completed-at-epoch-ms type-name)
    (unless (and (exact-integer? completed-at-epoch-ms)
                 (>= completed-at-epoch-ms 0))
      (raise-argument-error
       type-name "exact-nonnegative-integer?" completed-at-epoch-ms))
    completed-at-epoch-ms))

(struct transaction-voided transaction-event ()
  #:transparent)

(struct timestamped-transaction-voided transaction-event
  (voided-at-epoch-ms)
  #:transparent
  #:guard
  (lambda (voided-at-epoch-ms type-name)
    (unless (and (exact-integer? voided-at-epoch-ms)
                 (>= voided-at-epoch-ms 0))
      (raise-argument-error
       type-name "exact-nonnegative-integer?" voided-at-epoch-ms))
    voided-at-epoch-ms))
