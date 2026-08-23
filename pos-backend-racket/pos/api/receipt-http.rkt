#lang racket

(require json
         web-server/http
         "http-response.rkt"
         "../application/transaction-service.rkt"
         "../domain/canonical-receipt.rkt"
         "../domain/money.rkt"
         "../domain/tax.rkt")

(provide handle-receipt-query-request)

(define (internal-error-response)
  (api-error-response
   "internal_error"
   "An internal service error occurred."
   #:status 500
   #:status-message #"Internal Server Error"))

(define (transaction-recovery-failed-response)
  (api-error-response
   "transaction_recovery_failed"
   "Transaction state could not be recovered."
   #:status 500
   #:status-message #"Internal Server Error"))

(define (nullable-tax-category->jsexpr value)
  (if value value (json-null)))

(define (nullable-tax-rate->jsexpr value)
  (if value
      (tax-rate-millionths value)
      (json-null)))

(define (receipt-line->jsexpr line)
  (hasheq
   'barcode (canonical-receipt-line-barcode line)
   'description (canonical-receipt-line-description line)
   'unit_price_minor_units
   (money-minor-units (canonical-receipt-line-unit-price line))
   'tax_category_id
   (nullable-tax-category->jsexpr
    (canonical-receipt-line-tax-category-id line))
   'tax_rate_millionths
   (nullable-tax-rate->jsexpr
    (canonical-receipt-line-tax-rate line))
   'tax_amount_minor_units
   (money-minor-units (canonical-receipt-line-tax-amount line))))

(define (canonical-receipt->jsexpr receipt)
  (hasheq
   'schema_version 1
   'transaction_id (canonical-receipt-transaction-id receipt)
   'transaction_version
   (canonical-receipt-transaction-version receipt)
   'line_items
   (for/list ([line
               (in-list (canonical-receipt-line-items receipt))])
     (receipt-line->jsexpr line))
   'subtotal_minor_units
   (money-minor-units (canonical-receipt-subtotal receipt))
   'tax_minor_units
   (money-minor-units (canonical-receipt-tax receipt))
   'total_minor_units
   (money-minor-units (canonical-receipt-total receipt))
   'tendered_cash_minor_units
   (money-minor-units (canonical-receipt-tendered-cash receipt))
   'change_due_minor_units
   (money-minor-units (canonical-receipt-change-due receipt))))

(define (receipt-result-response result)
  (cond
    [(transaction-service-receipt-success? result)
     (json-response
      (hasheq
       'ok #t
       'receipt
       (canonical-receipt->jsexpr
        (transaction-service-receipt-success-receipt result))))]
    [(transaction-service-receipt-not-found? result)
     (api-error-response
      "transaction_not_found"
      "Transaction not found."
      #:status 404
      #:status-message #"Not Found")]
    [(transaction-service-receipt-not-available? result)
     (api-error-response
      "receipt_not_available"
      "Receipt is not available because the transaction is not completed."
      #:status 409
      #:status-message #"Conflict"
      #:reason "transaction_not_completed")]
    [(transaction-service-recovery-failed? result)
     (transaction-recovery-failed-response)]
    [else
     (error
      'receipt-result-response
      "unsupported receipt query result: ~e"
      result)]))

(define (handle-receipt-query-request transaction-service transaction-id)
  (with-handlers ([exn:fail? (lambda (_exception) (internal-error-response))])
    (receipt-result-response
     (transaction-service-load-canonical-receipt
      transaction-service
      transaction-id))))
