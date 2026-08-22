#lang racket

(require json
         rackunit
         "../pos/persistence/catalog-snapshot-codec.rkt")

(define valid-snapshot-jsexpr
  (hasheq
   'schema_version 1
   'items
   (list
    (hasheq 'item_id "item-apples"
            'description "Test Apples"
            'unit_price_minor_units 199
            'active #t)
    (hasheq 'item_id "item-free"
            'description "Free Sample"
            'unit_price_minor_units 0
            'active #f)
    (hasheq 'item_id "item-no-barcode"
            'description "No Barcode"
            'unit_price_minor_units 250
            'active #t))
   'barcodes
   (list
    (hasheq 'barcode "049000001234" 'item_id "item-apples")
    (hasheq 'barcode "000012340005" 'item_id "item-apples")
    (hasheq 'barcode "000000000001" 'item_id "item-free"))))

(define (decode-jsexpr value)
  (json-string->catalog-snapshot (jsexpr->string value)))

(define (check-failure value expected-code)
  (define result (decode-jsexpr value))
  (check-pred catalog-snapshot-decode-failure? result)
  (check-equal? (catalog-snapshot-decode-failure-code result) expected-code)
  (check-pred string? (catalog-snapshot-decode-failure-detail result)))

(define (check-raw-failure text expected-code)
  (for ([result
         (in-list
          (list (json-string->catalog-snapshot text)
                (json-bytes->catalog-snapshot
                 (string->bytes/utf-8 text))))])
    (check-pred catalog-snapshot-decode-failure? result)
    (check-equal? (catalog-snapshot-decode-failure-code result) expected-code)
    (check-pred string? (catalog-snapshot-decode-failure-detail result))))

(module+ test
  (test-case "valid snapshot decodes into exact typed staged values"
    (define result (decode-jsexpr valid-snapshot-jsexpr))
    (check-pred catalog-snapshot-decode-success? result)
    (define snapshot
      (catalog-snapshot-decode-success-snapshot result))
    (check-pred catalog-snapshot? snapshot)
    (check-equal? (length (catalog-snapshot-items snapshot)) 3)
    (check-equal? (length (catalog-snapshot-barcodes snapshot)) 3)

    (define apples (first (catalog-snapshot-items snapshot)))
    (check-equal? (catalog-snapshot-item-item-id apples) "item-apples")
    (check-equal? (catalog-snapshot-item-description apples) "Test Apples")
    (check-equal?
     (catalog-snapshot-item-unit-price-minor-units apples)
     199)
    (check-true (catalog-snapshot-item-active? apples))
    (check-true (immutable? (catalog-snapshot-item-item-id apples)))
    (check-true (immutable? (catalog-snapshot-item-description apples)))

    (define leading-zero (second (catalog-snapshot-barcodes snapshot)))
    (check-equal? (catalog-snapshot-barcode-barcode leading-zero)
                  "000012340005")
    (check-equal? (catalog-snapshot-barcode-item-id leading-zero)
                  "item-apples")
    (check-true
     (immutable? (catalog-snapshot-barcode-barcode leading-zero)))
    (check-true
     (immutable? (catalog-snapshot-barcode-item-id leading-zero))))

  (test-case "valid snapshot summary counts exact catalog categories"
    (define snapshot
      (catalog-snapshot-decode-success-snapshot
       (decode-jsexpr valid-snapshot-jsexpr)))
    (define summary (summarize-catalog-snapshot snapshot))
    (check-equal? (catalog-snapshot-summary-item-count summary) 3)
    (check-equal? (catalog-snapshot-summary-active-item-count summary) 2)
    (check-equal? (catalog-snapshot-summary-inactive-item-count summary) 1)
    (check-equal? (catalog-snapshot-summary-barcode-count summary) 3))

  (test-case "multiple barcodes, barcode-less items, and zero price are valid"
    (define result (decode-jsexpr valid-snapshot-jsexpr))
    (check-pred catalog-snapshot-decode-success? result)
    (define snapshot
      (catalog-snapshot-decode-success-snapshot result))
    (define free-item (second (catalog-snapshot-items snapshot)))
    (check-equal?
     (catalog-snapshot-item-unit-price-minor-units free-item)
     0)
    (check-false (catalog-snapshot-item-active? free-item))
    (check-equal?
     (count
      (lambda (assignment)
        (string=? (catalog-snapshot-barcode-item-id assignment)
                  "item-apples"))
      (catalog-snapshot-barcodes snapshot))
     2))

  (test-case "malformed duplicate invalid UTF-8 and trailing JSON fail strictly"
    (check-raw-failure "{not-json" 'malformed-json)
    (check-raw-failure
     #<<JSON
{"schema_version":1,"schema_version":1,"items":[],"barcodes":[]}
JSON
     'duplicate-field)
    (check-raw-failure
     #<<JSON
{"schema_version":1,"items":[{"item_id":"first","item_\u0069d":"second","description":"Item","unit_price_minor_units":1,"active":true}],"barcodes":[]}
JSON
     'duplicate-field)
    (define invalid-utf8 (json-bytes->catalog-snapshot #"\377"))
    (check-pred catalog-snapshot-decode-failure? invalid-utf8)
    (check-equal? (catalog-snapshot-decode-failure-code invalid-utf8)
                  'malformed-json)
    (check-raw-failure
     (string-append (jsexpr->string valid-snapshot-jsexpr) " trailing")
     'malformed-json))

  (test-case "root must be an exact schema v1 object"
    (check-failure '() 'expected-object)
    (for ([field (in-list '(schema_version items barcodes))])
      (check-failure (hash-remove valid-snapshot-jsexpr field)
                     'missing-field))
    (check-failure (hash-set valid-snapshot-jsexpr 'unexpected "field")
                   'unexpected-field)
    (check-failure (hash-set valid-snapshot-jsexpr 'schema_version 2)
                   'unsupported-schema-version)
    (check-failure (hash-set valid-snapshot-jsexpr 'schema_version 1.0)
                   'invalid-field-type)
    (check-failure (hash-set valid-snapshot-jsexpr 'items "not-an-array")
                   'invalid-field-type)
    (check-failure (hash-set valid-snapshot-jsexpr 'barcodes #t)
                   'invalid-field-type))

  (test-case "item records require exact fields and primitive types"
    (define item (first (hash-ref valid-snapshot-jsexpr 'items)))
    (define (with-item replacement)
      (hash-set valid-snapshot-jsexpr 'items (list replacement)))

    (check-failure (with-item "not-an-object") 'expected-object)
    (for ([field (in-list
                  '(item_id description unit_price_minor_units active))])
      (check-failure (with-item (hash-remove item field)) 'missing-field))
    (check-failure (with-item (hash-set item 'unexpected "field"))
                   'unexpected-field)
    (check-failure (with-item (hash-set item 'item_id 1))
                   'invalid-field-type)
    (check-failure (with-item (hash-set item 'item_id ""))
                   'invalid-item-id)
    (check-failure (with-item (hash-set item 'description 1))
                   'invalid-field-type)
    (check-failure (with-item (hash-set item 'description ""))
                   'invalid-description)
    (for ([price (in-list (list -1 1.5 "199"))])
      (check-failure
       (with-item (hash-set item 'unit_price_minor_units price))
       'invalid-price))
    (for ([active (in-list (list 0 1 "true"))])
      (check-failure
       (with-item (hash-set item 'active active))
       'invalid-active)))

  (test-case "barcode records require exact opaque string fields"
    (define assignment
      (first (hash-ref valid-snapshot-jsexpr 'barcodes)))
    (define (with-barcode replacement)
      (hash-set valid-snapshot-jsexpr 'barcodes (list replacement)))

    (check-failure (with-barcode 1) 'expected-object)
    (for ([field (in-list '(barcode item_id))])
      (check-failure (with-barcode (hash-remove assignment field))
                     'missing-field))
    (check-failure
     (with-barcode (hash-set assignment 'unexpected "field"))
     'unexpected-field)
    (check-failure (with-barcode (hash-set assignment 'barcode 49000001234))
                   'invalid-field-type)
    (check-failure (with-barcode (hash-set assignment 'barcode ""))
                   'invalid-barcode)
    (check-failure (with-barcode (hash-set assignment 'item_id 1))
                   'invalid-field-type)
    (check-failure (with-barcode (hash-set assignment 'item_id ""))
                   'invalid-item-id))

  (test-case "duplicate staged identities reject the complete snapshot"
    (define item (first (hash-ref valid-snapshot-jsexpr 'items)))
    (check-failure
     (hash-set valid-snapshot-jsexpr 'items (list item item))
     'duplicate-item-id)
    (define assignment
      (first (hash-ref valid-snapshot-jsexpr 'barcodes)))
    (check-failure
     (hash-set valid-snapshot-jsexpr
               'barcodes
               (list assignment assignment))
     'duplicate-barcode))

  (test-case "barcode reference must name an item in the same snapshot"
    (define assignment
      (first (hash-ref valid-snapshot-jsexpr 'barcodes)))
    (check-failure
     (hash-set valid-snapshot-jsexpr
               'barcodes
               (list (hash-set assignment 'item_id "missing-item")))
     'unknown-item-reference)))
