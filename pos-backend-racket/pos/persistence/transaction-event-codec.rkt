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

;; Racket's JSON reader represents objects as hashes, so a repeated member
;; name would otherwise be collapsed before the strict schema checks see it.
;; This pass inspects the already syntax-validated raw JSON and compares decoded
;; member names, including names whose source spelling uses JSON escapes.
(define (find-duplicate-json-field raw-bytes)
  (define byte-count (bytes-length raw-bytes))
  (define quote-byte (char->integer #\"))
  (define backslash-byte (char->integer #\\))
  (define left-brace-byte (char->integer #\{))
  (define right-brace-byte (char->integer #\}))
  (define colon-byte (char->integer #\:))

  (define (json-whitespace-byte? byte)
    (member byte '(32 9 10 13)))

  (define (skip-whitespace position)
    (let loop ([position position])
      (if (and (< position byte-count)
               (json-whitespace-byte?
                (bytes-ref raw-bytes position)))
          (loop (add1 position))
          position)))

  (define (scan-string start)
    (unless (and (< start byte-count)
                 (= (bytes-ref raw-bytes start) quote-byte))
      (error 'find-duplicate-json-field "expected a JSON string"))
    (let loop ([position (add1 start)])
      (when (>= position byte-count)
        (error 'find-duplicate-json-field "unterminated JSON string"))
      (define byte (bytes-ref raw-bytes position))
      (cond
        [(= byte quote-byte) (add1 position)]
        [(= byte backslash-byte)
         (when (>= (add1 position) byte-count)
           (error 'find-duplicate-json-field "unterminated JSON escape"))
         (loop (+ position 2))]
        [else (loop (add1 position))])))

  (define (decode-key start end)
    (bytes->jsexpr (subbytes raw-bytes start end)))

  (let loop ([position 0]
             [object-scopes '()])
    (cond
      [(>= position byte-count) #f]
      [else
       (define byte (bytes-ref raw-bytes position))
       (cond
         [(= byte left-brace-byte)
          (loop (add1 position) (cons (hash) object-scopes))]
         [(= byte right-brace-byte)
          (loop (add1 position)
                (if (null? object-scopes)
                    object-scopes
                    (rest object-scopes)))]
         [(= byte quote-byte)
          (define key-end (scan-string position))
          (define after-string (skip-whitespace key-end))
          (cond
            [(and (< after-string byte-count)
                  (= (bytes-ref raw-bytes after-string) colon-byte))
             (unless (pair? object-scopes)
               (error 'find-duplicate-json-field
                      "JSON member name is outside an object"))
             (define key (decode-key position key-end))
             (define current-scope (first object-scopes))
             (if (hash-has-key? current-scope key)
                 key
                 (loop key-end
                       (cons (hash-set current-scope key #t)
                             (rest object-scopes))))]
            [else (loop key-end object-scopes)])]
         [else (loop (add1 position) object-scopes)])])))

(define (finish-raw-json-decode parsed raw-bytes malformed-message)
  (cond
    [(event-decode-failure? parsed) parsed]
    [else
     (define duplicate-or-failure
       (with-handlers ([exn:fail?
                        (lambda (_exception)
                          (event-decode-failure
                           'malformed-json
                           malformed-message))])
         (find-duplicate-json-field raw-bytes)))
     (cond
       [(event-decode-failure? duplicate-or-failure)
        duplicate-or-failure]
       [duplicate-or-failure
        (event-decode-failure
         'duplicate-field
         (format "JSON object contains duplicate field ~s"
                 duplicate-or-failure))]
       [else (jsexpr->transaction-event parsed)])]))

(define (read-complete-json input-port malformed-message)
  (define (malformed-json)
    (event-decode-failure 'malformed-json malformed-message))
  (with-handlers ([exn:fail? (lambda (_exception) (malformed-json))])
    (define parsed (read-json input-port))
    (let consume-trailing-whitespace ()
      (define next-character (read-char input-port))
      (cond
        [(eof-object? next-character) parsed]
        [(memv next-character '(#\space #\tab #\newline #\return))
         (consume-trailing-whitespace)]
        [else (malformed-json)]))))

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
    (read-complete-json
     (open-input-string text)
     "transaction event is not valid JSON"))
  (finish-raw-json-decode
   parsed
   (string->bytes/utf-8 text)
   "transaction event is not valid JSON"))

(define (json-bytes->transaction-event bytes)
  (unless (bytes? bytes)
    (raise-argument-error
     'json-bytes->transaction-event
     "bytes?"
     bytes))
  (define parsed
    (read-complete-json
     (open-input-bytes bytes)
     "transaction event is not valid UTF-8 JSON"))
  (finish-raw-json-decode
   parsed
   bytes
   "transaction event is not valid UTF-8 JSON"))
