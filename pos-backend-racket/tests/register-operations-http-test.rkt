#lang racket

(require (prefix-in db: db)
         json
         net/url
         rackunit
         web-server/http
         "../pos/api/server.rkt"
         "../pos/application/register-operations-service.rkt"
         "../pos/application/transaction-service.rkt"
         "../pos/application/transaction-command.rkt"
         "../pos/domain/fake-catalog.rkt"
         "../pos/domain/transaction-void-approval.rkt"
         "../pos/persistence/operational-configuration-snapshot-codec.rkt"
         "../pos/persistence/pos-database-migrations.rkt"
         "../pos/persistence/sqlite-register-operations.rkt"
         "../pos/persistence/transaction-void-approval-store.rkt"
         "../pos/security/transaction-void-approval.rkt"
         "../pos/support/readiness.rkt"
         "support/authentication.rkt")

(define config-json
  "{\"schema_version\":1,\"register\":{\"register_id\":\"register-one\",\"display_name\":\"Register One\"},\"cashiers\":[{\"cashier_id\":\"__http_test_operator__\",\"display_name\":\"HTTP Test Operator\",\"active\":true},{\"cashier_id\":\"inactive\",\"display_name\":\"Inactive\",\"active\":false}]}")
(define test-access-token (box #f))
(define test-approval-token (box #f))

(define (request* method path [body #f])
  (request method
           (string->url path)
           (append
            (if body (list (header #"Content-Type" #"application/json")) '())
            (if (unbox test-access-token)
                (list (test-authorization-header (unbox test-access-token)))
                '())
            (if (unbox test-approval-token)
                (list (header #"X-Grocery-POS-Approval"
                              (string->bytes/utf-8 (unbox test-approval-token))))
                '()))
           (delay '())
           body
           "127.0.0.1" 7340 "127.0.0.1"))

(define (body response)
  (define out (open-output-bytes))
  ((response-output response) out)
  (bytes->jsexpr (get-output-bytes out)))

(define (post app path value)
  (app (request* #"POST" path (jsexpr->bytes value))))

(define (error-code response)
  (hash-ref (hash-ref (body response) 'error) 'code))

(module+ test
  (define connection (db:sqlite3-connect #:database 'memory))
  (migrate-pos-database! connection)
  (define clock-values (box '(1000 2000)))
  (define register-service
    (make-register-operations-service
     connection
     #:current-epoch-ms
     (lambda ()
       (define value (first (unbox clock-values)))
       (set-box! clock-values (rest (unbox clock-values)))
       value)
     #:generate-shift-id (lambda () "shift-one")))
  (define auth-service
    (make-test-authentication-service connection #:role 'cashier))
  (set-box! test-access-token (issue-test-access-token auth-service))
  (define app
    (make-app
     (make-transaction-service
     connection
      #:catalog-lookup fake-catalog-lookup
      #:current-epoch-ms (lambda () 1500)
      #:approval-consumer
      (lambda (approval-connection capability requester revision command)
        (consume-transaction-void-approval!/in-transaction!
         approval-connection capability "http-test-instance" requester revision
         command 2000)))
     register-service
     #:authentication-service auth-service
     #:readiness-probe
     (lambda () (runtime-ready current-pos-database-schema-version))))

  (test-case "register context reports legitimate unconfigured state"
    (define response (app (request* #"GET" "/register-context")))
    (check-equal? (response-code response) 200)
    (check-equal?
     (hash-ref (body response) 'register_context)
     (hasheq 'configured #f
             'register (json-null)
             'active_shift (json-null))))

  (test-case "transaction start is durably blocked while unconfigured"
    (define response
      (post
       app
       "/transaction-commands"
       (hasheq
        'schema_version 1
        'command_id "cmd-unconfigured"
        'transaction_id "txn-unconfigured"
        'expected_version 0
        'command_type "start_transaction"
        'payload (hasheq))))
    (check-equal? (response-code response) 409)
    (define result (hash-ref (body response) 'command_result))
    (check-equal? (hash-ref result 'outcome_kind) "domain_rejected")
    (check-equal? (hash-ref result 'outcome_code)
                  "register_not_configured"))

  (define decoded
    (json-string->operational-configuration-snapshot config-json))
  (void
   (activate-operational-configuration!
    connection
    (operational-configuration-decode-success-snapshot decoded)))

  (test-case "transaction start is durably blocked until a shift opens"
    (define response
      (post
       app
       "/transaction-commands"
       (hasheq
        'schema_version 1
        'command_id "cmd-no-shift"
        'transaction_id "txn-no-shift"
        'expected_version 0
        'command_type "start_transaction"
        'payload (hasheq))))
    (check-equal? (response-code response) 409)
    (define result (hash-ref (body response) 'command_result))
    (check-equal? (hash-ref result 'outcome_kind) "domain_rejected")
    (check-equal? (hash-ref result 'outcome_code) "shift_required"))

  (test-case "cashier role cannot list the configured cashier directory"
    (define response (app (request* #"GET" "/cashiers")))
    (check-equal? (response-code response) 403)
    (check-equal? (error-code response) "authorization_denied")
    (check-equal?
     (db:query-value
      connection
      "SELECT COUNT(*) FROM security_audit_events WHERE event_type = 'authorization.denied'")
     1)
    ;; Authorization denial does not revoke a valid bearer session.
    (check-equal?
     (response-code (app (request* #"GET" "/register-context")))
     200))

  (test-case "open validates strictly and safely repeats same cashier"
    (define malformed
      (post app "/shifts/open"
            (hasheq 'opening_cash_minor_units 10000
                    'extra #t)))
    (check-equal? (response-code malformed) 400)
    (for ([invalid (in-list (list -1 1.5 "10000"))])
      (check-equal?
       (response-code
        (post app "/shifts/open"
              (hasheq 'opening_cash_minor_units invalid)))
       400))
    (define identity-claim
      (post app "/shifts/open"
            (hasheq 'cashier_id "inactive"
                    'opening_cash_minor_units 10000)))
    (check-equal? (response-code identity-claim) 400)
    (define opened
      (post app "/shifts/open"
            (hasheq 'opening_cash_minor_units 10000)))
    (check-equal? (response-code opened) 200)
    (check-equal? (hash-ref (hash-ref (body opened) 'shift) 'shift_id)
                  "shift-one")
    (check-equal?
     (hash-ref (hash-ref (body opened) 'cash_summary) 'view)
     "limited")
    (check-false
     (hash-has-key? (hash-ref (body opened) 'cash_summary)
                    'opening_cash_minor_units))
    (for ([command
           (in-list
            (list
             (hasheq 'schema_version 1
                     'command_id "cmd-summary-start"
                     'transaction_id "txn-cash-summary-sentinel"
                     'expected_version 0
                     'command_type "start_transaction"
                     'payload (hasheq))
             (hasheq 'schema_version 1
                     'command_id "cmd-summary-scan"
                     'transaction_id "txn-cash-summary-sentinel"
                     'expected_version 1
                     'command_type "scan_barcode"
                     'payload (hasheq 'barcode "049000001234"))
             (hasheq 'schema_version 1
                     'command_id "cmd-summary-tender"
                     'transaction_id "txn-cash-summary-sentinel"
                     'expected_version 2
                     'command_type "tender_cash"
                     'payload (hasheq 'amount_minor_units 8765432))
             (hasheq 'schema_version 1
                     'command_id "cmd-summary-complete"
                     'transaction_id "txn-cash-summary-sentinel"
                     'expected_version 3
                     'command_type "complete_transaction"
                     'payload (hasheq))))])
      (check-equal?
       (response-code (post app "/transaction-commands" command))
       200))
    (define repeated
      (post app "/shifts/open"
            (hasheq 'opening_cash_minor_units 999)))
    (check-equal? (response-code repeated) 200)
    (define repeated-summary
      (hash-ref (body repeated) 'cash_summary))
    (check-equal? repeated-summary
                  (hasheq 'shift_id "shift-one"
                          'status "open"
                          'view "limited"))
    (define serialized-repeated (jsexpr->string (body repeated)))
    (for ([forbidden
           (in-list
            '("opening_cash_minor_units"
              "completed_cash_sale_count"
              "cash_sales_minor_units"
              "expected_cash_minor_units"
              "counted_cash_minor_units"
              "over_short_minor_units"
              "199"
              "10199"))])
      (check-false (string-contains? serialized-repeated forbidden)))
    (db:query-exec
     connection
     "DELETE FROM shift_cash_movements WHERE transaction_id = 'txn-cash-summary-sentinel'")
    (check-equal? (body repeated) (body opened)))

  (test-case "transaction start under the open shift claims and releases its slot"
    (define start-response
      (post
       app
       "/transaction-commands"
       (hasheq
        'schema_version 1
        'command_id "cmd-under-shift"
        'transaction_id "txn-under-shift"
        'expected_version 0
        'command_type "start_transaction"
        'payload (hasheq))))
    (check-equal? (response-code start-response) 200)
    (check-equal?
     (db:query-value
      connection
      "SELECT active_transaction_id FROM register_shifts WHERE shift_id = 'shift-one'")
     "txn-under-shift")
    ;; This older slot-release fixture now uses an explicit scoped approval.
    (db:query-exec
     connection
     "INSERT INTO operators VALUES ('http-supervisor', 'HTTP Supervisor', 1)")
    (db:query-exec
     connection
     "INSERT INTO operator_roles VALUES ('http-supervisor', 'supervisor')")
    (db:query-exec
     connection
     "INSERT INTO operator_pin_credentials VALUES ('http-supervisor', '$argon2id$v=19$m=19456,t=2,p=1$c2FsdA$aGFzaA', 1)")
    (define approval-token
      (string-append "gpos_a1_" (make-string 64 #\c)))
    (define approval-capability
      (transaction-void-approval-token->capability approval-token))
    (define void-command
      (void-transaction-command "cmd-under-shift-void" "txn-under-shift" 1))
    (db:call-with-transaction
     connection
     (lambda ()
       (replace-transaction-void-approval-grant!/in-transaction!
        connection
        (transaction-void-approval-grant
         "http-test-approval"
         (transaction-void-approval-capability-token-digest approval-capability)
         "http-test-instance"
         test-operator-id
         1
         "http-supervisor"
         1 "cmd-under-shift-void" "txn-under-shift" 1 1
         1000 91000 91000)
        "http-test-instance" 1000))
     #:option 'immediate)
    (set-box! test-approval-token approval-token)
    (define void-response
      (post
       app
       "/transaction-commands"
       (hasheq
        'schema_version 1
        'command_id "cmd-under-shift-void"
        'transaction_id "txn-under-shift"
        'expected_version 1
        'command_type "void_transaction"
        'payload (hasheq))))
    (set-box! test-approval-token #f)
    (check-equal? (response-code void-response) 200)
    (check-true
     (db:sql-null?
      (db:query-value
       connection
       "SELECT active_transaction_id FROM register_shifts WHERE shift_id = 'shift-one'"))))

  (test-case "close blocks active transaction then is repeatably safe"
    (db:query-exec
     connection
     "UPDATE register_shifts SET active_transaction_id = 'txn-one' WHERE shift_id = 'shift-one'")
    (define blocked
      (post app "/shifts/shift-one/close"
            (hasheq 'counted_cash_minor_units 10000)))
    (check-equal? (response-code blocked) 409)
    (check-equal? (error-code blocked) "shift_has_active_transaction")
    (db:query-exec
     connection
     "UPDATE register_shifts SET active_transaction_id = NULL WHERE shift_id = 'shift-one'")
    (define before-close
      (app (request* #"GET" "/shifts/shift-one/cash-summary")))
    (check-equal? (response-code before-close) 200)
    (check-equal?
     (hash-ref (hash-ref (body before-close) 'cash_summary) 'status)
     "open")
    (check-equal?
     (hash-ref (hash-ref (body before-close) 'cash_summary) 'view)
     "limited")
    (for ([field (in-list '(opening_cash_minor_units
                            completed_cash_sale_count
                            cash_sales_minor_units
                            expected_cash_minor_units
                            counted_cash_minor_units
                            over_short_minor_units))])
      (check-false
       (hash-has-key? (hash-ref (body before-close) 'cash_summary) field)))
    (for ([invalid (in-list (list -1 1.5 "10000"))])
      (check-equal?
       (response-code
        (post app "/shifts/shift-one/close"
              (hasheq 'counted_cash_minor_units invalid)))
       400))
    (define closed
      (post app "/shifts/shift-one/close"
            (hasheq 'counted_cash_minor_units 9975)))
    (check-equal? (response-code closed) 200)
    (check-equal? (hash-ref (hash-ref (body closed) 'shift)
                            'closed_at_epoch_ms)
                  2000)
    (define closed-summary (hash-ref (body closed) 'cash_summary))
    (check-equal? (hash-ref closed-summary 'status) "closed")
    (check-equal? (hash-ref closed-summary 'view) "full")
    (check-equal? (hash-ref closed-summary 'counted_cash_minor_units) 9975)
    (check-equal? (hash-ref closed-summary 'over_short_minor_units) -25)
    (define repeated
      (post app "/shifts/shift-one/close"
            (hasheq 'counted_cash_minor_units 10000)))
    (check-equal? (response-code repeated) 200)
    (check-equal? (body repeated) (body closed)))

  (test-case "operational routes enforce methods"
    (for ([path (in-list '("/register-context" "/cashiers"))])
      (check-equal? (response-code (app (request* #"POST" path #"{}"))) 405))
    (check-equal? (response-code (app (request* #"GET" "/shifts/open"))) 405)
    (check-equal?
     (response-code (app (request* #"GET" "/shifts/shift-one/close"))) 405)
    (check-equal?
     (response-code
      (app (request* #"POST" "/shifts/shift-one/cash-summary" #"{}")))
     405))

  (db:disconnect connection))
