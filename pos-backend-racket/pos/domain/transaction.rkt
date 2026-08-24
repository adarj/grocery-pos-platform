#lang racket

(require "catalog-item.rkt"
         "money.rkt"
         "tax.rkt"
         "transaction-event.rkt"
         "transaction-operational-context.rkt")

(provide start-transaction
         start-transaction-with-operational-context
         start-accepted?
         start-accepted-transaction
         start-accepted-events
         make-transaction
         transaction?
         transaction-id
         transaction-status
         transaction-line-items
         transaction-subtotal
         transaction-tax
         transaction-total
         transaction-tendered-cash
         transaction-change-due
         transaction-operational-context
         transaction-completed-at-epoch-ms
         transaction-voided-at-epoch-ms
         transaction-line-item?
         transaction-line-item-barcode
         transaction-line-item-description
         transaction-line-item-unit-price
         transaction-line-item-tax-category-id
         transaction-line-item-tax-rate
         transaction-line-item-tax-amount
         scan-barcode
         scan-accepted?
         scan-accepted-transaction
         scan-accepted-events
         scan-rejected?
         scan-rejected-code
         scan-rejected-transaction
         scan-rejected-events
         tender-cash
         tender-accepted?
         tender-accepted-transaction
         tender-accepted-events
         tender-rejected?
         tender-rejected-code
         tender-rejected-transaction
         tender-rejected-events
         remove-line-item
         removal-accepted?
         removal-accepted-transaction
         removal-accepted-events
         removal-rejected?
         removal-rejected-code
         removal-rejected-transaction
         removal-rejected-events
         complete-transaction
         completion-accepted?
         completion-accepted-transaction
         completion-accepted-events
         completion-rejected?
         completion-rejected-code
         completion-rejected-transaction
         completion-rejected-events
         void-transaction
         void-accepted?
         void-accepted-transaction
         void-accepted-events
         void-rejected?
         void-rejected-code
         void-rejected-transaction
         void-rejected-events
         apply-transaction-event
         event-applied?
         event-applied-transaction
         event-rejected?
         event-rejected-code
         event-rejected-transaction
         replay-transaction
         replay-succeeded?
         replay-succeeded-transaction
         replay-failed?
         replay-failed-event-index
         replay-failed-code
         replay-failed-transaction)

(struct transaction
  (id
   status
   line-items
   cash-tender
   operational-context
   completed-at-epoch-ms
   voided-at-epoch-ms)
  #:transparent)

(struct transaction-line-item
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

(struct cash-tender (amount)
  #:transparent)

(struct start-accepted (transaction events)
  #:transparent)

(struct scan-accepted (transaction events)
  #:transparent)

(struct scan-rejected (code transaction events)
  #:transparent)

(struct tender-accepted (transaction events)
  #:transparent)

(struct tender-rejected (code transaction events)
  #:transparent)

(struct removal-accepted (transaction events)
  #:transparent)

(struct removal-rejected (code transaction events)
  #:transparent)

(struct completion-accepted (transaction events)
  #:transparent)

(struct completion-rejected (code transaction events)
  #:transparent)

(struct void-accepted (transaction events)
  #:transparent)

(struct void-rejected (code transaction events)
  #:transparent)

(struct event-applied (transaction)
  #:transparent)

(struct event-rejected (code transaction)
  #:transparent)

(struct replay-succeeded (transaction)
  #:transparent)

(struct replay-failed (event-index code transaction)
  #:transparent)

(define (make-open-transaction id [operational-context #f])
  (transaction
   (string->immutable-string id)
   'open
   '()
   #f
   operational-context
   #f
   #f))

(define (add-sale-line-item current-transaction
                            barcode
                            description
                            unit-price
                            tax-category-id
                            tax-rate
                            tax-amount)
  (define line-item
    (transaction-line-item barcode
                           description
                           unit-price
                           tax-category-id
                           tax-rate
                           tax-amount))
  (struct-copy transaction current-transaction
               [line-items
                (append (transaction-line-items current-transaction)
                        (list line-item))]))

(define (record-sufficient-cash current-transaction amount)
  (struct-copy transaction current-transaction
               [status 'paid]
               [cash-tender (cash-tender amount)]))

(define (mark-transaction-completed current-transaction completed-at-epoch-ms)
  (struct-copy transaction current-transaction
               [status 'completed]
               [completed-at-epoch-ms completed-at-epoch-ms]))

(define (remove-transaction-line current-transaction line-index)
  (define line-items (transaction-line-items current-transaction))
  (struct-copy transaction current-transaction
               [line-items
                (append (take line-items line-index)
                        (drop line-items (add1 line-index)))]))

(define (mark-transaction-voided current-transaction voided-at-epoch-ms)
  (struct-copy transaction current-transaction
               [status 'voided]
               [voided-at-epoch-ms voided-at-epoch-ms]))

(define (transaction-open? current-transaction)
  (eq? (transaction-status current-transaction) 'open))

(define (decision-from-event current-transaction
                             event
                             make-accepted
                             make-rejected)
  (define application
    (apply-transaction-event current-transaction event))
  (cond
    [(event-applied? application)
     (make-accepted (event-applied-transaction application)
                    (list event))]
    [else
     (make-rejected (event-rejected-code application)
                    (event-rejected-transaction application)
                    '())]))

(define (start-transaction id)
  (unless (string? id)
    (raise-argument-error 'start-transaction "string?" id))
  (define event (transaction-started id))
  (define application (apply-transaction-event #f event))
  (start-accepted (event-applied-transaction application)
                  (list event)))

(define (start-transaction-with-operational-context id context)
  (unless (string? id)
    (raise-argument-error
     'start-transaction-with-operational-context "string?" id))
  (unless (transaction-operational-context? context)
    (raise-argument-error
     'start-transaction-with-operational-context
     "transaction-operational-context?"
     context))
  (define event (operational-transaction-started id context))
  (define application (apply-transaction-event #f event))
  (start-accepted (event-applied-transaction application)
                  (list event)))

(define (make-transaction id)
  (unless (string? id)
    (raise-argument-error 'make-transaction "string?" id))
  (start-accepted-transaction (start-transaction id)))

(define (transaction-subtotal current-transaction)
  (unless (transaction? current-transaction)
    (raise-argument-error
     'transaction-subtotal
     "transaction?"
     current-transaction))
  (money
   (for/sum ([line-item
              (in-list (transaction-line-items current-transaction))])
     (money-minor-units
      (transaction-line-item-unit-price line-item)))))

(define (transaction-total current-transaction)
  (unless (transaction? current-transaction)
    (raise-argument-error 'transaction-total "transaction?" current-transaction))
  (money
   (+ (money-minor-units (transaction-subtotal current-transaction))
      (money-minor-units (transaction-tax current-transaction)))))

(define (transaction-tax current-transaction)
  (unless (transaction? current-transaction)
    (raise-argument-error 'transaction-tax "transaction?" current-transaction))
  (money
   (for/sum ([line-item
              (in-list (transaction-line-items current-transaction))])
     (money-minor-units
      (transaction-line-item-tax-amount line-item)))))

(define (transaction-tendered-cash current-transaction)
  (unless (transaction? current-transaction)
    (raise-argument-error
     'transaction-tendered-cash
     "transaction?"
     current-transaction))
  (define tender (transaction-cash-tender current-transaction))
  (and tender (cash-tender-amount tender)))

(define (transaction-change-due current-transaction)
  (unless (transaction? current-transaction)
    (raise-argument-error
     'transaction-change-due
     "transaction?"
     current-transaction))
  (define tendered-cash (transaction-tendered-cash current-transaction))
  (and tendered-cash
       (money
        (- (money-minor-units tendered-cash)
           (money-minor-units (transaction-total current-transaction))))))

(define (scan-barcode current-transaction barcode catalog-lookup)
  (unless (transaction? current-transaction)
    (raise-argument-error 'scan-barcode "transaction?" current-transaction))
  (unless (procedure? catalog-lookup)
    (raise-argument-error 'scan-barcode "procedure?" catalog-lookup))

  (cond
    [(not (transaction-open? current-transaction))
     (scan-rejected 'invalid-transaction-state current-transaction '())]
    [else
     (define item (catalog-lookup barcode))
     (cond
       [(not item)
        (scan-rejected 'unknown-barcode current-transaction '())]
       [else
        (define event
          (taxed-sale-item-added
           (catalog-item-barcode item)
           (catalog-item-description item)
           (catalog-item-unit-price item)
           (catalog-item-tax-category-id item)
           (catalog-item-tax-rate item)
           (calculate-line-tax (catalog-item-unit-price item)
                               (catalog-item-tax-rate item))))
        (decision-from-event current-transaction
                             event
                             scan-accepted
                             scan-rejected)])]))

(define (tender-cash current-transaction amount)
  (unless (transaction? current-transaction)
    (raise-argument-error 'tender-cash "transaction?" current-transaction))
  (unless (money? amount)
    (raise-argument-error 'tender-cash "money?" amount))

  (decision-from-event current-transaction
                       (cash-tendered amount)
                       tender-accepted
                       tender-rejected))

(define (remove-line-item current-transaction line-index)
  (unless (transaction? current-transaction)
    (raise-argument-error
     'remove-line-item
     "transaction?"
     current-transaction))
  (unless (and (exact-integer? line-index)
               (>= line-index 0))
    (raise-argument-error
     'remove-line-item
     "exact nonnegative integer"
     line-index))

  (decision-from-event current-transaction
                       (sale-line-removed line-index)
                       removal-accepted
                       removal-rejected))

(define (complete-transaction current-transaction [completed-at-epoch-ms #f])
  (unless (transaction? current-transaction)
    (raise-argument-error
     'complete-transaction
     "transaction?"
     current-transaction))

  (when (and completed-at-epoch-ms
             (not (and (exact-integer? completed-at-epoch-ms)
                       (>= completed-at-epoch-ms 0))))
    (raise-argument-error
     'complete-transaction
     "(or/c #f exact-nonnegative-integer?)"
     completed-at-epoch-ms))
  (decision-from-event current-transaction
                       (if completed-at-epoch-ms
                           (timestamped-transaction-completed
                            completed-at-epoch-ms)
                           (transaction-completed))
                       completion-accepted
                       completion-rejected))

(define (void-transaction current-transaction [voided-at-epoch-ms #f])
  (unless (transaction? current-transaction)
    (raise-argument-error
     'void-transaction
     "transaction?"
     current-transaction))

  (when (and voided-at-epoch-ms
             (not (and (exact-integer? voided-at-epoch-ms)
                       (>= voided-at-epoch-ms 0))))
    (raise-argument-error
     'void-transaction
     "(or/c #f exact-nonnegative-integer?)"
     voided-at-epoch-ms))
  (decision-from-event current-transaction
                       (if voided-at-epoch-ms
                           (timestamped-transaction-voided voided-at-epoch-ms)
                           (transaction-voided))
                       void-accepted
                       void-rejected))

(define (apply-transaction-event current-transaction event)
  (unless (or (not current-transaction)
              (transaction? current-transaction))
    (raise-argument-error
     'apply-transaction-event
     "(or/c #f transaction?)"
     current-transaction))
  (unless (transaction-event? event)
    (raise-argument-error
     'apply-transaction-event
     "transaction-event?"
     event))

  (cond
    [(transaction-started? event)
     (if current-transaction
         (event-rejected
          'duplicate-transaction-started
          current-transaction)
         (event-applied
          (make-open-transaction
           (transaction-started-transaction-id event))))]
    [(operational-transaction-started? event)
     (if current-transaction
         (event-rejected
          'duplicate-transaction-started
          current-transaction)
         (event-applied
          (make-open-transaction
           (operational-transaction-started-transaction-id event)
           (operational-transaction-started-context event))))]
    [(not current-transaction)
     (event-rejected 'transaction-not-started #f)]
    [(sale-item-added? event)
     (if (transaction-open? current-transaction)
         (event-applied
          (add-sale-line-item
           current-transaction
           (sale-item-added-barcode event)
           (sale-item-added-description event)
           (sale-item-added-unit-price event)
           #f
           #f
           (money 0)))
         (event-rejected
          'invalid-transaction-state
          current-transaction))]
    [(taxed-sale-item-added? event)
     (if (transaction-open? current-transaction)
         (event-applied
          (add-sale-line-item
           current-transaction
           (taxed-sale-item-added-barcode event)
           (taxed-sale-item-added-description event)
           (taxed-sale-item-added-unit-price event)
           (taxed-sale-item-added-tax-category-id event)
           (taxed-sale-item-added-tax-rate event)
           (taxed-sale-item-added-tax-amount event)))
         (event-rejected
          'invalid-transaction-state
          current-transaction))]
    [(sale-line-removed? event)
     (define line-index (sale-line-removed-line-index event))
     (cond
       [(not (transaction-open? current-transaction))
        (event-rejected
         'invalid-transaction-state
         current-transaction)]
       [(>= line-index
            (length (transaction-line-items current-transaction)))
        (event-rejected 'line-item-not-found current-transaction)]
       [else
        (event-applied
         (remove-transaction-line current-transaction line-index))])]
    [(cash-tendered? event)
     (define amount (cash-tendered-amount event))
     (cond
       [(not (transaction-open? current-transaction))
        (event-rejected
         'invalid-transaction-state
         current-transaction)]
       [(empty? (transaction-line-items current-transaction))
        (event-rejected 'empty-transaction current-transaction)]
       [(< (money-minor-units amount)
           (money-minor-units
            (transaction-total current-transaction)))
        (event-rejected 'insufficient-tender current-transaction)]
       [else
        (event-applied
         (record-sufficient-cash current-transaction amount))])]
    [(transaction-completed? event)
     (if (eq? (transaction-status current-transaction) 'paid)
         (event-applied
          (mark-transaction-completed current-transaction #f))
         (event-rejected
          'invalid-transaction-state
          current-transaction))]
    [(timestamped-transaction-completed? event)
     (cond
       [(not (eq? (transaction-status current-transaction) 'paid))
        (event-rejected 'invalid-transaction-state current-transaction)]
       [(and (transaction-operational-context current-transaction)
             (< (timestamped-transaction-completed-completed-at-epoch-ms event)
                (transaction-operational-context-started-at-epoch-ms
                 (transaction-operational-context current-transaction))))
        (event-rejected 'invalid-operational-timestamp current-transaction)]
       [else
        (event-applied
         (mark-transaction-completed
          current-transaction
          (timestamped-transaction-completed-completed-at-epoch-ms event)))])]
    [(transaction-voided? event)
     (if (transaction-open? current-transaction)
         (event-applied
          (mark-transaction-voided current-transaction #f))
         (event-rejected
          'invalid-transaction-state
          current-transaction))]
    [(timestamped-transaction-voided? event)
     (cond
       [(not (transaction-open? current-transaction))
        (event-rejected 'invalid-transaction-state current-transaction)]
       [(and (transaction-operational-context current-transaction)
             (< (timestamped-transaction-voided-voided-at-epoch-ms event)
                (transaction-operational-context-started-at-epoch-ms
                 (transaction-operational-context current-transaction))))
        (event-rejected 'invalid-operational-timestamp current-transaction)]
       [else
        (event-applied
         (mark-transaction-voided
          current-transaction
          (timestamped-transaction-voided-voided-at-epoch-ms event)))])]))

(define (replay-transaction events)
  (unless (list? events)
    (raise-argument-error 'replay-transaction "list?" events))

  (let replay-next ([remaining-events events]
                    [current-transaction #f]
                    [event-index 0])
    (cond
      [(empty? remaining-events)
       (if current-transaction
           (replay-succeeded current-transaction)
           (replay-failed #f 'transaction-not-started #f))]
      [else
       (define result
         (apply-transaction-event current-transaction
                                  (first remaining-events)))
       (cond
         [(event-applied? result)
          (replay-next (rest remaining-events)
                       (event-applied-transaction result)
                       (add1 event-index))]
         [else
          (replay-failed event-index
                         (event-rejected-code result)
                         (event-rejected-transaction result))])])))
