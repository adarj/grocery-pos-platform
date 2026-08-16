#lang racket

(require json
         rackunit
         "../pos/domain/money.rkt"
         "../pos/domain/transaction-event.rkt"
         "../pos/persistence/transaction-event-codec.rkt")

(define started-event
  (transaction-started "txn-001"))

(define item-added-event
  (sale-item-added "049000001234"
                   "Test Apples"
                   (money 199)))

(define tendered-event
  (cash-tendered (money 500)))

(define completed-event
  (transaction-completed))

(define expected-started
  (hasheq 'schema_version 1
          'event_type "transaction_started"
          'payload
          (hasheq 'transaction_id "txn-001")))

(define expected-item-added
  (hasheq 'schema_version 1
          'event_type "sale_item_added"
          'payload
          (hasheq 'barcode "049000001234"
                  'description "Test Apples"
                  'unit_price_minor_units 199)))

(define expected-tendered
  (hasheq 'schema_version 1
          'event_type "cash_tendered"
          'payload
          (hasheq 'amount_minor_units 500)))

(define expected-completed
  (hasheq 'schema_version 1
          'event_type "transaction_completed"
          'payload (hasheq)))

(define (check-failure value expected-code)
  (define result (jsexpr->transaction-event value))
  (check-pred event-decode-failure? result)
  (check-equal? (event-decode-failure-code result) expected-code)
  (check-pred string? (event-decode-failure-message result)))

(define (check-raw-json-failure text expected-code)
  (for ([result
         (in-list
          (list (json-string->transaction-event text)
                (json-bytes->transaction-event
                 (string->bytes/utf-8 text))))])
    (check-pred event-decode-failure? result)
    (check-equal? (event-decode-failure-code result) expected-code)
    (check-pred string? (event-decode-failure-message result))))

(module+ test
  (test-case "schema v1 encodes exact golden representations"
    (check-equal? (transaction-event->jsexpr started-event)
                  expected-started)
    (check-equal? (transaction-event->jsexpr item-added-event)
                  expected-item-added)
    (check-equal? (transaction-event->jsexpr tendered-event)
                  expected-tendered)
    (check-equal? (transaction-event->jsexpr completed-event)
                  expected-completed))

  (test-case "all schema v1 events round trip through representations and JSON"
    (for ([event (in-list (list started-event
                                item-added-event
                                tendered-event
                                completed-event))])
      (define representation (transaction-event->jsexpr event))
      (define string-result
        (json-string->transaction-event
         (transaction-event->json-string event)))
      (define bytes-result
        (json-bytes->transaction-event
         (transaction-event->json-bytes event)))
      (define representation-result
        (jsexpr->transaction-event representation))

      (check-pred event-decode-success? representation-result)
      (check-pred event-decode-success? string-result)
      (check-pred event-decode-success? bytes-result)
      (check-equal? (event-decode-success-event representation-result)
                    event)
      (check-equal? (event-decode-success-event string-result) event)
      (check-equal? (event-decode-success-event bytes-result) event)
      (check-equal? (string->jsexpr (transaction-event->json-string event))
                    representation)
      (check-equal? (bytes->jsexpr (transaction-event->json-bytes event))
                    representation)))

  (test-case "malformed JSON produces a predictable codec failure"
    (define string-result (json-string->transaction-event "{not-json"))
    (define bytes-result (json-bytes->transaction-event #"\377"))

    (check-pred event-decode-failure? string-result)
    (check-equal? (event-decode-failure-code string-result) 'malformed-json)
    (check-pred string? (event-decode-failure-message string-result))
    (check-pred event-decode-failure? bytes-result)
    (check-equal? (event-decode-failure-code bytes-result) 'malformed-json)
    (check-pred string? (event-decode-failure-message bytes-result)))

  (test-case "raw JSON decoding requires end-of-input after one event"
    (define completed-json
      (transaction-event->json-string completed-event))
    (check-raw-json-failure
     (string-append completed-json " trailing-garbage")
     'malformed-json)
    (check-raw-json-failure
     (string-append completed-json completed-json)
     'malformed-json)

    ;; JSON whitespace after the single value remains valid.
    (define with-trailing-whitespace
      (string-append completed-json " \t\r\n"))
    (for ([result
           (in-list
            (list
             (json-string->transaction-event with-trailing-whitespace)
             (json-bytes->transaction-event
              (string->bytes/utf-8 with-trailing-whitespace))))])
      (check-pred event-decode-success? result)
      (check-equal? (event-decode-success-event result)
                    completed-event)))

  (test-case "duplicate JSON object fields are rejected before decoding"
    (check-raw-json-failure
     #<<JSON
{"schema_version":999,"schema_version":1,"event_type":"transaction_completed","payload":{}}
JSON
     'duplicate-field)
    (check-raw-json-failure
     #<<JSON
{"schema_version":1,"event_type":"sale_item_added","payload":{"barcode":"049000001234","description":"Test Apples","unit_price_minor_units":999,"unit_price_minor_units":199}}
JSON
     'duplicate-field)
    ;; JSON escape spelling does not make a member name distinct.
    (check-raw-json-failure
     #<<JSON
{"schema_version":999,"schema_\u0076ersion":1,"event_type":"transaction_completed","payload":{}}
JSON
     'duplicate-field))

  (test-case "top-level schema shape is strict"
    (check-failure "transaction_started" 'expected-object)
    (check-failure
     (hasheq 'event_type "transaction_started"
             'payload (hasheq 'transaction_id "txn-001"))
     'missing-field)
    (check-failure
     (hasheq 'schema_version 1
             'payload (hasheq 'transaction_id "txn-001"))
     'missing-field)
    (check-failure
     (hasheq 'schema_version 1
             'event_type "transaction_started")
     'missing-field)
    (check-failure
     (hash-set expected-started 'unexpected "field")
     'unexpected-field))

  (test-case "schema version and event type are validated explicitly"
    (check-failure
     (hash-set expected-started 'schema_version 2)
     'unsupported-schema-version)
    (check-failure
     (hash-set expected-started 'schema_version 1.0)
     'invalid-field-type)
    (check-failure
     (hash-set expected-started 'event_type 'transaction_started)
     'invalid-field-type)
    (check-failure
     (hash-set expected-started 'event_type "future_event")
     'unknown-event-type))

  (test-case "payload must be an object with its exact event-specific shape"
    (check-failure
     (hash-set expected-started 'payload "txn-001")
     'invalid-field-type)
    (check-failure
     (hash-set expected-started 'payload (hasheq))
     'missing-field)
    (check-failure
     (hash-set expected-started
               'payload
               (hasheq 'transaction_id "txn-001"
                       'unexpected "field"))
     'unexpected-field)
    (check-failure
     (hash-set expected-completed
               'payload
               (hasheq 'unexpected "field"))
     'unexpected-field))

  (test-case "textual domain facts are not coerced"
    (check-failure
     (hash-set expected-started
               'payload
               (hasheq 'transaction_id 1))
     'invalid-field-type)
    (check-failure
     (hash-set expected-item-added
               'payload
               (hasheq 'barcode 49000001234
                       'description "Test Apples"
                       'unit_price_minor_units 199))
     'invalid-field-type)
    (check-failure
     (hash-set expected-item-added
               'payload
               (hasheq 'barcode "049000001234"
                       'description 'test-apples
                       'unit_price_minor_units 199))
     'invalid-field-type))

  (test-case "money fields require exact nonnegative integer minor units"
    (for ([invalid-price (in-list (list -1 1.99 1.0 199/100 "199"))])
      (check-failure
       (hash-set expected-item-added
                 'payload
                 (hasheq 'barcode "049000001234"
                         'description "Test Apples"
                         'unit_price_minor_units invalid-price))
       'invalid-money))
    (for ([invalid-amount (in-list (list -1 5.00 500/3 "500"))])
      (check-failure
       (hash-set expected-tendered
                 'payload
                 (hasheq 'amount_minor_units invalid-amount))
       'invalid-money))))
