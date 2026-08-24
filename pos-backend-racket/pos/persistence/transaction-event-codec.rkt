#lang racket

(require json
         "../domain/money.rkt"
         "../domain/tax.rkt"
         "../domain/transaction-event.rkt"
         "../domain/transaction-operational-context.rkt"
         "strict-json.rkt")

(provide transaction-event->jsexpr
         transaction-event->json-string
         transaction-event->json-bytes
         jsexpr->transaction-event
         json-string->transaction-event
         json-bytes->transaction-event
         event-decode-success?
         event-decode-success-event
         event-decode-failure?
         event-decode-failure-code
         event-decode-failure-message)

(struct event-decode-success (event)
  #:transparent)

(struct event-decode-failure (code message)
  #:transparent)

(define envelope-fields
  '(schema_version event_type payload))

(define (transaction-event->jsexpr event)
  (unless (transaction-event? event)
    (raise-argument-error
     'transaction-event->jsexpr
     "transaction-event?"
     event))

  (define-values (schema-version event-type payload)
    (cond
      [(transaction-started? event)
       (values
        1
        "transaction_started"
        (hasheq
         'transaction_id
         (transaction-started-transaction-id event)))]
      [(operational-transaction-started? event)
       (define context (operational-transaction-started-context event))
       (values
        2
        "transaction_started"
        (hasheq
         'transaction_id
         (operational-transaction-started-transaction-id event)
         'register_id
         (transaction-operational-context-register-id context)
         'register_display_name
         (transaction-operational-context-register-display-name context)
         'cashier_id
         (transaction-operational-context-cashier-id context)
         'cashier_display_name
         (transaction-operational-context-cashier-display-name context)
         'shift_id
         (transaction-operational-context-shift-id context)
         'started_at_epoch_ms
         (transaction-operational-context-started-at-epoch-ms context)))]
      [(sale-item-added? event)
       (values
        1
        "sale_item_added"
        (hasheq
         'barcode (sale-item-added-barcode event)
         'description (sale-item-added-description event)
         'unit_price_minor_units
         (money-minor-units
          (sale-item-added-unit-price event))))]
      [(taxed-sale-item-added? event)
       (values
        2
        "sale_item_added"
        (hasheq
         'barcode (taxed-sale-item-added-barcode event)
         'description (taxed-sale-item-added-description event)
         'unit_price_minor_units
         (money-minor-units
          (taxed-sale-item-added-unit-price event))
         'tax_category_id
         (taxed-sale-item-added-tax-category-id event)
         'tax_rate_millionths
         (tax-rate-millionths
          (taxed-sale-item-added-tax-rate event))
         'tax_amount_minor_units
         (money-minor-units
          (taxed-sale-item-added-tax-amount event))))]
      [(cash-tendered? event)
       (values
        1
        "cash_tendered"
        (hasheq
         'amount_minor_units
         (money-minor-units (cash-tendered-amount event))))]
      [(sale-line-removed? event)
       (values
        1
        "sale_line_removed"
        (hasheq 'line_index
                (sale-line-removed-line-index event)))]
      [(transaction-completed? event)
       (values 1 "transaction_completed" (hasheq))]
      [(timestamped-transaction-completed? event)
       (values
        2
        "transaction_completed"
        (hasheq
         'completed_at_epoch_ms
         (timestamped-transaction-completed-completed-at-epoch-ms event)))]
      [(transaction-voided? event)
       (values 1 "transaction_voided" (hasheq))]
      [(timestamped-transaction-voided? event)
       (values
        2
        "transaction_voided"
        (hasheq
         'voided_at_epoch_ms
         (timestamped-transaction-voided-voided-at-epoch-ms event)))]))

  (hasheq 'schema_version schema-version
          'event_type event-type
          'payload payload))

(define (transaction-event->json-string event)
  (jsexpr->string (transaction-event->jsexpr event)))

(define (transaction-event->json-bytes event)
  (jsexpr->bytes (transaction-event->jsexpr event)))

(define (missing-field object expected-fields)
  (for/first ([field (in-list expected-fields)]
              #:unless (hash-has-key? object field))
    field))

(define (unexpected-field object expected-fields)
  (for/first ([field (in-hash-keys object)]
              #:unless (member field expected-fields))
    field))

(define (validate-exact-fields object expected-fields context)
  (define missing (missing-field object expected-fields))
  (define unexpected (unexpected-field object expected-fields))
  (cond
    [missing
     (event-decode-failure
      'missing-field
      (format "~a is missing required field ~s" context missing))]
    [unexpected
     (event-decode-failure
      'unexpected-field
      (format "~a contains unexpected field ~s" context unexpected))]
    [else #f]))

(define (invalid-field-type field expected)
  (event-decode-failure
   'invalid-field-type
   (format "field ~s must contain ~a" field expected)))

(define (decode-money value field)
  (if (and (exact-integer? value)
           (>= value 0))
      (money value)
      (event-decode-failure
       'invalid-money
       (format
        "field ~s must contain exact nonnegative integer minor units"
        field))))

(define (decode-transaction-started payload)
  (define shape-failure
    (validate-exact-fields payload
                           '(transaction_id)
                           "transaction_started payload"))
  (cond
    [shape-failure shape-failure]
    [else
     (define transaction-id (hash-ref payload 'transaction_id))
     (if (string? transaction-id)
         (event-decode-success
          (transaction-started transaction-id))
         (invalid-field-type 'transaction_id "a string"))]))

(define (non-empty-string-field payload field)
  (define value (hash-ref payload field))
  (if (and (string? value) (positive? (string-length value)))
      value
      (event-decode-failure
       'invalid-field-type
       (format "field ~s must contain a non-empty string" field))))

(define (epoch-ms-field payload field)
  (define value (hash-ref payload field))
  (if (and (exact-integer? value) (>= value 0))
      value
      (event-decode-failure
       'invalid-field-type
       (format
        "field ~s must contain an exact nonnegative epoch millisecond integer"
        field))))

(define (decode-operational-transaction-started payload)
  (define fields
    '(transaction_id
      register_id
      register_display_name
      cashier_id
      cashier_display_name
      shift_id
      started_at_epoch_ms))
  (define shape-failure
    (validate-exact-fields payload fields
                           "schema v2 transaction_started payload"))
  (cond
    [shape-failure shape-failure]
    [else
     (define transaction-id
       (non-empty-string-field payload 'transaction_id))
     (define register-id (non-empty-string-field payload 'register_id))
     (define register-name
       (non-empty-string-field payload 'register_display_name))
     (define cashier-id (non-empty-string-field payload 'cashier_id))
     (define cashier-name
       (non-empty-string-field payload 'cashier_display_name))
     (define shift-id (non-empty-string-field payload 'shift_id))
     (define started-at (epoch-ms-field payload 'started_at_epoch_ms))
     (define failure
       (for/first ([value
                    (in-list
                     (list transaction-id register-id register-name cashier-id
                           cashier-name shift-id started-at))]
                   #:when (event-decode-failure? value))
         value))
     (if failure
         failure
         (event-decode-success
          (operational-transaction-started
           transaction-id
           (transaction-operational-context
            register-id register-name cashier-id cashier-name shift-id
            started-at))))]))

(define (decode-sale-item-added payload)
  (define shape-failure
    (validate-exact-fields
     payload
     '(barcode description unit_price_minor_units)
     "sale_item_added payload"))
  (cond
    [shape-failure shape-failure]
    [else
     (define barcode (hash-ref payload 'barcode))
     (define description (hash-ref payload 'description))
     (define price
       (decode-money (hash-ref payload 'unit_price_minor_units)
                     'unit_price_minor_units))
     (cond
       [(not (string? barcode))
        (invalid-field-type 'barcode "a string")]
       [(not (string? description))
        (invalid-field-type 'description "a string")]
       [(event-decode-failure? price) price]
       [else
        (event-decode-success
         (sale-item-added barcode description price))])]))

(define (decode-tax-rate value field)
  (if (and (exact-integer? value)
           (<= 0 value 1000000))
      (tax-rate value)
      (event-decode-failure
       'invalid-tax-rate
       (format
        "field ~s must contain an exact integer from 0 through 1000000"
        field))))

(define (decode-taxed-sale-item-added payload)
  (define shape-failure
    (validate-exact-fields
     payload
     '(barcode
       description
       unit_price_minor_units
       tax_category_id
       tax_rate_millionths
       tax_amount_minor_units)
     "schema v2 sale_item_added payload"))
  (cond
    [shape-failure shape-failure]
    [else
     (define barcode (hash-ref payload 'barcode))
     (define description (hash-ref payload 'description))
     (define tax-category-id (hash-ref payload 'tax_category_id))
     (define price
       (decode-money (hash-ref payload 'unit_price_minor_units)
                     'unit_price_minor_units))
     (define rate
       (decode-tax-rate (hash-ref payload 'tax_rate_millionths)
                        'tax_rate_millionths))
     (define tax-amount
       (decode-money (hash-ref payload 'tax_amount_minor_units)
                     'tax_amount_minor_units))
     (cond
       [(not (string? barcode))
        (invalid-field-type 'barcode "a string")]
       [(not (string? description))
        (invalid-field-type 'description "a string")]
       [(not (and (string? tax-category-id)
                  (positive? (string-length tax-category-id))))
        (event-decode-failure
         'invalid-tax-category-id
         "field 'tax_category_id must contain a non-empty string")]
       [(event-decode-failure? price) price]
       [(event-decode-failure? rate) rate]
       [(event-decode-failure? tax-amount) tax-amount]
       [(not (equal? tax-amount (calculate-line-tax price rate)))
        (event-decode-failure
         'inconsistent-tax-amount
         "tax amount does not match the Schema v2 line-tax calculation")]
       [else
        (event-decode-success
         (taxed-sale-item-added barcode
                                description
                                price
                                tax-category-id
                                rate
                                tax-amount))])]))

(define (decode-cash-tendered payload)
  (define shape-failure
    (validate-exact-fields payload
                           '(amount_minor_units)
                           "cash_tendered payload"))
  (cond
    [shape-failure shape-failure]
    [else
     (define amount
       (decode-money (hash-ref payload 'amount_minor_units)
                     'amount_minor_units))
     (if (event-decode-failure? amount)
         amount
         (event-decode-success (cash-tendered amount)))]))

(define (decode-transaction-completed payload)
  (define shape-failure
    (validate-exact-fields payload
                           '()
                           "transaction_completed payload"))
  (if shape-failure
      shape-failure
      (event-decode-success (transaction-completed))))

(define (decode-timestamped-transaction-completed payload)
  (define shape-failure
    (validate-exact-fields payload
                           '(completed_at_epoch_ms)
                           "schema v2 transaction_completed payload"))
  (cond
    [shape-failure shape-failure]
    [else
     (define completed-at (epoch-ms-field payload 'completed_at_epoch_ms))
     (if (event-decode-failure? completed-at)
         completed-at
         (event-decode-success
          (timestamped-transaction-completed completed-at))) ]))

(define (decode-sale-line-removed payload)
  (define shape-failure
    (validate-exact-fields payload
                           '(line_index)
                           "sale_line_removed payload"))
  (cond
    [shape-failure shape-failure]
    [else
     (define line-index (hash-ref payload 'line_index))
     (if (and (exact-integer? line-index)
              (>= line-index 0))
         (event-decode-success (sale-line-removed line-index))
         (event-decode-failure
          'invalid-line-index
          "field 'line_index must contain an exact nonnegative integer"))]))

(define (decode-transaction-voided payload)
  (define shape-failure
    (validate-exact-fields payload
                           '()
                           "transaction_voided payload"))
  (if shape-failure
      shape-failure
      (event-decode-success (transaction-voided))))

(define (decode-timestamped-transaction-voided payload)
  (define shape-failure
    (validate-exact-fields payload
                           '(voided_at_epoch_ms)
                           "schema v2 transaction_voided payload"))
  (cond
    [shape-failure shape-failure]
    [else
     (define voided-at (epoch-ms-field payload 'voided_at_epoch_ms))
     (if (event-decode-failure? voided-at)
         voided-at
         (event-decode-success
          (timestamped-transaction-voided voided-at)))]))

(define (jsexpr->transaction-event value)
  (cond
    [(not (hash? value))
     (event-decode-failure
      'expected-object
      "transaction event must be a JSON object")]
    [else
     (define shape-failure
       (validate-exact-fields value envelope-fields "transaction event"))
     (cond
       [shape-failure shape-failure]
       [else
        (define version (hash-ref value 'schema_version))
        (define event-type (hash-ref value 'event_type))
        (define payload (hash-ref value 'payload))
        (cond
          [(not (exact-integer? version))
           (invalid-field-type 'schema_version "an exact integer")]
          [(not (or (= version 1) (= version 2)))
           (event-decode-failure
            'unsupported-schema-version
            (format "unsupported transaction event schema version ~a"
                    version))]
          [(not (string? event-type))
           (invalid-field-type 'event_type "a string")]
          [(not (hash? payload))
           (invalid-field-type 'payload "a JSON object")]
          [else
           (cond
             [(= version 2)
              (cond
                [(string=? event-type "transaction_started")
                 (decode-operational-transaction-started payload)]
                [(string=? event-type "sale_item_added")
                 (decode-taxed-sale-item-added payload)]
                [(string=? event-type "transaction_completed")
                 (decode-timestamped-transaction-completed payload)]
                [(string=? event-type "transaction_voided")
                 (decode-timestamped-transaction-voided payload)]
                [else
                 (event-decode-failure
                  'unsupported-schema-event-type
                  (format
                   "transaction event schema version 2 does not support event type ~s"
                   event-type))])]
             [(string=? event-type "transaction_started")
              (decode-transaction-started payload)]
             [(string=? event-type "sale_item_added")
              (decode-sale-item-added payload)]
             [(string=? event-type "cash_tendered")
              (decode-cash-tendered payload)]
             [(string=? event-type "sale_line_removed")
              (decode-sale-line-removed payload)]
             [(string=? event-type "transaction_completed")
              (decode-transaction-completed payload)]
             [(string=? event-type "transaction_voided")
              (decode-transaction-voided payload)]
             [else
              (event-decode-failure
               'unknown-event-type
               (format "unknown transaction event type ~s"
                       event-type))])])])]))

(define (strict-json-result->event result malformed-message)
  (cond
    [(strict-json-success? result)
     (jsexpr->transaction-event (strict-json-success-value result))]
    [(eq? (strict-json-failure-code result) 'duplicate-field)
     (event-decode-failure
      'duplicate-field
      (format "JSON object contains duplicate field ~s"
              (strict-json-failure-detail result)))]
    [else
     (event-decode-failure 'malformed-json malformed-message)]))

(define (json-string->transaction-event text)
  (unless (string? text)
    (raise-argument-error
     'json-string->transaction-event
     "string?"
     text))
  (strict-json-result->event
   (strict-json-string->jsexpr text)
   "transaction event is not valid JSON"))

(define (json-bytes->transaction-event bytes)
  (unless (bytes? bytes)
    (raise-argument-error
     'json-bytes->transaction-event
     "bytes?"
     bytes))
  (strict-json-result->event
   (strict-json-bytes->jsexpr bytes)
   "transaction event is not valid UTF-8 JSON"))
