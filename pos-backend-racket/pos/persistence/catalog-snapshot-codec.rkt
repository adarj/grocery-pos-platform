#lang racket

(require "strict-json.rkt")

(provide json-string->catalog-snapshot
         json-bytes->catalog-snapshot
         jsexpr->catalog-snapshot
         catalog-snapshot-decode-success?
         catalog-snapshot-decode-success-snapshot
         catalog-snapshot-decode-failure?
         catalog-snapshot-decode-failure-code
         catalog-snapshot-decode-failure-detail
         catalog-snapshot?
         catalog-snapshot-schema-version
         catalog-snapshot-items
         catalog-snapshot-barcodes
         catalog-snapshot-item?
         catalog-snapshot-item-item-id
         catalog-snapshot-item-description
         catalog-snapshot-item-unit-price-minor-units
         catalog-snapshot-item-active?
         catalog-snapshot-barcode?
         catalog-snapshot-barcode-barcode
         catalog-snapshot-barcode-item-id
         summarize-catalog-snapshot
         catalog-snapshot-summary?
         catalog-snapshot-summary-item-count
         catalog-snapshot-summary-active-item-count
         catalog-snapshot-summary-inactive-item-count
         catalog-snapshot-summary-barcode-count)

(struct catalog-snapshot-decode-success (snapshot)
  #:transparent)
(struct catalog-snapshot-decode-failure (code detail)
  #:transparent)

;; Constructors stay private. A catalog-snapshot value therefore represents a
;; complete Schema v1 document that has passed primitive, duplicate, and
;; cross-reference validation.
(struct catalog-snapshot (schema-version items barcodes)
  #:transparent)
(struct catalog-snapshot-item
  (item-id description unit-price-minor-units active?)
  #:transparent)
(struct catalog-snapshot-barcode (barcode item-id)
  #:transparent)
(struct catalog-snapshot-summary
  (item-count active-item-count inactive-item-count barcode-count)
  #:transparent)

(define schema-version 1)
(define root-fields '(schema_version items barcodes))
(define item-fields
  '(item_id description unit_price_minor_units active))
(define barcode-fields '(barcode item_id))

(define (decode-failure code detail-format . arguments)
  (catalog-snapshot-decode-failure
   code
   (apply format detail-format arguments)))

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
     (decode-failure
      'missing-field
      "~a is missing required field ~s"
      context
      missing)]
    [unexpected
     (decode-failure
      'unexpected-field
      "~a contains unexpected field ~s"
      context
      unexpected)]
    [else #f]))

(define (invalid-field-type field expected context)
  (decode-failure
   'invalid-field-type
   "~a field ~s must contain ~a"
   context
   field
   expected))

(define (decode-non-empty-string value field invalid-code context)
  (cond
    [(not (string? value))
     (invalid-field-type field "a string" context)]
    [(zero? (string-length value))
     (decode-failure
      invalid-code
      "~a field ~s must contain a non-empty string"
      context
      field)]
    [else (string->immutable-string value)]))

(define (decode-item value index)
  (define context (format "catalog item at index ~a" index))
  (cond
    [(not (hash? value))
     (decode-failure 'expected-object "~a must be a JSON object" context)]
    [else
     (define shape-failure
       (validate-exact-fields value item-fields context))
     (cond
       [shape-failure shape-failure]
       [else
        (define item-id
          (decode-non-empty-string
           (hash-ref value 'item_id)
           'item_id
           'invalid-item-id
           context))
        (define description
          (decode-non-empty-string
           (hash-ref value 'description)
           'description
           'invalid-description
           context))
        (define price (hash-ref value 'unit_price_minor_units))
        (define active (hash-ref value 'active))
        (cond
          [(catalog-snapshot-decode-failure? item-id) item-id]
          [(catalog-snapshot-decode-failure? description) description]
          [(not (and (exact-integer? price) (>= price 0)))
           (decode-failure
            'invalid-price
            "~a field 'unit_price_minor_units must contain exact nonnegative integer minor units"
            context)]
          [(not (boolean? active))
           (decode-failure
            'invalid-active
            "~a field 'active must contain a JSON boolean"
            context)]
          [else
           (catalog-snapshot-item item-id description price active)])])]))

(define (decode-barcode value index)
  (define context (format "catalog barcode at index ~a" index))
  (cond
    [(not (hash? value))
     (decode-failure 'expected-object "~a must be a JSON object" context)]
    [else
     (define shape-failure
       (validate-exact-fields value barcode-fields context))
     (cond
       [shape-failure shape-failure]
       [else
        (define barcode
          (decode-non-empty-string
           (hash-ref value 'barcode)
           'barcode
           'invalid-barcode
           context))
        (define item-id
          (decode-non-empty-string
           (hash-ref value 'item_id)
           'item_id
           'invalid-item-id
           context))
        (cond
          [(catalog-snapshot-decode-failure? barcode) barcode]
          [(catalog-snapshot-decode-failure? item-id) item-id]
          [else (catalog-snapshot-barcode barcode item-id)])])]))

(define (decode-list-elements values decode-element)
  (let loop ([remaining values]
             [index 0]
             [decoded '()])
    (cond
      [(null? remaining) (reverse decoded)]
      [else
       (define next (decode-element (first remaining) index))
       (if (catalog-snapshot-decode-failure? next)
           next
           (loop (rest remaining) (add1 index) (cons next decoded)))])))

(define (find-duplicate values identity)
  (let loop ([remaining values] [seen (hash)])
    (cond
      [(null? remaining) #f]
      [else
       (define key (identity (first remaining)))
       (if (hash-has-key? seen key)
           key
           (loop (rest remaining) (hash-set seen key #t)))])))

(define (validate-cross-record-invariants items barcodes)
  (define duplicate-item-id
    (find-duplicate items catalog-snapshot-item-item-id))
  (define duplicate-barcode
    (find-duplicate barcodes catalog-snapshot-barcode-barcode))
  (cond
    [duplicate-item-id
     (decode-failure
      'duplicate-item-id
      "catalog snapshot contains duplicate item_id ~s"
      duplicate-item-id)]
    [duplicate-barcode
     (decode-failure
      'duplicate-barcode
      "catalog snapshot contains duplicate barcode ~s"
      duplicate-barcode)]
    [else
     (define item-ids
       (for/hash ([item (in-list items)])
         (values (catalog-snapshot-item-item-id item) #t)))
     (define missing-reference
       (for/first ([assignment (in-list barcodes)]
                   #:unless
                   (hash-has-key?
                    item-ids
                    (catalog-snapshot-barcode-item-id assignment)))
         assignment))
     (if missing-reference
         (decode-failure
          'unknown-item-reference
          "barcode ~s references missing item_id ~s"
          (catalog-snapshot-barcode-barcode missing-reference)
          (catalog-snapshot-barcode-item-id missing-reference))
         #f)]))

(define (jsexpr->catalog-snapshot value)
  (let/ec return
    (unless (hash? value)
      (return
       (decode-failure
        'expected-object
        "catalog snapshot must be a JSON object")))
    (define shape-failure
      (validate-exact-fields value root-fields "catalog snapshot"))
    (when shape-failure (return shape-failure))

    (define version (hash-ref value 'schema_version))
    (define raw-items (hash-ref value 'items))
    (define raw-barcodes (hash-ref value 'barcodes))
    (unless (exact-integer? version)
      (return
       (invalid-field-type
        'schema_version "an exact integer" "catalog snapshot")))
    (unless (= version schema-version)
      (return
       (decode-failure
        'unsupported-schema-version
        "unsupported catalog snapshot schema version ~a"
        version)))
    (unless (list? raw-items)
      (return
       (invalid-field-type 'items "a JSON array" "catalog snapshot")))
    (unless (list? raw-barcodes)
      (return
       (invalid-field-type 'barcodes "a JSON array" "catalog snapshot")))

    (define items (decode-list-elements raw-items decode-item))
    (when (catalog-snapshot-decode-failure? items) (return items))
    (define barcodes
      (decode-list-elements raw-barcodes decode-barcode))
    (when (catalog-snapshot-decode-failure? barcodes) (return barcodes))
    (define invariant-failure
      (validate-cross-record-invariants items barcodes))
    (when invariant-failure (return invariant-failure))

    (catalog-snapshot-decode-success
     (catalog-snapshot version items barcodes))))

(define (strict-json-result->catalog-snapshot result malformed-detail)
  (cond
    [(strict-json-success? result)
     (jsexpr->catalog-snapshot (strict-json-success-value result))]
    [(eq? (strict-json-failure-code result) 'duplicate-field)
     (decode-failure
      'duplicate-field
      "JSON object contains duplicate field ~s"
      (strict-json-failure-detail result))]
    [else
     (decode-failure 'malformed-json "~a" malformed-detail)]))

(define (json-string->catalog-snapshot text)
  (unless (string? text)
    (raise-argument-error 'json-string->catalog-snapshot "string?" text))
  (strict-json-result->catalog-snapshot
   (strict-json-string->jsexpr text)
   "catalog snapshot is not valid JSON"))

(define (json-bytes->catalog-snapshot bytes)
  (unless (bytes? bytes)
    (raise-argument-error 'json-bytes->catalog-snapshot "bytes?" bytes))
  (strict-json-result->catalog-snapshot
   (strict-json-bytes->jsexpr bytes)
   "catalog snapshot is not valid UTF-8 JSON"))

(define (summarize-catalog-snapshot snapshot)
  (unless (catalog-snapshot? snapshot)
    (raise-argument-error
     'summarize-catalog-snapshot "catalog-snapshot?" snapshot))
  (define items (catalog-snapshot-items snapshot))
  (define active-count
    (count catalog-snapshot-item-active? items))
  (catalog-snapshot-summary
   (length items)
   active-count
   (- (length items) active-count)
   (length (catalog-snapshot-barcodes snapshot))))
