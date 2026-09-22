#lang racket

(require json
         racket/string
         web-server/http
         "http-response.rkt"
         "../application/transaction-command-receipt.rkt"
         "../application/transaction-command.rkt"
         "../application/transaction-service.rkt"
         "../domain/money.rkt"
         "../domain/transaction.rkt"
         "../persistence/transaction-command-codec.rkt")

(provide handle-transaction-command-request
         handle-transaction-query-request)

(define bad-request-message #"Bad Request")
(define not-found-message #"Not Found")
(define conflict-message #"Conflict")
(define unsupported-media-type-message #"Unsupported Media Type")
(define internal-server-error-message #"Internal Server Error")

(define (internal-error-response)
  (api-error-response
   "internal_error"
   "An internal service error occurred."
   #:status 500
   #:status-message internal-server-error-message))

(define (transaction-recovery-failed-response)
  (api-error-response
   "transaction_recovery_failed"
   "Transaction state could not be recovered."
   #:status 500
   #:status-message internal-server-error-message))

(define (json-content-type? req)
  (define content-type
    (headers-assq* #"Content-Type" (request-headers/raw req)))
  (and content-type
       (let* ([text
               (bytes->string/latin-1 (header-value content-type))]
              [parts (string-split text ";")])
         (and (pair? parts)
              (string=?
               (string-downcase (string-trim (first parts)))
               "application/json")))))

(define (decode-failure-code->reason code)
  (case code
    [(malformed-json) "malformed_json"]
    [(duplicate-field) "duplicate_field"]
    [(expected-object) "expected_object"]
    [(missing-field) "missing_field"]
    [(unexpected-field) "unexpected_field"]
    [(unsupported-schema-version) "unsupported_schema_version"]
    [(unknown-command-type) "unknown_command_type"]
    [(invalid-field-type) "invalid_field_type"]
    [(invalid-command-id) "invalid_command_id"]
    [(invalid-transaction-id) "invalid_transaction_id"]
    [(invalid-expected-version) "invalid_expected_version"]
    [(invalid-barcode) "invalid_barcode"]
    [(invalid-money) "invalid_money"]
    [(invalid-line-index) "invalid_line_index"]
    [else
     (error
      'decode-failure-code->reason
      "unmapped transaction command decode failure code: ~e"
      code)]))

(define (invalid-command-response reason)
  (api-error-response
   "invalid_transaction_command"
   "Transaction command is invalid."
   #:status 400
   #:status-message bad-request-message
   #:reason reason))

(define (receipt-outcome->http-values outcome-kind)
  (case outcome-kind
    [(accepted) (values "accepted" 200 #"OK" #t)]
    [(domain-rejected)
     (values "domain_rejected" 409 conflict-message #f)]
    [(not-found)
     (values "not_found" 404 not-found-message #f)]
    [(already-exists)
     (values "already_exists" 409 conflict-message #f)]
    [(version-conflict)
     (values "version_conflict" 409 conflict-message #f)]
    [else
     (error
      'receipt-outcome->http-values
      "unmapped transaction command outcome kind: ~e"
      outcome-kind)]))

(define (receipt-response receipt)
  (define command
    (transaction-command-receipt-command receipt))
  (define-values (outcome-kind status status-message ok?)
    (receipt-outcome->http-values
     (transaction-command-receipt-outcome-kind receipt)))
  (json-response
   (hasheq
    'ok ok?
    'command_result
    (hasheq
     'command_id (transaction-command-command-id command)
     'transaction_id (transaction-command-transaction-id command)
     'outcome_kind outcome-kind
     'outcome_code (transaction-command-receipt-outcome-code receipt)
     'outcome_stream_version
     (transaction-command-receipt-outcome-stream-version receipt)))
   #:status status
   #:message status-message))

(define (command-result-response result)
  (cond
    [(transaction-service-command-resolved? result)
     (receipt-response
      (transaction-service-command-resolved-receipt result))]
    [(transaction-service-command-id-reused? result)
     (api-error-response
      "command_id_reused"
      "Command ID is already associated with a different command."
      #:status 409
      #:status-message conflict-message)]
    [(transaction-service-authorization-denied? result)
     (authorization-denied-response)]
    [(transaction-service-command-persistence-failed? result)
     (api-error-response
      "command_persistence_failed"
      "The command could not be committed. Retry using the same command ID."
      #:status 500
      #:status-message internal-server-error-message
      #:retry-same-command-id? #t)]
    [(transaction-service-recovery-failed? result)
     (transaction-recovery-failed-response)]
    [else
     (error
      'command-result-response
      "unsupported transaction service command result: ~e"
      result)]))

(define (execute-decoded-command transaction-service principal command)
  ;; Once a typed command exists, an escaping exception cannot prove that the
  ;; atomic commit did not land. The only safe client protocol is same-ID retry.
  (with-handlers
      ([exn:fail?
        (lambda (_exception)
          (api-error-response
           "command_outcome_unknown"
           "The command outcome could not be confirmed. Retry using the same command ID."
           #:status 500
           #:status-message internal-server-error-message
           #:retry-same-command-id? #t))])
    (command-result-response
     (transaction-service-execute-command
      transaction-service principal command))))

(define (handle-transaction-command-request transaction-service principal req)
  ;; Failures before a typed logical command exists are transport/internal
  ;; failures, not uncertain outcomes for a particular command identity.
  (with-handlers ([exn:fail? (lambda (_exception) (internal-error-response))])
    (cond
      [(not (json-content-type? req))
       (api-error-response
        "unsupported_media_type"
        "Content-Type must be application/json."
        #:status 415
        #:status-message unsupported-media-type-message)]
      [else
       (define body (request-post-data/raw req))
       (cond
         [(or (not body) (zero? (bytes-length body)))
          (invalid-command-response "missing_body")]
         [else
          (define decoded
            (json-bytes->transaction-command body))
          (cond
            [(command-decode-failure? decoded)
             (invalid-command-response
              (decode-failure-code->reason
               (command-decode-failure-code decoded)))]
            [(command-decode-success? decoded)
             (execute-decoded-command
              transaction-service
              principal
              (command-decode-success-command decoded))]
            [else
             (error
              'handle-transaction-command-request
              "unsupported command codec result: ~e"
              decoded)])])])))

(define (transaction-status->string status)
  (case status
    [(open) "open"]
    [(paid) "paid"]
    [(completed) "completed"]
    [(voided) "voided"]
    [else
     (error
      'transaction-status->string
      "unmapped transaction status: ~e"
      status)]))

(define (nullable-money->jsexpr value)
  (if value
      (money-minor-units value)
      (json-null)))

(define (line-item->jsexpr line-item)
  (hasheq
   'barcode (transaction-line-item-barcode line-item)
   'description (transaction-line-item-description line-item)
   'unit_price_minor_units
   (money-minor-units
    (transaction-line-item-unit-price line-item))))

(define (transaction->jsexpr transaction version owned-by-operator?)
  (hasheq
   'transaction_id (transaction-id transaction)
   'owned_by_authenticated_operator owned-by-operator?
   'version version
   'status (transaction-status->string (transaction-status transaction))
   'line_items
   (for/list ([line-item (in-list (transaction-line-items transaction))])
     (line-item->jsexpr line-item))
   'subtotal_minor_units
   (money-minor-units (transaction-subtotal transaction))
   'tax_minor_units
   (money-minor-units (transaction-tax transaction))
   'total_minor_units
   (money-minor-units (transaction-total transaction))
   'tendered_cash_minor_units
   (nullable-money->jsexpr (transaction-tendered-cash transaction))
   'change_due_minor_units
   (nullable-money->jsexpr (transaction-change-due transaction))))

(define (query-result-response result principal)
  (cond
    [(transaction-service-success? result)
     (json-response
      (hasheq
       'ok #t
       'transaction
       (transaction->jsexpr
        (transaction-service-success-transaction result)
        (transaction-service-success-version result)
        (transaction-service-success-owned-by-principal?
         result principal))))]
    [(transaction-service-not-found? result)
     (api-error-response
      "transaction_not_found"
      "Transaction not found."
      #:status 404
      #:status-message not-found-message)]
    [(transaction-service-recovery-failed? result)
     (transaction-recovery-failed-response)]
    [else
     (error
      'query-result-response
      "unsupported transaction service query result: ~e"
      result)]))

(define (handle-transaction-query-request
         transaction-service
         principal
         transaction-id)
  (with-handlers ([exn:fail? (lambda (_exception) (internal-error-response))])
    (query-result-response
     (transaction-service-load-transaction
      transaction-service
      principal
      transaction-id)
     principal)))
