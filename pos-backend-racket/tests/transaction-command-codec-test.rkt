#lang racket

(require json
         rackunit
         "../pos/application/transaction-command.rkt"
         "../pos/domain/money.rkt"
         "../pos/persistence/transaction-command-codec.rkt")

(define start-command
  (start-transaction-command "cmd-start" "txn-001" 0))
(define scan-command
  (scan-barcode-command "cmd-scan" "txn-001" 1 "049000001234"))
(define tender-command
  (tender-cash-command "cmd-tender" "txn-001" 2 (money 500)))
(define completion-command
  (complete-transaction-command "cmd-complete" "txn-001" 3))
(define remove-command
  (remove-line-item-command "cmd-remove" "txn-001" 4 1))
(define void-command
  (void-transaction-command "cmd-void" "txn-001" 5))

(define expected-start
  (hasheq 'schema_version 1
          'command_id "cmd-start"
          'transaction_id "txn-001"
          'expected_version 0
          'command_type "start_transaction"
          'payload (hasheq)))

(define expected-scan
  (hasheq 'schema_version 1
          'command_id "cmd-scan"
          'transaction_id "txn-001"
          'expected_version 1
          'command_type "scan_barcode"
          'payload (hasheq 'barcode "049000001234")))

(define expected-tender
  (hasheq 'schema_version 1
          'command_id "cmd-tender"
          'transaction_id "txn-001"
          'expected_version 2
          'command_type "tender_cash"
          'payload (hasheq 'amount_minor_units 500)))

(define expected-completion
  (hasheq 'schema_version 1
          'command_id "cmd-complete"
          'transaction_id "txn-001"
          'expected_version 3
          'command_type "complete_transaction"
          'payload (hasheq)))

(define expected-remove
  (hasheq 'schema_version 1
          'command_id "cmd-remove"
          'transaction_id "txn-001"
          'expected_version 4
          'command_type "remove_line_item"
          'payload (hasheq 'line_index 1)))

(define expected-void
  (hasheq 'schema_version 1
          'command_id "cmd-void"
          'transaction_id "txn-001"
          'expected_version 5
          'command_type "void_transaction"
          'payload (hasheq)))

(define (check-jsexpr-failure value expected-code)
  (define result (jsexpr->transaction-command value))
  (check-pred command-decode-failure? result)
  (check-equal? (command-decode-failure-code result) expected-code)
  (check-pred string? (command-decode-failure-message result)))

(define (check-raw-json-failure text expected-code)
  (for ([result
         (in-list
          (list (json-string->transaction-command text)
                (json-bytes->transaction-command
                 (string->bytes/utf-8 text))))])
    (check-pred command-decode-failure? result)
    (check-equal? (command-decode-failure-code result) expected-code)
    (check-pred string? (command-decode-failure-message result))))

(module+ test
  (test-case "schema v1 commands encode exact golden representations"
    (check-equal? (transaction-command->jsexpr start-command) expected-start)
    (check-equal? (transaction-command->jsexpr scan-command) expected-scan)
    (check-equal? (transaction-command->jsexpr tender-command) expected-tender)
    (check-equal? (transaction-command->jsexpr completion-command)
                  expected-completion)
    (check-equal? (transaction-command->jsexpr remove-command)
                  expected-remove)
    (check-equal? (transaction-command->jsexpr void-command)
                  expected-void))

  (test-case "all schema v1 commands round trip through jsexpr, string, and bytes"
    (for ([command (in-list (list start-command
                                  scan-command
                                  tender-command
                                  completion-command
                                  remove-command
                                  void-command))])
      (define representation (transaction-command->jsexpr command))
      (define results
        (list (jsexpr->transaction-command representation)
              (json-string->transaction-command
               (transaction-command->json-string command))
              (json-bytes->transaction-command
               (transaction-command->json-bytes command))))

      (for ([result (in-list results)])
        (check-pred command-decode-success? result)
        (check-equal? (command-decode-success-command result) command))
      (check-equal? (string->jsexpr
                     (transaction-command->json-string command))
                    representation)
      (check-equal? (bytes->jsexpr
                     (transaction-command->json-bytes command))
                    representation)))

  (test-case "JSON syntax variations do not affect typed command identity"
    (define differently-ordered
      #<<JSON
{"payload":{"barcode":"049000001234"},"command_type":"scan_barcode","expected_version":1,"transaction_id":"txn-001","command_id":"cmd-scan","schema_version":1}
JSON
      )
    (define with-whitespace
      #<<JSON
  {
    "schema_version" : 1,
    "command_id" : "cmd-scan",
    "transaction_id" : "txn-001",
    "expected_version" : 1,
    "command_type" : "scan_barcode",
    "payload" : { "barcode" : "049000001234" }
  }
JSON
      )
    (define with-equivalent-escapes
      #<<JSON
{"schema_\u0076ersion":1,"command_id":"cmd\u002dscan","transaction_id":"txn\u002d001","expected_version":1,"command_type":"scan\u005fbarcode","payload":{"barcode":"04900000123\u0034"}}
JSON
      )

    (for ([text (in-list (list differently-ordered
                               with-whitespace
                               with-equivalent-escapes))])
      (define result (json-string->transaction-command text))
      (check-pred command-decode-success? result)
      (check-equal? (command-decode-success-command result) scan-command)))

  (test-case "malformed, invalid UTF-8, and trailing JSON fail predictably"
    (check-raw-json-failure "{not-json" 'malformed-json)
    (define invalid-utf8 (json-bytes->transaction-command #"\377"))
    (check-pred command-decode-failure? invalid-utf8)
    (check-equal? (command-decode-failure-code invalid-utf8)
                  'malformed-json)
    (check-raw-json-failure
     (string-append (transaction-command->json-string start-command)
                    " trailing")
     'malformed-json))

  (test-case "duplicate envelope and payload fields are rejected"
    (check-raw-json-failure
     #<<JSON
{"schema_version":999,"schema_version":1,"command_id":"cmd-start","transaction_id":"txn-001","expected_version":0,"command_type":"start_transaction","payload":{}}
JSON
     'duplicate-field)
    (check-raw-json-failure
     #<<JSON
{"schema_version":1,"command_id":"cmd-scan","transaction_id":"txn-001","expected_version":1,"command_type":"scan_barcode","payload":{"barcode":"bad","barcode":"049000001234"}}
JSON
     'duplicate-field)
    (check-raw-json-failure
     #<<JSON
{"schema_version":999,"schema_\u0076ersion":1,"command_id":"cmd-start","transaction_id":"txn-001","expected_version":0,"command_type":"start_transaction","payload":{}}
JSON
     'duplicate-field))

  (test-case "command envelope must be an exact object shape"
    (check-jsexpr-failure "start_transaction" 'expected-object)
    (for ([field (in-list '(schema_version
                            command_id
                            transaction_id
                            expected_version
                            command_type
                            payload))])
      (check-jsexpr-failure (hash-remove expected-start field)
                            'missing-field))
    (check-jsexpr-failure (hash-set expected-start 'unexpected "field")
                          'unexpected-field))

  (test-case "schema version, command type, and payload object are strict"
    (check-jsexpr-failure (hash-set expected-start 'schema_version 2)
                          'unsupported-schema-version)
    (check-jsexpr-failure (hash-set expected-start 'schema_version 1.0)
                          'invalid-field-type)
    (check-jsexpr-failure (hash-set expected-start 'command_type 1)
                          'invalid-field-type)
    (check-jsexpr-failure (hash-set expected-start
                                     'command_type
                                     "future_command")
                          'unknown-command-type)
    (check-jsexpr-failure (hash-set expected-start 'payload '())
                          'invalid-field-type))

  (test-case "common command identity fields are validated without coercion"
    (check-jsexpr-failure (hash-set expected-start 'command_id 1)
                          'invalid-field-type)
    (check-jsexpr-failure (hash-set expected-start 'command_id "")
                          'invalid-command-id)
    (check-jsexpr-failure (hash-set expected-start 'transaction_id 1)
                          'invalid-field-type)
    (check-jsexpr-failure (hash-set expected-start 'transaction_id "")
                          'invalid-transaction-id)
    (check-jsexpr-failure (hash-set expected-start 'expected_version -1)
                          'invalid-expected-version)
    (check-jsexpr-failure (hash-set expected-start 'expected_version 1.5)
                          'invalid-expected-version)
    (check-jsexpr-failure (hash-set expected-start 'expected_version "1")
                          'invalid-field-type))

  (test-case "scan payload has one required non-empty string barcode"
    (check-jsexpr-failure (hash-set expected-scan 'payload (hasheq))
                          'missing-field)
    (check-jsexpr-failure
     (hash-set expected-scan
               'payload
               (hasheq 'barcode "049000001234" 'unexpected "field"))
     'unexpected-field)
    (check-jsexpr-failure
     (hash-set expected-scan 'payload (hasheq 'barcode 49000001234))
     'invalid-field-type)
    (check-jsexpr-failure
     (hash-set expected-scan 'payload (hasheq 'barcode ""))
     'invalid-barcode))

  (test-case "tender payload accepts only exact nonnegative integer minor units"
    (for ([invalid-amount (in-list (list -1 1.5 3/2 "500"))])
      (check-jsexpr-failure
       (hash-set expected-tender
                 'payload
                 (hasheq 'amount_minor_units invalid-amount))
       'invalid-money))
    (check-jsexpr-failure (hash-set expected-tender 'payload (hasheq))
                          'missing-field)
    (check-jsexpr-failure
     (hash-set expected-tender
               'payload
               (hasheq 'amount_minor_units 500 'unexpected "field"))
     'unexpected-field))

  (test-case "empty-payload commands reject supplied payload fields"
    (for ([representation (in-list (list expected-start
                                         expected-completion
                                         expected-void))])
      (check-jsexpr-failure
       (hash-set representation 'payload (hasheq 'unexpected "field"))
       'unexpected-field)))

  (test-case "remove payload requires an exact nonnegative line index"
    (for ([invalid-index (in-list (list -1 1.5 "1"))])
      (check-jsexpr-failure
       (hash-set expected-remove
                 'payload
                 (hasheq 'line_index invalid-index))
       'invalid-line-index))
    (check-jsexpr-failure
     (hash-set expected-remove 'payload (hasheq))
     'missing-field)
    (check-jsexpr-failure
     (hash-set expected-remove
               'payload
               (hasheq 'line_index 1 'unexpected "field"))
     'unexpected-field)))
