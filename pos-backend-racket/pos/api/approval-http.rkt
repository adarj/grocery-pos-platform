#lang racket

(require racket/string
         web-server/http
         "http-response.rkt"
         "../application/transaction-command.rkt"
         "../application/transaction-void-approval-service.rkt"
         "../persistence/strict-json.rkt"
         "../persistence/transaction-command-codec.rkt")

(provide handle-transaction-void-approval-request)

(define no-store-header (header #"Cache-Control" #"no-store"))

(define (approval-response value
                           #:status [status 200]
                           #:message [message #"OK"])
  (json-response value
                 #:status status
                 #:message message
                 #:headers (list no-store-header)))

(define (approval-error code message status status-message)
  (approval-response
   (hasheq 'ok #f 'error (hasheq 'code code 'message message))
   #:status status
   #:message status-message))

(define (decode-request req)
  (define body (request-post-data/raw req))
  (cond
    [(or (not body) (zero? (bytes-length body))) #f]
    [else
     (define decoded (strict-json-bytes->jsexpr body))
     (and
      (strict-json-success? decoded)
      (let ([object (strict-json-success-value decoded)])
        (and
         (hash? object)
         (= (hash-count object) 3)
         (hash-has-key? object 'command)
         (hash-has-key? object 'approver_operator_id)
         (hash-has-key? object 'approver_pin)
         (string? (hash-ref object 'approver_operator_id))
         (string? (hash-ref object 'approver_pin))
         (let ([command-result
                (jsexpr->transaction-command (hash-ref object 'command))])
           (and
            (command-decode-success? command-result)
            (void-transaction-command?
             (command-decode-success-command command-result))
            (list
             (command-decode-success-command command-result)
             (hash-ref object 'approver_operator_id)
             (hash-ref object 'approver_pin)))))))]))

(define (json-content-type? req)
  (define content-type
    (headers-assq* #"Content-Type" (request-headers/raw req)))
  (and content-type
       (let ([parts
              (string-split
               (bytes->string/latin-1 (header-value content-type)) ";")])
         (and (pair? parts)
              (string=?
               (string-downcase (string-trim (first parts)))
               "application/json")))))

(define (handle-transaction-void-approval-request service requester req)
  (define decoded (and (json-content-type? req) (decode-request req)))
  (cond
    [(not decoded)
     (approval-error
      "invalid_approval_request"
      "Transaction void approval request is invalid."
      400
      #"Bad Request")]
    [else
     (define result
       (transaction-void-approval-service-request
        service requester (first decoded) (second decoded) (third decoded)))
     (cond
       [(transaction-void-approval-granted? result)
        (approval-response
         (hasheq
          'ok #t
          'approval
          (hasheq
           'approval_token
           (transaction-void-approval-granted-approval-token result)
           'expires_at_epoch_ms
           (transaction-void-approval-granted-expires-at-epoch-ms result)
           'approver_operator_id
           (transaction-void-approval-granted-approver-operator-id result)
           'approver_display_name
           (transaction-void-approval-granted-approver-display-name result))))]
       [(transaction-void-approval-not-granted? result)
        (approval-error
         "approval_not_granted"
         "Approval was not granted."
         403
         #"Forbidden")]
       [(transaction-void-approval-request-denied? result)
        (approval-error
         "authorization_denied"
         "Operator is not authorized for this operation."
         403
         #"Forbidden")]
       [(transaction-void-approval-target-stale? result)
        (approval-error
         "approval_target_stale"
         "The transaction changed before approval could be granted."
         409
         #"Conflict")]
       [else
        (approval-error
         "approval_unavailable"
         "Transaction void approval is temporarily unavailable."
         503
         #"Service Unavailable")])]))
