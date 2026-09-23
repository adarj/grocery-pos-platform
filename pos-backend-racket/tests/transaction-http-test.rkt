#lang racket

(require (prefix-in db: db)
         json
         net/url
         rackunit
         racket/file
         web-server/http
         "../pos/api/server.rkt"
         "../pos/application/transaction-command.rkt"
         "../pos/application/authentication-service.rkt"
         "../pos/application/operator-service.rkt"
         "../pos/application/register-operations-service.rkt"
         "../pos/application/transaction-service.rkt"
         "../pos/application/transaction-void-approval-service.rkt"
         "../pos/domain/catalog-item.rkt"
         "../pos/domain/fake-catalog.rkt"
         "../pos/domain/money.rkt"
         "../pos/domain/tax.rkt"
         "../pos/domain/transaction-event.rkt"
         "../pos/domain/transaction-operational-context.rkt"
         "../pos/domain/transaction-void-approval.rkt"
         "../pos/persistence/sqlite-transaction-event-store.rkt"
         "../pos/persistence/operational-configuration-snapshot-codec.rkt"
         "../pos/persistence/sqlite-register-operations.rkt"
         "../pos/persistence/transaction-command-codec.rkt"
         "../pos/persistence/transaction-command-unit-of-work.rkt"
         "../pos/persistence/transaction-void-approval-store.rkt"
         "../pos/persistence/pos-database-migrations.rkt"
         "../pos/runtime-config.rkt"
         "../pos/runtime.rkt"
         "../pos/security/transaction-void-approval.rkt"
         "../pos/support/readiness.rkt"
         "support/authentication.rkt")

(define test-barcode "049000001234")
(define unknown-barcode "000000000000")
(define current-test-access-token (make-parameter #f))
(define current-test-authentication-service (make-parameter #f))
(define current-test-approval-service (make-parameter #f))

(define (test-readiness)
  (runtime-ready current-pos-database-schema-version))

(define (login-token authentication-service operator-id pin)
  (define result
    (authentication-service-login authentication-service operator-id pin))
  (unless (authentication-login-succeeded? result)
    (error 'login-token "test authentication failed"))
  (authentication-login-succeeded-access-token result))

(define (make-http-request method
                           path
                           #:body [body #f]
                           #:content-type [content-type #f]
                           #:headers [extra-headers '()])
  (request
   method
   (string->url path)
   (append
    (if content-type
        (list
         (header
          #"Content-Type"
          (if (bytes? content-type)
              content-type
              (string->bytes/utf-8 content-type))))
        '())
    (if (current-test-access-token)
        (list (test-authorization-header (current-test-access-token)))
        '())
    extra-headers)
   (delay '())
   body
   "127.0.0.1"
   7340
   "127.0.0.1"))

(define (response-bytes response)
  (define output (open-output-bytes))
  ((response-output response) output)
  (get-output-bytes output))

(define (response-json response)
  (bytes->jsexpr (response-bytes response)))

(define (response-header response name)
  (define found
    (headers-assq* name (response-headers response)))
  (and found (header-value found)))

(define (post-command app command
                      #:body [body (transaction-command->json-bytes command)]
                      #:content-type [content-type "application/json"]
                      #:approval-token [approval-token #f])
  (app
   (make-http-request
    #"POST"
    "/transaction-commands"
    #:body body
    #:content-type content-type
    #:headers
    (if approval-token
        (list (header #"X-Grocery-POS-Approval"
                      (string->bytes/utf-8 approval-token)))
        '()))))

(define (request-void-approval app command approver-id pin)
  (define response
    (app
     (make-http-request
      #"POST"
      "/approvals/transaction-void"
      #:content-type "application/json"
      #:body
      (jsexpr->bytes
       (hasheq 'command (transaction-command->jsexpr command)
               'approver_operator_id approver-id
               'approver_pin pin)))))
  (check-equal? (response-code response) 200)
  (hash-ref (hash-ref (response-json response) 'approval) 'approval_token))

(define (get-transaction app transaction-id)
  (app
   (make-http-request
    #"GET"
    (string-append "/transactions/" transaction-id))))

(define (make-test-service
         connection
         #:catalog-lookup [catalog-lookup fake-catalog-lookup]
         #:load-events [load-events load-transaction-events]
         #:commit-command!
         [commit-command! commit-transaction-command-outcome!]
         #:approval-consumer [approval-consumer #f])
  (make-transaction-service
   connection
   #:catalog-lookup catalog-lookup
   #:load-events load-events
   #:commit-command! commit-command!
   #:approval-consumer approval-consumer))

(define (call-with-http-app proc
                            #:catalog-lookup
                            [catalog-lookup fake-catalog-lookup]
                            #:load-events
                            [load-events load-transaction-events]
                            #:commit-command!
                            [commit-command! commit-transaction-command-outcome!])
  (define connection
    (db:sqlite3-connect #:database 'memory))
  (dynamic-wind
    (lambda ()
      (migrate-pos-database! connection))
    (lambda ()
      (define approval-authority
        (make-transaction-void-approval-authority
         #:issuer-instance-id "http-test-instance"
         #:current-monotonic-ms (lambda () 1000)
         #:current-epoch-ms (lambda () 500000)))
      (define service
        (make-test-service
         connection
         #:catalog-lookup catalog-lookup
         #:load-events load-events
         #:commit-command! commit-command!
         #:approval-consumer
         (lambda (approval-connection capability requester command)
           (consume-transaction-void-approval!/in-transaction!
            approval-connection capability "http-test-instance" requester
            command 2000))))
      (define auth-service (make-test-authentication-service connection))
      (db:query-exec
       connection
       "INSERT INTO operators VALUES ('http-supervisor', 'HTTP Supervisor', 1)")
      (db:query-exec
       connection
       "INSERT INTO operator_roles VALUES ('http-supervisor', 'supervisor')")
      (db:query-exec
       connection
       #<<SQL
INSERT INTO operator_pin_credentials
SELECT 'http-supervisor', password_hash, 1
FROM operator_pin_credentials
WHERE operator_id = ?
SQL
       test-operator-id)
      (define approval-service
        (make-transaction-void-approval-service
         auth-service service approval-authority))
      (define access-token (issue-test-access-token auth-service))
      (parameterize
          ([current-test-access-token access-token]
           [current-test-authentication-service auth-service]
           [current-test-approval-service approval-service])
        (proc connection
              service
              (make-app
               service
               #:authentication-service auth-service
               #:transaction-void-approval-service approval-service
               #:readiness-probe test-readiness))))
    (lambda ()
      (db:disconnect connection))))

(define (error-result response)
  (hash-ref (response-json response) 'error))

(define (check-command-result response
                              status
                              ok?
                              command-id
                              transaction-id
                              outcome-kind
                              outcome-code
                              outcome-version)
  (check-equal? (response-code response) status)
  (define body (response-json response))
  (check-equal? (hash-ref body 'ok) ok?)
  (check-equal?
   (hash-ref body 'command_result)
   (hasheq 'command_id command-id
           'transaction_id transaction-id
           'outcome_kind outcome-kind
           'outcome_code outcome-code
           'outcome_stream_version outcome-version)))

(define (accepted-start app transaction-id [command-id "cmd-start"])
  (define command
    (start-transaction-command command-id transaction-id 0))
  (define response (post-command app command))
  (check-command-result response
                        200 #t
                        command-id transaction-id
                        "accepted" "accepted" 1)
  command)

(define (accepted-scan app transaction-id version command-id)
  (define command
    (scan-barcode-command
     command-id transaction-id version test-barcode))
  (define response (post-command app command))
  (check-command-result response
                        200 #t
                        command-id transaction-id
                        "accepted" "accepted" (add1 version))
  command)

(define (event-count connection transaction-id event-type)
  (db:query-value
   connection
   #<<SQL
SELECT COUNT(*)
FROM transaction_events
WHERE transaction_id = ? AND event_type = ?
SQL
   transaction-id
   event-type))

(define (receipt-count connection command-id)
  (db:query-value
   connection
   "SELECT COUNT(*) FROM transaction_command_receipts WHERE command_id = ?"
   command-id))

(define (install-http-approval! connection command [token-character #\a])
  (define token
    (string-append "gpos_a1_" (make-string 64 token-character)))
  (define capability (transaction-void-approval-token->capability token))
  (db:call-with-transaction
   connection
   (lambda ()
     (replace-transaction-void-approval-grant!/in-transaction!
      connection
      (transaction-void-approval-grant
       (string-append "approval-" (string token-character))
       (transaction-void-approval-capability-token-digest capability)
       "http-test-instance"
       test-operator-id
       "http-supervisor"
       1
       (transaction-command-command-id command)
       (transaction-command-transaction-id command)
       1
       (transaction-command-expected-version command)
       1000 91000 590000)
      "http-test-instance"
      1000))
   #:option 'immediate)
  token)

(define (check-safe-error response status code)
  (check-equal? (response-code response) status)
  (define body (response-json response))
  (check-false (hash-ref body 'ok))
  (check-equal? (hash-ref (hash-ref body 'error) 'code) code))

(module+ test
  (test-case "health and unknown routes retain safe behavior"
    (call-with-http-app
     (lambda (_connection _service app)
       (define health
         (app (make-http-request #"GET" "/health")))
       (check-equal? (response-code health) 200)
       (check-true (hash-ref (response-json health) 'ok))

       (define missing
         (app (make-http-request #"GET" "/does-not-exist")))
       (check-safe-error missing 404 "not_found")
       (check-equal? (hash-ref (error-result missing) 'message)
                     "Route not found."))))

  (test-case "complete accepted cash workflow maps all command variants"
    (call-with-http-app
     (lambda (connection _service app)
       (accepted-start app "txn-workflow")
       (accepted-scan app "txn-workflow" 1 "cmd-scan")

       (define tender
         (tender-cash-command
          "cmd-tender" "txn-workflow" 2 (money 500)))
       (check-command-result
        (post-command app tender)
        200 #t "cmd-tender" "txn-workflow"
        "accepted" "accepted" 3)

       (define completion
         (complete-transaction-command
          "cmd-complete" "txn-workflow" 3))
       (check-command-result
        (post-command app completion)
        200 #t "cmd-complete" "txn-workflow"
        "accepted" "accepted" 4)

       (check-equal?
        (db:query-list
         connection
         #<<SQL
SELECT event_type
FROM transaction_events
WHERE transaction_id = 'txn-workflow'
ORDER BY stream_sequence
SQL
         )
        '("transaction_started"
          "sale_item_added"
          "cash_tendered"
          "transaction_completed")))))

  (test-case "same command retry returns identical response and one fact"
    (call-with-http-app
     (lambda (connection _service app)
       (accepted-start app "txn-retry")
       (define command
         (scan-barcode-command
          "cmd-retry" "txn-retry" 1 test-barcode))
       (define first (post-command app command))
       (define retry (post-command app command))

       (check-equal? (response-code retry) (response-code first))
       (check-equal? (response-json retry) (response-json first))
       (check-equal?
        (event-count connection "txn-retry" "sale_item_added")
        1)
       (check-equal? (receipt-count connection "cmd-retry") 1)
       (check-false
        (hash-has-key? (response-json retry) 'transaction)))))

  (test-case "delayed retry preserves original version after later command"
    (call-with-http-app
     (lambda (connection _service app)
       (accepted-start app "txn-delayed")
       (define scan
         (accepted-scan app "txn-delayed" 1 "cmd-delayed-scan"))
       (define original (post-command app scan))
       (define tender
         (tender-cash-command
          "cmd-delayed-tender" "txn-delayed" 2 (money 500)))
       (check-equal? (response-code (post-command app tender)) 200)

       (define delayed (post-command app scan))
       (check-equal? (response-json delayed) (response-json original))
       (check-command-result
        delayed
        200 #t "cmd-delayed-scan" "txn-delayed"
        "accepted" "accepted" 2)
       (check-equal?
        (event-count connection "txn-delayed" "sale_item_added")
        1)
       (check-equal?
        (db:query-value
         connection
         "SELECT MAX(stream_sequence) FROM transaction_events WHERE transaction_id = 'txn-delayed'")
        3)
       (check-false
        (hash-has-key? (response-json original) 'transaction)))))

  (test-case "same command ID with different command maps to reuse"
    (call-with-http-app
     (lambda (connection _service app)
       (accepted-start app "txn-reuse")
       (define original
         (scan-barcode-command
          "cmd-reused" "txn-reuse" 1 test-barcode))
       (check-equal? (response-code (post-command app original)) 200)
       (define changed
         (scan-barcode-command
          "cmd-reused" "txn-reuse" 1 unknown-barcode))
       (define response (post-command app changed))

       (check-safe-error response 409 "command_id_reused")
       (check-equal?
        (hash-ref (error-result response) 'message)
        "Command ID is already associated with a different command.")
       (check-equal?
        (event-count connection "txn-reuse" "sale_item_added")
        1)
       (check-equal? (receipt-count connection "cmd-reused") 1)
       (check-false
        (hash-has-key? (error-result response) 'transaction_id)))))

  (test-case "deterministic domain rejection is durable and retry-stable"
    (call-with-http-app
     (lambda (connection _service app)
       (accepted-start app "txn-rejected")
       (define command
         (scan-barcode-command
          "cmd-rejected" "txn-rejected" 1 unknown-barcode))
       (define first (post-command app command))
       (define retry (post-command app command))

       (check-command-result
        first
        409 #f "cmd-rejected" "txn-rejected"
        "domain_rejected" "unknown_barcode" 1)
       (check-equal? (response-json retry) (response-json first))
       (check-equal?
        (event-count connection "txn-rejected" "sale_item_added")
        0))))

  (test-case "stale, missing, and already-existing outcomes map explicitly"
    (call-with-http-app
     (lambda (connection _service app)
       (accepted-start app "txn-outcomes")
       (accepted-scan app "txn-outcomes" 1 "cmd-outcomes-scan")

       (define stale
         (scan-barcode-command
          "cmd-stale" "txn-outcomes" 1 test-barcode))
       (check-command-result
        (post-command app stale)
        409 #f "cmd-stale" "txn-outcomes"
        "version_conflict" "stale_expected_version" 2)

       (define missing
         (scan-barcode-command
          "cmd-missing" "txn-missing" 0 test-barcode))
       (check-command-result
        (post-command app missing)
        404 #f "cmd-missing" "txn-missing"
        "not_found" "transaction_not_found" 0)

       (define existing
         (start-transaction-command
          "cmd-existing" "txn-outcomes" 0))
       (check-command-result
        (post-command app existing)
        409 #f "cmd-existing" "txn-outcomes"
        "already_exists" "transaction_already_exists" 2)

       (check-equal?
        (event-count connection "txn-outcomes" "sale_item_added")
        1)
       (check-equal?
        (event-count connection "txn-missing" "sale_item_added")
        0))))

  (test-case "strict command codec failures map to stable safe reasons"
    (call-with-http-app
     (lambda (_connection _service app)
       (define cases
         (list
          (cons #"{" "malformed_json")
          (cons (bytes #xff) "malformed_json")
          (cons
           #"{\"schema_version\":1,\"schema_version\":1,\"command_id\":\"cmd\",\"transaction_id\":\"txn\",\"expected_version\":0,\"command_type\":\"start_transaction\",\"payload\":{}}"
           "duplicate_field")
          (cons
           #"{\"schema_version\":1,\"command_id\":\"cmd\",\"transaction_id\":\"txn\",\"expected_version\":1,\"command_type\":\"scan_barcode\",\"payload\":{\"barcode\":\"a\",\"barcode\":\"b\"}}"
           "duplicate_field")
          (cons
           #"{\"schema_version\":1,\"command_id\":\"cmd\",\"transaction_id\":\"txn\",\"expected_version\":0,\"command_type\":\"start_transaction\"}"
           "missing_field")
          (cons
           #"{\"schema_version\":1,\"command_id\":\"cmd\",\"transaction_id\":\"txn\",\"expected_version\":0,\"command_type\":\"start_transaction\",\"payload\":{},\"extra\":true}"
           "unexpected_field")
          (cons
           #"{\"schema_version\":2,\"command_id\":\"cmd\",\"transaction_id\":\"txn\",\"expected_version\":0,\"command_type\":\"start_transaction\",\"payload\":{}}"
           "unsupported_schema_version")
          (cons
           #"{\"schema_version\":1,\"command_id\":\"cmd\",\"transaction_id\":\"txn\",\"expected_version\":0,\"command_type\":\"invented\",\"payload\":{}}"
           "unknown_command_type")))

       (for ([case (in-list cases)])
         (define response
           (app
            (make-http-request
             #"POST" "/transaction-commands"
             #:body (car case)
             #:content-type "application/json")))
         (check-safe-error response 400 "invalid_transaction_command")
         (check-equal? (hash-ref (error-result response) 'reason)
                       (cdr case))
         (check-false
          (regexp-match? #rx"\"cmd\"|\"txn\"|\"barcode\":\"a\""
                         (bytes->string/utf-8
                          (response-bytes response))))))))

  (test-case "empty body and media type policy are explicit"
    (call-with-http-app
     (lambda (_connection _service app)
       (for ([body (in-list (list #f #""))])
         (define empty
           (app
            (make-http-request
             #"POST" "/transaction-commands"
             #:body body
             #:content-type "application/json")))
         (check-safe-error empty 400 "invalid_transaction_command")
         (check-equal? (hash-ref (error-result empty) 'reason)
                       "missing_body"))

       (for ([content-type (in-list '(#f "" "text/plain"))])
         (define response
           (app
            (make-http-request
             #"POST" "/transaction-commands"
             #:body #"{}"
             #:content-type content-type)))
         (check-safe-error response 415 "unsupported_media_type"))

       (define command
         (start-transaction-command "cmd-charset" "txn-charset" 0))
       (define accepted
         (post-command
          app command
          #:content-type "application/json; charset=utf-8"))
       (check-equal? (response-code accepted) 200))))

  (test-case "query serializes open and scanned state with exact money"
    (call-with-http-app
     (lambda (_connection _service app)
       (accepted-start app "txn-query")
       (define open-response (get-transaction app "txn-query"))
       (check-equal? (response-code open-response) 200)
       (check-equal?
        (hash-ref (response-json open-response) 'transaction)
        (hasheq
         'transaction_id "txn-query"
         'owned_by_authenticated_operator #f
         'version 1
         'status "open"
         'line_items '()
         'subtotal_minor_units 0
         'tax_minor_units 0
         'total_minor_units 0
         'tendered_cash_minor_units 'null
         'change_due_minor_units 'null))

       (accepted-scan app "txn-query" 1 "cmd-query-scan")
       (define scanned
         (hash-ref (response-json (get-transaction app "txn-query"))
                   'transaction))
       (check-equal? (hash-ref scanned 'version) 2)
       (check-equal? (hash-ref scanned 'status) "open")
       (check-equal? (hash-ref scanned 'subtotal_minor_units) 199)
       (check-equal? (hash-ref scanned 'tax_minor_units) 0)
       (check-equal? (hash-ref scanned 'total_minor_units) 199)
       (check-equal?
        (hash-ref scanned 'line_items)
        (list
         (hasheq 'barcode test-barcode
                 'description "Test Apples"
                 'unit_price_minor_units 199)))
       (check-false (hash-has-key? scanned 'events))
       (check-false (hash-has-key? scanned 'command_receipts)))))

  (test-case "query exposes exact authoritative tax through all sale states"
    (define taxed-item
      (catalog-item test-barcode
                    "Taxed Apples"
                    (money 199)
                    "standard"
                    (tax-rate 100000)))
    (call-with-http-app
     #:catalog-lookup (lambda (_barcode) taxed-item)
     (lambda (_connection _service app)
       (accepted-start app "txn-tax-query")
       (accepted-scan app "txn-tax-query" 1 "cmd-tax-query-scan")
       (define open
         (hash-ref (response-json (get-transaction app "txn-tax-query"))
                   'transaction))
       (check-equal? (hash-ref open 'subtotal_minor_units) 199)
       (check-equal? (hash-ref open 'tax_minor_units) 20)
       (check-equal? (hash-ref open 'total_minor_units) 219)

       (check-equal?
        (response-code
         (post-command
          app
          (tender-cash-command
           "cmd-tax-query-tender" "txn-tax-query" 2 (money 500))))
        200)
       (define paid
         (hash-ref (response-json (get-transaction app "txn-tax-query"))
                   'transaction))
       (check-equal? (hash-ref paid 'tax_minor_units) 20)
       (check-equal? (hash-ref paid 'change_due_minor_units) 281)

       (check-equal?
        (response-code
         (post-command
          app
          (complete-transaction-command
           "cmd-tax-query-complete" "txn-tax-query" 3)))
        200)
       (define completed
         (hash-ref (response-json (get-transaction app "txn-tax-query"))
                   'transaction))
       (check-equal? (hash-ref completed 'tax_minor_units) 20)
       (check-equal? (hash-ref completed 'total_minor_units) 219))))

  (test-case "query treats historical schema v1 sale items as zero tax"
    (call-with-http-app
     (lambda (connection _service app)
       (define appended
         (append-transaction-events!
          connection
          "txn-legacy-tax-query"
          0
          (list
           (transaction-started "txn-legacy-tax-query")
           (sale-item-added test-barcode "Legacy Apples" (money 199)))))
       (check-pred journal-append-succeeded? appended)
       (define transaction
         (hash-ref
          (response-json (get-transaction app "txn-legacy-tax-query"))
          'transaction))
       (check-equal? (hash-ref transaction 'subtotal_minor_units) 199)
       (check-equal? (hash-ref transaction 'tax_minor_units) 0)
       (check-equal? (hash-ref transaction 'total_minor_units) 199))))

  (test-case "query serializes paid and completed tender state"
    (call-with-http-app
     (lambda (_connection _service app)
       (accepted-start app "txn-paid")
       (accepted-scan app "txn-paid" 1 "cmd-paid-scan")
       (define tender
         (tender-cash-command "cmd-paid" "txn-paid" 2 (money 500)))
       (check-equal? (response-code (post-command app tender)) 200)

       (define paid
         (hash-ref (response-json (get-transaction app "txn-paid"))
                   'transaction))
       (check-equal? (hash-ref paid 'status) "paid")
       (check-equal? (hash-ref paid 'version) 3)
       (check-equal? (hash-ref paid 'tendered_cash_minor_units) 500)
       (check-equal? (hash-ref paid 'change_due_minor_units) 301)
       (check-true (exact-integer? (hash-ref paid 'total_minor_units)))

       (define completion
         (complete-transaction-command
          "cmd-paid-complete" "txn-paid" 3))
       (check-equal? (response-code (post-command app completion)) 200)
       (define completed
         (hash-ref (response-json (get-transaction app "txn-paid"))
                   'transaction))
       (check-equal? (hash-ref completed 'status) "completed")
       (check-equal? (hash-ref completed 'version) 4)
       (check-equal? (hash-ref completed 'tendered_cash_minor_units) 500)
       (check-equal? (hash-ref completed 'change_due_minor_units) 301))))

  (test-case "remove command returns durable outcomes and authoritative basket"
    (call-with-http-app
     (lambda (_connection _service app)
       (accepted-start app "txn-http-remove")
       (for ([index (in-range 3)])
         (accepted-scan app
                        "txn-http-remove"
                        (add1 index)
                        (format "cmd-http-remove-scan-~a" index)))
       (define remove-command
         (remove-line-item-command
          "cmd-http-remove" "txn-http-remove" 4 1))
       (check-command-result
        (post-command app remove-command)
        200 #t "cmd-http-remove" "txn-http-remove"
        "accepted" "accepted" 5)

       (define transaction
         (hash-ref (response-json (get-transaction app "txn-http-remove"))
                   'transaction))
       (check-equal? (hash-ref transaction 'version) 5)
       (check-equal? (length (hash-ref transaction 'line_items)) 2)
       (check-equal? (hash-ref transaction 'subtotal_minor_units) 398)
       (check-equal? (hash-ref transaction 'tax_minor_units) 0)
       (check-equal? (hash-ref transaction 'total_minor_units) 398)

       (check-command-result
        (post-command
         app
         (remove-line-item-command
          "cmd-http-remove-miss" "txn-http-remove" 5 9))
        409 #f "cmd-http-remove-miss" "txn-http-remove"
        "domain_rejected" "line_item_not_found" 5)
       (check-command-result
        (post-command
         app
         (remove-line-item-command
          "cmd-http-remove-stale" "txn-http-remove" 4 0))
        409 #f "cmd-http-remove-stale" "txn-http-remove"
        "version_conflict" "stale_expected_version" 5))))

  (test-case "approved void command produces an authoritative terminal projection"
    (call-with-http-app
     (lambda (connection _service app)
       (accepted-start app "txn-http-void")
       (accepted-scan app "txn-http-void" 1 "cmd-http-void-scan")
       (define void-command
         (void-transaction-command
          "cmd-http-void" "txn-http-void" 2))
       (check-safe-error
        (post-command app void-command)
        403
        "approval_required")
       (check-equal? (receipt-count connection "cmd-http-void") 0)
       (check-command-result
        (post-command
         app void-command
         #:approval-token (install-http-approval! connection void-command))
        200 #t "cmd-http-void" "txn-http-void"
        "accepted" "accepted" 3)

       (define transaction
         (hash-ref (response-json (get-transaction app "txn-http-void"))
                   'transaction))
       (check-equal? (hash-ref transaction 'status) "voided")
       (check-equal? (length (hash-ref transaction 'line_items)) 1)
       (check-equal? (hash-ref transaction 'subtotal_minor_units) 199)
       (check-equal? (hash-ref transaction 'tax_minor_units) 0)
       (check-equal? (hash-ref transaction 'total_minor_units) 199)
       (check-equal? (hash-ref transaction 'tendered_cash_minor_units) 'null)
       (check-equal? (hash-ref transaction 'change_due_minor_units) 'null)

       (define again
         (void-transaction-command
          "cmd-http-void-again" "txn-http-void" 3))
       (check-command-result
        (post-command
         app again
         #:approval-token (install-http-approval! connection again #\b))
        409 #f "cmd-http-void-again" "txn-http-void"
        "domain_rejected" "invalid_transaction_state" 3))))

  (test-case "approval endpoint authenticates a separate approver without switching session"
    (call-with-http-app
     (lambda (connection _service app)
       (check-pred
        journal-append-succeeded?
        (append-transaction-events!
         connection
         "txn-approval-http"
         0
         (list
          (operational-transaction-started
           "txn-approval-http"
           (transaction-operational-context
            "register-http" "HTTP Register"
            test-operator-id "HTTP Test Operator"
            "shift-http" 1000)))))
       (define command
         (void-transaction-command
          "cmd-approval-http" "txn-approval-http" 1))
       (define token
         (request-void-approval
          app command "http-supervisor" test-operator-pin))
       (check-regexp-match #px"^gpos_a1_[0-9a-f]{64}$" token)
       (define session-response
         (app (make-http-request #"GET" "/auth/session")))
       (check-equal? (response-code session-response) 200)
       (check-equal?
        (hash-ref
         (hash-ref (response-json session-response) 'session)
         'operator_id)
        test-operator-id)
       (check-equal?
        (db:query-value
         connection
         "SELECT approver_operator_id FROM transaction_void_approval_grants WHERE command_id = 'cmd-approval-http'")
        "http-supervisor"))))

  (test-case "unexpected and duplicate approval headers never consume the scoped grant"
    (call-with-http-app
     (lambda (connection _service app)
       (accepted-start app "txn-approval-header")
       (define void-command
         (void-transaction-command
          "cmd-approval-header-void" "txn-approval-header" 1))
       (define token (install-http-approval! connection void-command))
       (define scan-command
         (scan-barcode-command
          "cmd-approval-header-scan" "txn-approval-header" 1 test-barcode))
       (check-safe-error
        (post-command app scan-command #:approval-token token)
        400 "unexpected_approval")
       (check-equal? (receipt-count connection "cmd-approval-header-scan") 0)
       (check-safe-error
        (app
         (make-http-request
          #"POST" "/transaction-commands"
          #:content-type "application/json"
          #:body (transaction-command->json-bytes void-command)
          #:headers
          (list (header #"X-Grocery-POS-Approval"
                        (string->bytes/utf-8 token))
                (header #"X-Grocery-POS-Approval"
                        (string->bytes/utf-8 token)))))
        400 "invalid_approval")
       (check-equal?
        (db:query-value connection
                        "SELECT COUNT(*) FROM transaction_void_approval_grants WHERE command_id = 'cmd-approval-header-void'")
        1)
       (check-command-result
        (post-command app void-command #:approval-token token)
        200 #t "cmd-approval-header-void" "txn-approval-header"
        "accepted" "accepted" 2))))

  (test-case "malformed correction payloads fail before command execution"
    (call-with-http-app
     (lambda (_connection _service app)
       (for ([body
              (in-list
               (list
                #"{\"schema_version\":1,\"command_id\":\"cmd\",\"transaction_id\":\"txn\",\"expected_version\":1,\"command_type\":\"remove_line_item\",\"payload\":{\"line_index\":-1}}"
                #"{\"schema_version\":1,\"command_id\":\"cmd\",\"transaction_id\":\"txn\",\"expected_version\":1,\"command_type\":\"remove_line_item\",\"payload\":{\"line_index\":1.5}}"))])
         (define response
           (post-command
            app
            (start-transaction-command "unused" "unused" 0)
            #:body body))
         (check-safe-error response 400 "invalid_transaction_command")
         (check-equal? (hash-ref (error-result response) 'reason)
                       "invalid_line_index"))

       (define unexpected-void
         (post-command
          app
          (start-transaction-command "unused" "unused" 0)
          #:body
          #"{\"schema_version\":1,\"command_id\":\"cmd\",\"transaction_id\":\"txn\",\"expected_version\":1,\"command_type\":\"void_transaction\",\"payload\":{\"unexpected\":true}}"))
       (check-safe-error unexpected-void 400 "invalid_transaction_command")
       (check-equal? (hash-ref (error-result unexpected-void) 'reason)
                     "unexpected_field"))))

  (test-case "query not found and recovery failure are safe"
    (call-with-http-app
     (lambda (connection _service app)
       (check-safe-error
        (get-transaction app "txn-absent")
        404
        "transaction_not_found")

       (accepted-start app "txn-corrupt")
       (db:query-exec
        connection
        #<<SQL
INSERT INTO transaction_events
  (transaction_id, stream_sequence, schema_version, event_type, event_json)
VALUES ('txn-corrupt', 2, 1, 'sale_item_added', '{secret-corrupt-json')
SQL
        )
       (define response (get-transaction app "txn-corrupt"))
       (check-safe-error response 500 "transaction_recovery_failed")
       (check-false
        (regexp-match? #rx"secret-corrupt-json"
                       (bytes->string/utf-8 (response-bytes response)))))))

  (test-case "mutation recovery failure is safe"
    (call-with-http-app
     (lambda (connection _service app)
       (accepted-start app "txn-command-corrupt")
       (db:query-exec
        connection
        #<<SQL
INSERT INTO transaction_events
  (transaction_id, stream_sequence, schema_version, event_type, event_json)
VALUES ('txn-command-corrupt', 2, 1, 'sale_item_added', '{secret-command-corruption')
SQL
        )
       (define command
         (scan-barcode-command
          "cmd-corrupt" "txn-command-corrupt" 1 test-barcode))
       (define response (post-command app command))
       (check-safe-error response 500 "transaction_recovery_failed")
       (check-equal? (receipt-count connection "cmd-corrupt") 0)
       (check-false
        (regexp-match? #rx"secret-command-corruption"
                       (bytes->string/utf-8 (response-bytes response)))))))

  (test-case "stable command persistence failure is safe and retryable"
    (call-with-http-app
     #:commit-command!
     (lambda (_connection _plan)
       (transaction-command-commit-failed
        'receipt-insert-conflict
        'secret-internal-detail
        "secret persistence message"))
     (lambda (_connection _service app)
       (define response
         (post-command
          app
          (start-transaction-command
           "cmd-persistence" "txn-persistence" 0)))
       (check-safe-error response 500 "command_persistence_failed")
       (check-true
        (hash-ref (error-result response) 'retry_same_command_id))
       (check-false
        (regexp-match? #rx"secret"
                       (bytes->string/utf-8 (response-bytes response)))))))

  (test-case "unexpected command exception becomes unknown outcome"
    (call-with-http-app
     #:commit-command!
     (lambda (_connection _plan)
       (error 'commit "secret pre-commit exception"))
     (lambda (connection _service app)
       (define response
         (post-command
          app
          (start-transaction-command "cmd-unknown" "txn-unknown" 0)))
       (check-safe-error response 500 "command_outcome_unknown")
       (check-true
        (hash-ref (error-result response) 'retry_same_command_id))
       (check-equal? (receipt-count connection "cmd-unknown") 0)
       (check-equal?
        (event-count connection "txn-unknown" "transaction_started")
        0)
       (check-false
        (regexp-match? #rx"secret"
                       (bytes->string/utf-8 (response-bytes response)))))))

  (test-case "post-commit response loss resolves through same HTTP command"
    (define committed? #f)
    (call-with-http-app
     #:commit-command!
     (lambda (connection plan)
       (commit-transaction-command-outcome! connection plan)
       (set! committed? #t)
       (error 'transport "secret response was lost after commit"))
     (lambda (connection _service uncertain-app)
       (define command
         (start-transaction-command
          "cmd-lost-response" "txn-lost-response" 0))
       (define uncertain (post-command uncertain-app command))
       (check-true committed?)
       (check-safe-error uncertain 500 "command_outcome_unknown")

       (define normal-service (make-test-service connection))
       (define retry
         (post-command
          (make-app
           normal-service
           #:authentication-service (current-test-authentication-service)
           #:readiness-probe test-readiness)
          command))
       (check-command-result
        retry
        200 #t "cmd-lost-response" "txn-lost-response"
        "accepted" "accepted" 1)
       (check-equal?
        (event-count
         connection "txn-lost-response" "transaction_started")
        1)
       (check-equal? (receipt-count connection "cmd-lost-response") 1))))

  (test-case "unexpected query exception is hidden"
    (call-with-http-app
     #:load-events
     (lambda (_connection _transaction-id)
       (error 'load "secret query exception"))
     (lambda (_connection _service app)
       (define response (get-transaction app "txn-error"))
       (check-safe-error response 500 "internal_error")
       (check-false
        (regexp-match? #rx"secret"
                       (bytes->string/utf-8 (response-bytes response)))))))

  (test-case "recognized wrong methods return Allow and malformed shapes stay 404"
    (define load-count 0)
    (call-with-http-app
     #:load-events
     (lambda (connection transaction-id)
       (set! load-count (add1 load-count))
       (load-transaction-events connection transaction-id))
     (lambda (_connection _service app)
       (for ([case (in-list
                    (list
                     (list #"GET" "/transaction-commands" #"POST")
                     (list #"POST" "/transactions/txn-001" #"GET")
                     (list #"POST" "/health" #"GET")))])
         (define response
           (app (make-http-request (first case) (second case))))
         (check-safe-error response 405 "method_not_allowed")
         (check-equal? (response-header response #"Allow") (third case)))

       (for ([path (in-list '("/transactions"
                              "/transactions/"
                              "/transactions/a/b"))])
         (check-safe-error
          (app (make-http-request #"GET" path))
          404
          "not_found"))
       (check-equal? load-count 0))))

  (test-case "file-backed runtime restart preserves HTTP retry and query state"
    (define directory
      (make-temporary-file "transaction-http-restart-~a" 'directory))
    (define database-path (build-path directory "pos.db"))
    (define config
      (pos-runtime-config "127.0.0.1" 7340 database-path))
    (define start-command
      (start-transaction-command "cmd-runtime-start" "txn-runtime" 0))
    (define scan-command
      (scan-barcode-command
       "cmd-runtime-scan" "txn-runtime" 1 test-barcode))
    (dynamic-wind
      void
      (lambda ()
        (initialize-sqlite-database! database-path)
        (define seed-connection
          (db:sqlite3-connect
           #:database database-path #:mode 'read/write))
        (dynamic-wind
          void
          (lambda ()
            (define decoded
              (json-string->operational-configuration-snapshot
               "{\"schema_version\":1,\"register\":{\"register_id\":\"http-register\",\"display_name\":\"HTTP Register\"},\"cashiers\":[{\"cashier_id\":\"http-cashier\",\"display_name\":\"HTTP Cashier\",\"active\":true}]}"))
            (activate-operational-configuration!
             seed-connection
             (operational-configuration-decode-success-snapshot decoded))
            (define enrollment
              (operator-service-enroll-pin
               (make-operator-service seed-connection)
               "http-cashier"
               test-operator-pin))
            (unless (operator-pin-enrollment-succeeded? enrollment)
              (error 'transaction-http-test "operator enrollment failed"))
            (register-operations-open-shift
             (make-register-operations-service
              seed-connection
             #:current-epoch-ms (lambda () 1000)
              #:generate-shift-id (lambda () "shift-http"))
             (authenticated-operator
              "http-cashier" "HTTP Cashier" 'cashier)
             (money 0)))
          (lambda () (db:disconnect seed-connection)))
        (define runtime-A
          (start-pos-runtime
           config
           #:catalog-lookup fake-catalog-lookup))
        (define original-scan
          (dynamic-wind
            void
            (lambda ()
              (define app-A
                (make-app
                 (pos-runtime-transaction-service runtime-A)
                 #:authentication-service
                 (pos-runtime-authentication-service runtime-A)
                 #:readiness-probe
                 (lambda () (pos-runtime-readiness runtime-A))))
              (define token-A
                (login-token
                 (pos-runtime-authentication-service runtime-A)
                 "http-cashier"
                 test-operator-pin))
              (parameterize ([current-test-access-token token-A])
                (check-equal?
                 (response-code (post-command app-A start-command)) 200)
                (define response (post-command app-A scan-command))
                (check-equal? (response-code response) 200)
                (response-json response)))
            (lambda ()
              (stop-pos-runtime! runtime-A))))

        (define runtime-B
          (start-pos-runtime
           config
           #:catalog-lookup fake-catalog-lookup))
        (dynamic-wind
          void
          (lambda ()
            (define app-B
              (make-app
               (pos-runtime-transaction-service runtime-B)
               #:authentication-service
               (pos-runtime-authentication-service runtime-B)
               #:readiness-probe
               (lambda () (pos-runtime-readiness runtime-B))))
            (define token-B
              (login-token
               (pos-runtime-authentication-service runtime-B)
               "http-cashier"
               test-operator-pin))
            (parameterize ([current-test-access-token token-B])
              (define retry (post-command app-B scan-command))
              (check-equal? (response-json retry) original-scan)
              (define query (get-transaction app-B "txn-runtime"))
              (check-equal? (response-code query) 200)
              (define transaction
                (hash-ref (response-json query) 'transaction))
              (check-equal? (hash-ref transaction 'version) 2)
              (check-equal? (hash-ref transaction 'subtotal_minor_units) 199)
              (check-equal? (length (hash-ref transaction 'line_items)) 1))

            (define connection
              (db:sqlite3-connect
               #:database database-path #:mode 'read/write))
            (dynamic-wind
              void
              (lambda ()
                (check-equal?
                 (event-count connection "txn-runtime" "sale_item_added")
                 1)
                (check-equal?
                 (receipt-count connection "cmd-runtime-scan")
                 1))
              (lambda ()
                (db:disconnect connection))))
          (lambda ()
            (stop-pos-runtime! runtime-B))))
      (lambda ()
        (delete-directory/files directory))))
)
