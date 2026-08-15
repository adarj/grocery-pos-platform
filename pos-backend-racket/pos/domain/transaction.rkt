#lang racket

(require "catalog-item.rkt"
         "money.rkt"
         "transaction-event.rkt")

(provide make-transaction
         transaction?
         transaction-id
         transaction-status
         transaction-line-items
         transaction-subtotal
         transaction-total
         transaction-tendered-cash
         transaction-change-due
         transaction-line-item?
         transaction-line-item-barcode
         transaction-line-item-description
         transaction-line-item-unit-price
         scan-barcode
         scan-accepted?
         scan-accepted-transaction
         scan-rejected?
         scan-rejected-code
         scan-rejected-transaction
         tender-cash
         tender-accepted?
         tender-accepted-transaction
         tender-rejected?
         tender-rejected-code
         tender-rejected-transaction
         complete-transaction
         completion-accepted?
         completion-accepted-transaction
         completion-rejected?
         completion-rejected-code
         completion-rejected-transaction
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

(struct transaction (id status line-items cash-tender)
  #:transparent)

(struct transaction-line-item (barcode description unit-price)
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

(struct cash-tender (amount)
  #:transparent)

(struct scan-accepted (transaction)
  #:transparent)

(struct scan-rejected (code transaction)
  #:transparent)

(struct tender-accepted (transaction)
  #:transparent)

(struct tender-rejected (code transaction)
  #:transparent)

(struct completion-accepted (transaction)
  #:transparent)

(struct completion-rejected (code transaction)
  #:transparent)

(struct event-applied (transaction)
  #:transparent)

(struct event-rejected (code transaction)
  #:transparent)

(struct replay-succeeded (transaction)
  #:transparent)

(struct replay-failed (event-index code transaction)
  #:transparent)

(define (make-open-transaction id)
  (transaction (string->immutable-string id) 'open '() #f))

(define (add-sale-line-item current-transaction barcode description unit-price)
  (define line-item
    (transaction-line-item barcode description unit-price))
  (struct-copy transaction current-transaction
               [line-items
                (append (transaction-line-items current-transaction)
                        (list line-item))]))

(define (record-sufficient-cash current-transaction amount)
  (struct-copy transaction current-transaction
               [status 'paid]
               [cash-tender (cash-tender amount)]))

(define (mark-transaction-completed current-transaction)
  (struct-copy transaction current-transaction
               [status 'completed]))

(define (make-transaction id)
  (unless (string? id)
    (raise-argument-error 'make-transaction "string?" id))
  (make-open-transaction id))

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
  (transaction-subtotal current-transaction))

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
    [(not (eq? (transaction-status current-transaction) 'open))
     (scan-rejected 'invalid-transaction-state current-transaction)]
    [else
     (define item (catalog-lookup barcode))
     (cond
       [(not item)
        (scan-rejected 'unknown-barcode current-transaction)]
       [else
        (scan-accepted
         (add-sale-line-item
          current-transaction
          (catalog-item-barcode item)
          (catalog-item-description item)
          (catalog-item-unit-price item)))])]))

(define (tender-cash current-transaction amount)
  (unless (transaction? current-transaction)
    (raise-argument-error 'tender-cash "transaction?" current-transaction))
  (unless (money? amount)
    (raise-argument-error 'tender-cash "money?" amount))

  (cond
    [(not (eq? (transaction-status current-transaction) 'open))
     (tender-rejected 'invalid-transaction-state current-transaction)]
    [(empty? (transaction-line-items current-transaction))
     (tender-rejected 'empty-transaction current-transaction)]
    [(< (money-minor-units amount)
        (money-minor-units (transaction-total current-transaction)))
     ;; v0 deliberately rejects partial cash rather than recording partial state.
     (tender-rejected 'insufficient-tender current-transaction)]
    [else
     (tender-accepted
      (record-sufficient-cash current-transaction amount))]))

(define (complete-transaction current-transaction)
  (unless (transaction? current-transaction)
    (raise-argument-error
     'complete-transaction
     "transaction?"
     current-transaction))

  (cond
    [(not (eq? (transaction-status current-transaction) 'paid))
     (completion-rejected
      'invalid-transaction-state
      current-transaction)]
    [else
     (completion-accepted
      (mark-transaction-completed current-transaction))]))

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
    [(not current-transaction)
     (event-rejected 'transaction-not-started #f)]
    [(sale-item-added? event)
     (if (eq? (transaction-status current-transaction) 'open)
         (event-applied
          (add-sale-line-item
           current-transaction
           (sale-item-added-barcode event)
           (sale-item-added-description event)
           (sale-item-added-unit-price event)))
         (event-rejected
          'invalid-transaction-state
          current-transaction))]
    [(cash-tendered? event)
     (define amount (cash-tendered-amount event))
     (cond
       [(not (eq? (transaction-status current-transaction) 'open))
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
          (mark-transaction-completed current-transaction))
         (event-rejected
          'invalid-transaction-state
          current-transaction))]))

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
