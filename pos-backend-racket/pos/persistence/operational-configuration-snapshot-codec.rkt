#lang racket

(require "strict-json.rkt")

(provide json-string->operational-configuration-snapshot
         json-bytes->operational-configuration-snapshot
         jsexpr->operational-configuration-snapshot
         summarize-operational-configuration
         (struct-out operational-configuration-decode-success)
         (struct-out operational-configuration-decode-failure)
         operational-configuration-snapshot?
         operational-configuration-snapshot-schema-version
         operational-configuration-snapshot-register
         operational-configuration-snapshot-cashiers
         operational-configuration-register?
         operational-configuration-register-register-id
         operational-configuration-register-display-name
         operational-configuration-cashier?
         operational-configuration-cashier-cashier-id
         operational-configuration-cashier-display-name
         operational-configuration-cashier-active?)

(provide (struct-out operational-configuration-summary))

(struct operational-configuration-decode-success (snapshot) #:transparent)
(struct operational-configuration-decode-failure (code detail) #:transparent)
(struct operational-configuration-summary
  (cashier-count active-cashier-count inactive-cashier-count)
  #:transparent)

;; Constructors are private so activation only accepts completely validated
;; full snapshots.
(struct operational-configuration-snapshot
  (schema-version register cashiers)
  #:transparent)
(struct operational-configuration-register (register-id display-name)
  #:transparent)
(struct operational-configuration-cashier (cashier-id display-name active?)
  #:transparent)

(define root-fields '(schema_version register cashiers))
(define register-fields '(register_id display_name))
(define cashier-fields '(cashier_id display_name active))

(define (failure code format-string . arguments)
  (operational-configuration-decode-failure
   code
   (apply format format-string arguments)))

(define (validate-exact-fields object fields context)
  (define missing
    (for/first ([field (in-list fields)]
                #:unless (hash-has-key? object field))
      field))
  (define unexpected
    (for/first ([field (in-hash-keys object)]
                #:unless (member field fields))
      field))
  (cond
    [missing (failure 'missing-field
                      "~a is missing required field ~s" context missing)]
    [unexpected (failure 'unexpected-field
                         "~a contains unexpected field ~s"
                         context unexpected)]
    [else #f]))

(define (decode-non-empty value field code context)
  (cond
    [(not (string? value))
     (failure 'invalid-field-type
              "~a field ~s must be a string" context field)]
    [(zero? (string-length value))
     (failure code "~a field ~s must be non-empty" context field)]
    [else (string->immutable-string value)]))

(define (decode-register value)
  (cond
    [(not (hash? value))
     (failure 'expected-object "register must be a JSON object")]
    [else
     (define shape (validate-exact-fields value register-fields "register"))
     (cond
       [shape shape]
       [else
        (define id
          (decode-non-empty
           (hash-ref value 'register_id)
           'register_id
           'invalid-register-id
           "register"))
        (define name
          (decode-non-empty
           (hash-ref value 'display_name)
           'display_name
           'invalid-display-name
           "register"))
        (cond
          [(operational-configuration-decode-failure? id) id]
          [(operational-configuration-decode-failure? name) name]
          [else (operational-configuration-register id name)])])]))

(define (decode-cashier value index)
  (define context (format "cashier at index ~a" index))
  (cond
    [(not (hash? value))
     (failure 'expected-object "~a must be a JSON object" context)]
    [else
     (define shape (validate-exact-fields value cashier-fields context))
     (cond
       [shape shape]
       [else
        (define id
          (decode-non-empty
           (hash-ref value 'cashier_id)
           'cashier_id
           'invalid-cashier-id
           context))
        (define name
          (decode-non-empty
           (hash-ref value 'display_name)
           'display_name
           'invalid-display-name
           context))
        (define active? (hash-ref value 'active))
        (cond
          [(operational-configuration-decode-failure? id) id]
          [(operational-configuration-decode-failure? name) name]
          [(not (boolean? active?))
           (failure 'invalid-active
                    "~a field 'active must be a JSON boolean"
                    context)]
          [else (operational-configuration-cashier id name active?)])])]))

(define (decode-cashiers values)
  (let loop ([remaining values] [index 0] [decoded '()] [seen (hash)])
    (cond
      [(null? remaining) (reverse decoded)]
      [else
       (define cashier (decode-cashier (first remaining) index))
       (cond
         [(operational-configuration-decode-failure? cashier) cashier]
         [(hash-has-key?
           seen
           (operational-configuration-cashier-cashier-id cashier))
          (failure
           'duplicate-cashier-id
           "operational configuration contains duplicate cashier_id ~s"
           (operational-configuration-cashier-cashier-id cashier))]
         [else
          (loop
           (rest remaining)
           (add1 index)
           (cons cashier decoded)
           (hash-set
            seen
            (operational-configuration-cashier-cashier-id cashier)
            #t))])])))

(define (jsexpr->operational-configuration-snapshot value)
  (let/ec return
    (unless (hash? value)
      (return
       (failure 'expected-object
                "operational configuration must be a JSON object")))
    (define shape (validate-exact-fields value root-fields
                                         "operational configuration"))
    (when shape (return shape))
    (define version (hash-ref value 'schema_version))
    (unless (exact-integer? version)
      (return
       (failure 'invalid-field-type
                "field 'schema_version must be an exact integer")))
    (unless (= version 1)
      (return
       (failure 'unsupported-schema-version
                "unsupported operational configuration schema version ~a"
                version)))
    (define register (decode-register (hash-ref value 'register)))
    (when (operational-configuration-decode-failure? register)
      (return register))
    (define raw-cashiers (hash-ref value 'cashiers))
    (unless (list? raw-cashiers)
      (return
       (failure 'invalid-field-type "field 'cashiers must be a JSON array")))
    (define cashiers (decode-cashiers raw-cashiers))
    (when (operational-configuration-decode-failure? cashiers)
      (return cashiers))
    (operational-configuration-decode-success
     (operational-configuration-snapshot version register cashiers))))

(define (strict-result->snapshot result malformed-detail)
  (cond
    [(strict-json-success? result)
     (jsexpr->operational-configuration-snapshot
      (strict-json-success-value result))]
    [(eq? (strict-json-failure-code result) 'duplicate-field)
     (failure 'duplicate-field
              "JSON object contains duplicate field ~s"
              (strict-json-failure-detail result))]
    [else (failure 'malformed-json "~a" malformed-detail)]))

(define (json-string->operational-configuration-snapshot text)
  (unless (string? text)
    (raise-argument-error
     'json-string->operational-configuration-snapshot "string?" text))
  (strict-result->snapshot
   (strict-json-string->jsexpr text)
   "operational configuration is not valid JSON"))

(define (json-bytes->operational-configuration-snapshot bytes)
  (unless (bytes? bytes)
    (raise-argument-error
     'json-bytes->operational-configuration-snapshot "bytes?" bytes))
  (strict-result->snapshot
   (strict-json-bytes->jsexpr bytes)
   "operational configuration is not valid UTF-8 JSON"))

(define (summarize-operational-configuration snapshot)
  (unless (operational-configuration-snapshot? snapshot)
    (raise-argument-error
     'summarize-operational-configuration
     "operational-configuration-snapshot?"
     snapshot))
  (define cashiers (operational-configuration-snapshot-cashiers snapshot))
  (define active-count
    (count operational-configuration-cashier-active? cashiers))
  (operational-configuration-summary
   (length cashiers)
   active-count
   (- (length cashiers) active-count)))
