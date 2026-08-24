#lang racket

(require json
         racket/string
         web-server/http
         "http-response.rkt"
         "../application/register-operations-service.rkt"
         "../domain/money.rkt"
         "../domain/register-operations.rkt"
         "../domain/shift-cash-accountability.rkt"
         "../persistence/strict-json.rkt")

(provide handle-register-context-request
         handle-active-cashiers-request
         handle-open-shift-request
         handle-close-shift-request
         handle-shift-cash-summary-request)

(define (internal-error-response)
  (api-error-response
   "internal_error"
   "An internal service error occurred."
   #:status 500
   #:status-message #"Internal Server Error"))

(define (json-content-type? req)
  (define content-type
    (headers-assq* #"Content-Type" (request-headers/raw req)))
  (and content-type
       (let ([parts
              (string-split
               (bytes->string/latin-1 (header-value content-type)) ";")])
         (and (pair? parts)
              (string=?
               (string-downcase (string-trim (first parts)))
               "application/json")))))

(define (register->jsexpr register)
  (hasheq 'register_id (register-identity-register-id register)
          'display_name (register-identity-display-name register)))

(define (cashier->jsexpr cashier)
  (hasheq 'cashier_id (cashier-identity-cashier-id cashier)
          'display_name (cashier-identity-display-name cashier)))

(define (shift->jsexpr shift)
  (hasheq
   'shift_id (register-shift-shift-id shift)
   'register_id (register-shift-register-id shift)
   'register_display_name (register-shift-register-display-name shift)
   'cashier_id (register-shift-cashier-id shift)
   'cashier_display_name (register-shift-cashier-display-name shift)
   'opened_at_epoch_ms (register-shift-opened-at-epoch-ms shift)
   'closed_at_epoch_ms
   (or (register-shift-closed-at-epoch-ms shift) (json-null))
   'active_transaction_id
   (or (register-shift-active-transaction-id shift) (json-null))))

(define (cash-summary->jsexpr summary)
  (hasheq
   'shift_id (shift-cash-summary-shift-id summary)
   'status (symbol->string (shift-cash-summary-status summary))
   'opening_cash_minor_units
   (money-minor-units (shift-cash-summary-opening-cash summary))
   'completed_cash_sale_count
   (shift-cash-summary-completed-cash-sale-count summary)
   'cash_sales_minor_units
   (money-minor-units (shift-cash-summary-cash-sales summary))
   'expected_cash_minor_units
   (money-minor-units (shift-cash-summary-expected-cash summary))
   'counted_cash_minor_units
   (if (shift-cash-summary-counted-cash summary)
       (money-minor-units (shift-cash-summary-counted-cash summary))
       (json-null))
   'over_short_minor_units
   (or (shift-cash-summary-over-short-minor-units summary) (json-null))))

(define (handle-register-context-request service)
  (with-handlers ([exn:fail? (lambda (_exception) (internal-error-response))])
    (define context (register-operations-load-context service))
    (json-response
     (hasheq
      'ok #t
      'register_context
      (hasheq
       'configured (register-context-configured? context)
       'register
       (if (register-context-register context)
           (register->jsexpr (register-context-register context))
           (json-null))
       'active_shift
       (if (register-context-active-shift context)
           (shift->jsexpr (register-context-active-shift context))
           (json-null)))))))

(define (handle-active-cashiers-request service)
  (with-handlers ([exn:fail? (lambda (_exception) (internal-error-response))])
    (json-response
     (hasheq
      'ok #t
      'cashiers
      (map cashier->jsexpr
           (register-operations-list-active-cashiers service))))))

(define (request-object req expected-fields)
  (cond
    [(not (json-content-type? req)) 'unsupported-media-type]
    [else
     (define bytes (request-post-data/raw req))
     (cond
       [(or (not bytes) (zero? (bytes-length bytes))) 'invalid-body]
       [else
        (define decoded (strict-json-bytes->jsexpr bytes))
        (cond
          [(strict-json-failure? decoded) 'invalid-body]
          [else
           (define value (strict-json-success-value decoded))
           (if (and (hash? value)
                    (= (hash-count value) (length expected-fields))
                    (andmap (lambda (field) (hash-has-key? value field))
                            expected-fields))
               value
               'invalid-body)])])]))

(define (invalid-request-response code message status status-message)
  (api-error-response code message #:status status #:status-message status-message))

(define (open-rejection-response code)
  (case code
    [(register-not-configured)
     (invalid-request-response
      "register_not_configured" "Register configuration is required."
      409 #"Conflict")]
    [(cashier-not-found)
     (invalid-request-response
      "cashier_not_found" "Cashier was not found." 404 #"Not Found")]
    [(cashier-inactive)
     (invalid-request-response
      "cashier_inactive" "Cashier is inactive." 409 #"Conflict")]
    [(shift-already-open)
     (invalid-request-response
      "shift_already_open" "A different cashier shift is already open."
      409 #"Conflict")]
    [else (error 'open-rejection-response "unsupported rejection: ~e" code)]))

(define (exact-nonnegative-integer? value)
  (and (exact-integer? value) (>= value 0)))

(define (handle-open-shift-request service req)
  (with-handlers ([exn:fail? (lambda (_exception) (internal-error-response))])
    (define object
      (request-object req '(cashier_id opening_cash_minor_units)))
    (cond
      [(eq? object 'unsupported-media-type)
       (invalid-request-response
        "unsupported_media_type" "Content-Type must be application/json."
        415 #"Unsupported Media Type")]
      [(eq? object 'invalid-body)
       (invalid-request-response
        "invalid_shift_request" "Open-shift request is invalid."
        400 #"Bad Request")]
      [else
       (define cashier-id (hash-ref object 'cashier_id))
       (define opening-minor-units
         (hash-ref object 'opening_cash_minor_units))
       (cond
         [(not (and (string? cashier-id)
                    (positive? (string-length cashier-id))))
          (invalid-request-response
           "invalid_shift_request" "cashier_id must be a non-empty string."
           400 #"Bad Request")]
         [(not (exact-nonnegative-integer? opening-minor-units))
          (invalid-request-response
           "invalid_shift_request"
           "opening_cash_minor_units must be an exact nonnegative integer."
           400 #"Bad Request")]
         [else
          (define result
            (register-operations-open-shift
             service cashier-id (money opening-minor-units)))
          (cond
            [(register-shift-opened? result)
             (json-response
              (hasheq 'ok #t
                      'shift
                      (shift->jsexpr
                       (register-shift-opened-shift result))
                      'cash_summary
                      (cash-summary->jsexpr
                       (register-shift-opened-cash-summary result))))]
            [(register-shift-open-rejected? result)
             (open-rejection-response
              (register-shift-open-rejected-code result))]
            [else (error 'handle-open-shift-request
                         "unsupported result: ~e" result)])])])) )

(define (close-rejection-response code)
  (case code
    [(shift-not-found)
     (invalid-request-response
      "shift_not_found" "Shift was not found." 404 #"Not Found")]
    [(shift-has-active-transaction)
     (invalid-request-response
      "shift_has_active_transaction"
      "Finish or void the active sale before closing the shift."
      409 #"Conflict")]
    [(cash-accounting-unavailable)
     (invalid-request-response
      "cash_accounting_unavailable"
      "Cash accounting is unavailable for this legacy shift."
      409 #"Conflict")]
    [else (error 'close-rejection-response "unsupported rejection: ~e" code)]))

(define (handle-close-shift-request service shift-id req)
  (with-handlers ([exn:fail? (lambda (_exception) (internal-error-response))])
    (define object (request-object req '(counted_cash_minor_units)))
    (cond
      [(eq? object 'unsupported-media-type)
       (invalid-request-response
        "unsupported_media_type" "Content-Type must be application/json."
        415 #"Unsupported Media Type")]
      [(eq? object 'invalid-body)
       (invalid-request-response
        "invalid_shift_request" "Close-shift request is invalid."
        400 #"Bad Request")]
      [else
       (define counted-minor-units
         (hash-ref object 'counted_cash_minor_units))
       (cond
         [(not (exact-nonnegative-integer? counted-minor-units))
          (invalid-request-response
           "invalid_shift_request"
           "counted_cash_minor_units must be an exact nonnegative integer."
           400 #"Bad Request")]
         [else
          (define result
            (register-operations-close-shift
             service shift-id (money counted-minor-units)))
          (cond
            [(register-shift-closed? result)
             (json-response
              (hasheq 'ok #t
                      'shift
                      (shift->jsexpr
                       (register-shift-closed-shift result))
                      'cash_summary
                      (cash-summary->jsexpr
                       (register-shift-closed-cash-summary result))))]
            [(register-shift-close-rejected? result)
             (close-rejection-response
              (register-shift-close-rejected-code result))]
            [else (error 'handle-close-shift-request
                         "unsupported result: ~e" result)])])])))

(define (cash-summary-result-response result)
  (cond
    [(shift-cash-summary-found? result)
     (json-response
      (hasheq 'ok #t
              'cash_summary
              (cash-summary->jsexpr
               (shift-cash-summary-found-summary result))))]
    [(shift-cash-summary-not-found? result)
     (invalid-request-response
      "shift_not_found" "Shift was not found." 404 #"Not Found")]
    [(shift-cash-summary-unavailable? result)
     (invalid-request-response
      "cash_accounting_unavailable"
      "Cash accounting is unavailable for this legacy shift."
      409 #"Conflict")]
    [else
     (error 'cash-summary-result-response "unsupported result: ~e" result)]))

(define (handle-shift-cash-summary-request service shift-id)
  (with-handlers ([exn:fail? (lambda (_exception) (internal-error-response))])
    (cash-summary-result-response
     (register-operations-load-cash-summary service shift-id))))
