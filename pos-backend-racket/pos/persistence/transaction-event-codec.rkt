#lang racket

(require json
         "../domain/money.rkt"
         "../domain/transaction-event.rkt")

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

(define schema-version 1)
(define envelope-fields
  '(schema_version event_type payload))

(define (transaction-event->jsexpr event)
  (unless (transaction-event? event)
    (raise-argument-error
     'transaction-event->jsexpr
     "transaction-event?"
     event))

  (define-values (event-type payload)
    (cond
      [(transaction-started? event)
       (values
        "transaction_started"
        (hasheq
         'transaction_id
         (transaction-started-transaction-id event)))]
      [(sale-item-added? event)
       (values
        "sale_item_added"
        (hasheq
         'barcode (sale-item-added-barcode event)
         'description (sale-item-added-description event)
         'unit_price_minor_units
         (money-minor-units
          (sale-item-added-unit-price event))))]
      [(cash-tendered? event)
       (values
        "cash_tendered"
        (hasheq
         'amount_minor_units
         (money-minor-units (cash-tendered-amount event))))]
      [(transaction-completed? event)
       (values "transaction_completed" (hasheq))]))

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
          [(not (= version schema-version))
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
             [(string=? event-type "transaction_started")
              (decode-transaction-started payload)]
             [(string=? event-type "sale_item_added")
              (decode-sale-item-added payload)]
             [(string=? event-type "cash_tendered")
              (decode-cash-tendered payload)]
             [(string=? event-type "transaction_completed")
              (decode-transaction-completed payload)]
             [else
              (event-decode-failure
               'unknown-event-type
               (format "unknown transaction event type ~s"
                       event-type))])])])]))

(define (json-string->transaction-event text)
  (unless (string? text)
    (raise-argument-error
     'json-string->transaction-event
     "string?"
     text))
  (define parsed
    (with-handlers ([exn:fail?
                     (lambda (_exception)
                       (event-decode-failure
                        'malformed-json
                        "transaction event is not valid JSON"))])
      (string->jsexpr text)))
  (if (event-decode-failure? parsed)
      parsed
      (jsexpr->transaction-event parsed)))

(define (json-bytes->transaction-event bytes)
  (unless (bytes? bytes)
    (raise-argument-error
     'json-bytes->transaction-event
     "bytes?"
     bytes))
  (define parsed
    (with-handlers ([exn:fail?
                     (lambda (_exception)
                       (event-decode-failure
                        'malformed-json
                        "transaction event is not valid UTF-8 JSON"))])
      (bytes->jsexpr bytes)))
  (if (event-decode-failure? parsed)
      parsed
      (jsexpr->transaction-event parsed)))
