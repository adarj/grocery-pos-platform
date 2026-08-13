#lang racket

(require "catalog-item.rkt"
         "money.rkt")

(provide make-transaction
         transaction?
         transaction-id
         transaction-status
         transaction-line-items
         transaction-subtotal
         transaction-line-item?
         transaction-line-item-barcode
         transaction-line-item-description
         transaction-line-item-unit-price
         scan-barcode
         scan-accepted?
         scan-accepted-transaction
         scan-rejected?
         scan-rejected-code
         scan-rejected-transaction)

(struct transaction (id status line-items)
  #:transparent)

(struct transaction-line-item (barcode description unit-price)
  #:transparent)

(struct scan-accepted (transaction)
  #:transparent)

(struct scan-rejected (code transaction)
  #:transparent)

(define (make-transaction id)
  (transaction id 'open '()))

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
                  (list line-item))))])]))

(module+ test-support
  (provide make-transaction-with-status-for-test)

  (define (make-transaction-with-status-for-test id status)
    (transaction id status '())))
