#lang racket

(require "money.rkt"
         "register-operations.rkt"
         "tax.rkt"
         "transaction.rkt"
         (prefix-in op: "transaction-operational-context.rkt"))

(provide (struct-out canonical-receipt-line)
         (struct-out canonical-receipt)
         (struct-out operational-canonical-receipt)
         (struct-out receipt-created)
         (struct-out receipt-unavailable)
         derive-canonical-receipt)

(struct canonical-receipt-line
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
    (unless (or (not tax-category-id)
                (and (string? tax-category-id)
                     (positive? (string-length tax-category-id))))
      (raise-argument-error
       type-name "(or/c #f non-empty-string?)" tax-category-id))
    (unless (or (not tax-rate) (tax-rate? tax-rate))
      (raise-argument-error type-name "(or/c #f tax-rate?)" tax-rate))
    (unless (eq? (not tax-category-id) (not tax-rate))
      (raise-arguments-error
       type-name
       "tax category and rate must either both be present or both be absent"
       "tax category ID" tax-category-id
       "tax rate" tax-rate))
    (unless (money? tax-amount)
      (raise-argument-error type-name "money?" tax-amount))
    (values (string->immutable-string barcode)
            (string->immutable-string description)
            unit-price
            (and tax-category-id
                 (string->immutable-string tax-category-id))
            tax-rate
            tax-amount)))

(struct canonical-receipt
  (transaction-id
   transaction-version
   line-items
   subtotal
   tax
   total
   tendered-cash
   change-due)
  #:transparent
  #:guard
  (lambda (transaction-id
           transaction-version
           line-items
           subtotal
           tax
           total
           tendered-cash
           change-due
           type-name)
    (unless (and (string? transaction-id)
                 (positive? (string-length transaction-id)))
      (raise-argument-error type-name "non-empty-string?" transaction-id))
    (unless (and (exact-integer? transaction-version)
                 (>= transaction-version 0))
      (raise-argument-error
       type-name "exact-nonnegative-integer?" transaction-version))
    (unless (and (list? line-items)
                 (andmap canonical-receipt-line? line-items))
      (raise-argument-error
       type-name "(listof canonical-receipt-line?)" line-items))
    (for ([value (in-list (list subtotal
                                tax
                                total
                                tendered-cash
                                change-due))]
          [field-name (in-list '(subtotal
                                 tax
                                 total
                                 tendered-cash
                                 change-due))])
      (unless (money? value)
        (raise-arguments-error
         type-name
         "receipt monetary fields must be money values"
         (symbol->string field-name) value)))
    (values (string->immutable-string transaction-id)
            transaction-version
            line-items
            subtotal
            tax
            total
            tendered-cash
            change-due)))

(struct operational-canonical-receipt canonical-receipt
  (register cashier shift-id started-at-epoch-ms completed-at-epoch-ms)
  #:transparent
  #:guard
  (lambda (transaction-id
           transaction-version
           line-items
           subtotal
           tax
           total
           tendered-cash
           change-due
           register
           cashier
           shift-id
           started-at-epoch-ms
           completed-at-epoch-ms
           type-name)
    (unless (register-identity? register)
      (raise-argument-error type-name "register-identity?" register))
    (unless (cashier-identity? cashier)
      (raise-argument-error type-name "cashier-identity?" cashier))
    (unless (and (string? shift-id) (positive? (string-length shift-id)))
      (raise-argument-error type-name "non-empty-string?" shift-id))
    (unless (and (exact-integer? started-at-epoch-ms)
                 (>= started-at-epoch-ms 0))
      (raise-argument-error
       type-name "exact-nonnegative-integer?" started-at-epoch-ms))
    (unless (and (exact-integer? completed-at-epoch-ms)
                 (>= completed-at-epoch-ms started-at-epoch-ms))
      (raise-arguments-error
       type-name
       "completion time must be an exact epoch millisecond no earlier than start"
       "started at" started-at-epoch-ms
       "completed at" completed-at-epoch-ms))
    (values transaction-id
            transaction-version
            line-items
            subtotal
            tax
            total
            tendered-cash
            change-due
            register
            cashier
            (string->immutable-string shift-id)
            started-at-epoch-ms
            completed-at-epoch-ms)))

(struct receipt-created (receipt)
  #:transparent
  #:guard
  (lambda (receipt type-name)
    (unless (canonical-receipt? receipt)
      (raise-argument-error type-name "canonical-receipt?" receipt))
    receipt))

(struct receipt-unavailable (reason)
  #:transparent)

(define (transaction-line->receipt-line line-item)
  (canonical-receipt-line
   (transaction-line-item-barcode line-item)
   (transaction-line-item-description line-item)
   (transaction-line-item-unit-price line-item)
   (transaction-line-item-tax-category-id line-item)
   (transaction-line-item-tax-rate line-item)
   (transaction-line-item-tax-amount line-item)))

(define (derive-canonical-receipt transaction transaction-version)
  (unless (transaction? transaction)
    (raise-argument-error
     'derive-canonical-receipt "transaction?" transaction))
  (unless (and (exact-integer? transaction-version)
               (>= transaction-version 0))
    (raise-argument-error
     'derive-canonical-receipt
     "exact-nonnegative-integer?"
     transaction-version))

  (cond
    [(not (eq? (transaction-status transaction) 'completed))
     (receipt-unavailable 'transaction-not-completed)]
    [else
     ;; A completed transaction can only be reached from paid, so replay has
     ;; already established both values. Treat their absence as an impossible
     ;; projection rather than inventing receipt money.
     (define tendered-cash (transaction-tendered-cash transaction))
     (define change-due (transaction-change-due transaction))
     (unless (and tendered-cash change-due)
       (error
        'derive-canonical-receipt
        "completed transaction is missing tendered cash or change due"))
     (define context (transaction-operational-context transaction))
     (define completed-at (transaction-completed-at-epoch-ms transaction))
     (unless (eq? (not context) (not completed-at))
       (error
        'derive-canonical-receipt
        "completed transaction has inconsistent operational context and completion time"))
     (define lines
       (for/list ([line-item
                   (in-list (transaction-line-items transaction))])
         (transaction-line->receipt-line line-item)))
     (define common
       (list (transaction-id transaction)
             transaction-version
             lines
             (transaction-subtotal transaction)
             (transaction-tax transaction)
             (transaction-total transaction)
             tendered-cash
             change-due))
     (receipt-created
      (if context
          (apply
           operational-canonical-receipt
           (append
            common
            (list
             (register-identity
              (op:transaction-operational-context-register-id context)
              (op:transaction-operational-context-register-display-name
               context))
             (cashier-identity
              (op:transaction-operational-context-cashier-id context)
              (op:transaction-operational-context-cashier-display-name
               context))
             (op:transaction-operational-context-shift-id context)
             (op:transaction-operational-context-started-at-epoch-ms context)
             completed-at)))
          (apply canonical-receipt common))) ]))
