#lang racket

(require "catalog-item.rkt"
         "money.rkt")

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
         completion-rejected-transaction)

(struct transaction (id status line-items cash-tender)
  #:transparent)

(struct transaction-line-item (barcode description unit-price)
  #:transparent)

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

(define (make-transaction id)
  (transaction id 'open '() #f))

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
        (define line-item
          (transaction-line-item
           (catalog-item-barcode item)
           (catalog-item-description item)
           (catalog-item-unit-price item)))
        (scan-accepted
         (transaction
          (transaction-id current-transaction)
          (transaction-status current-transaction)
          (append (transaction-line-items current-transaction)
                  (list line-item))
          (transaction-cash-tender current-transaction)))])]))

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
      (transaction
       (transaction-id current-transaction)
       'paid
       (transaction-line-items current-transaction)
       (cash-tender amount)))]))

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
      (struct-copy transaction current-transaction
                   [status 'completed]))]))
