#lang racket

(require json
         "../application/transaction-command.rkt"
         "../domain/money.rkt"
         "strict-json.rkt")

(provide transaction-command->jsexpr
         transaction-command->json-string
         transaction-command->json-bytes
         jsexpr->transaction-command
         json-string->transaction-command
         json-bytes->transaction-command
         command-decode-success?
         command-decode-success-command
         command-decode-failure?
         command-decode-failure-code
         command-decode-failure-message)

(struct command-decode-success (command)
  #:transparent)

(struct command-decode-failure (code message)
  #:transparent)

(define schema-version 1)
(define envelope-fields
  '(schema_version
    command_id
    transaction_id
    expected_version
    command_type
    payload))

(define (transaction-command->jsexpr command)
  (unless (transaction-command? command)
    (raise-argument-error
     'transaction-command->jsexpr
     "transaction-command?"
     command))

  (define-values (command-type payload)
    (cond
      [(start-transaction-command? command)
       (values "start_transaction" (hasheq))]
      [(scan-barcode-command? command)
       (values "scan_barcode"
               (hasheq 'barcode
                       (scan-barcode-command-barcode command)))]
      [(tender-cash-command? command)
       (values
        "tender_cash"
        (hasheq
         'amount_minor_units
         (money-minor-units (tender-cash-command-amount command))))]
      [(complete-transaction-command? command)
       (values "complete_transaction" (hasheq))]))

  (hasheq 'schema_version schema-version
          'command_id (transaction-command-command-id command)
          'transaction_id (transaction-command-transaction-id command)
          'expected_version
          (transaction-command-expected-version command)
          'command_type command-type
          'payload payload))

(define (transaction-command->json-string command)
  (jsexpr->string (transaction-command->jsexpr command)))

(define (transaction-command->json-bytes command)
  (jsexpr->bytes (transaction-command->jsexpr command)))

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
     (command-decode-failure
      'missing-field
      (format "~a is missing required field ~s" context missing))]
    [unexpected
     (command-decode-failure
      'unexpected-field
      (format "~a contains unexpected field ~s" context unexpected))]
    [else #f]))

(define (invalid-field-type field expected)
  (command-decode-failure
   'invalid-field-type
   (format "field ~s must contain ~a" field expected)))

(define (invalid-non-empty-string value field failure-code)
  (cond
    [(not (string? value))
     (invalid-field-type field "a string")]
    [(zero? (string-length value))
     (command-decode-failure
      failure-code
      (format "field ~s must contain a non-empty string" field))]
    [else #f]))

(define (decode-expected-version value)
  (cond
    [(not (number? value))
     (invalid-field-type 'expected_version "a number")]
    [(not (and (exact-integer? value) (>= value 0)))
     (command-decode-failure
      'invalid-expected-version
      "field 'expected_version must contain an exact nonnegative integer")]
    [else #f]))

(define (decode-money value field)
  (if (and (exact-integer? value)
           (>= value 0))
      (money value)
      (command-decode-failure
       'invalid-money
       (format
        "field ~s must contain exact nonnegative integer minor units"
        field))))

(define (decode-empty-payload payload context make-command)
  (define shape-failure
    (validate-exact-fields payload '() context))
  (if shape-failure
      shape-failure
      (command-decode-success (make-command))))

(define (decode-scan-payload payload
                             command-id
                             transaction-id
                             expected-version)
  (define shape-failure
    (validate-exact-fields payload '(barcode) "scan_barcode payload"))
  (cond
    [shape-failure shape-failure]
    [else
     (define barcode (hash-ref payload 'barcode))
     (define barcode-failure
       (invalid-non-empty-string barcode 'barcode 'invalid-barcode))
     (if barcode-failure
         barcode-failure
         (command-decode-success
          (scan-barcode-command command-id
                                transaction-id
                                expected-version
                                barcode)))]))

(define (decode-tender-payload payload
                               command-id
                               transaction-id
                               expected-version)
  (define shape-failure
    (validate-exact-fields payload
                           '(amount_minor_units)
                           "tender_cash payload"))
  (cond
    [shape-failure shape-failure]
    [else
     (define amount
       (decode-money (hash-ref payload 'amount_minor_units)
                     'amount_minor_units))
     (if (command-decode-failure? amount)
         amount
         (command-decode-success
          (tender-cash-command command-id
                               transaction-id
                               expected-version
                               amount)))]))

(define (decode-command-payload command-type
                                payload
                                command-id
                                transaction-id
                                expected-version)
  (cond
    [(string=? command-type "start_transaction")
     (decode-empty-payload
      payload
      "start_transaction payload"
      (lambda ()
        (start-transaction-command command-id
                                   transaction-id
                                   expected-version)))]
    [(string=? command-type "scan_barcode")
     (decode-scan-payload payload
                          command-id
                          transaction-id
                          expected-version)]
    [(string=? command-type "tender_cash")
     (decode-tender-payload payload
                            command-id
                            transaction-id
                            expected-version)]
    [(string=? command-type "complete_transaction")
     (decode-empty-payload
      payload
      "complete_transaction payload"
      (lambda ()
        (complete-transaction-command command-id
                                      transaction-id
                                      expected-version)))]
    [else
     (command-decode-failure
      'unknown-command-type
      (format "unknown transaction command type ~s" command-type))]))

(define (jsexpr->transaction-command value)
  (cond
    [(not (hash? value))
     (command-decode-failure
      'expected-object
      "transaction command must be a JSON object")]
    [else
     (define shape-failure
       (validate-exact-fields value envelope-fields "transaction command"))
     (cond
       [shape-failure shape-failure]
       [else
        (define version (hash-ref value 'schema_version))
        (define command-id (hash-ref value 'command_id))
        (define transaction-id (hash-ref value 'transaction_id))
        (define expected-version (hash-ref value 'expected_version))
        (define command-type (hash-ref value 'command_type))
        (define payload (hash-ref value 'payload))
        (define command-id-failure
          (invalid-non-empty-string
           command-id 'command_id 'invalid-command-id))
        (define transaction-id-failure
          (invalid-non-empty-string
           transaction-id 'transaction_id 'invalid-transaction-id))
        (define expected-version-failure
          (decode-expected-version expected-version))
        (cond
          [(not (exact-integer? version))
           (invalid-field-type 'schema_version "an exact integer")]
          [(not (= version schema-version))
           (command-decode-failure
            'unsupported-schema-version
            (format "unsupported transaction command schema version ~a"
                    version))]
          [command-id-failure command-id-failure]
          [transaction-id-failure transaction-id-failure]
          [expected-version-failure expected-version-failure]
          [(not (string? command-type))
           (invalid-field-type 'command_type "a string")]
          [(not (hash? payload))
           (invalid-field-type 'payload "a JSON object")]
          [else
           (decode-command-payload command-type
                                   payload
                                   command-id
                                   transaction-id
                                   expected-version)])])]))

(define (strict-json-result->command result malformed-message)
  (cond
    [(strict-json-success? result)
     (jsexpr->transaction-command (strict-json-success-value result))]
    [(eq? (strict-json-failure-code result) 'duplicate-field)
     (command-decode-failure
      'duplicate-field
      (format "JSON object contains duplicate field ~s"
              (strict-json-failure-detail result)))]
    [else
     (command-decode-failure 'malformed-json malformed-message)]))

(define (json-string->transaction-command text)
  (unless (string? text)
    (raise-argument-error
     'json-string->transaction-command
     "string?"
     text))
  (strict-json-result->command
   (strict-json-string->jsexpr text)
   "transaction command is not valid JSON"))

(define (json-bytes->transaction-command bytes)
  (unless (bytes? bytes)
    (raise-argument-error
     'json-bytes->transaction-command
     "bytes?"
     bytes))
  (strict-json-result->command
   (strict-json-bytes->jsexpr bytes)
   "transaction command is not valid UTF-8 JSON"))
