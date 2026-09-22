#lang racket

(require json
         web-server/http)

(provide json-response
         api-error-response
         authorization-denied-response)

(define (authorization-denied-response)
  (api-error-response
   "authorization_denied"
   "Operator is not authorized for this operation."
   #:status 403
   #:status-message #"Forbidden"))

(define (jsexpr->utf8-bytes value)
  (string->bytes/utf-8 (jsexpr->string value)))

(define (json-response value
                       #:status [status 200]
                       #:message [message #"OK"]
                       #:headers [headers '()])
  (response/full
   status
   message
   (current-seconds)
   #"application/json; charset=utf-8"
   headers
   (list (jsexpr->utf8-bytes value))))

(define (api-error-response code
                            message
                            #:status status
                            #:status-message status-message
                            #:headers [headers '()]
                            #:reason [reason #f]
                            #:retry-same-command-id?
                            [retry-same-command-id? #f])
  (unless (string? code)
    (raise-argument-error 'api-error-response "string?" code))
  (unless (string? message)
    (raise-argument-error 'api-error-response "string?" message))
  (define base-error
    (hasheq 'code code 'message message))
  (define with-reason
    (if reason
        (hash-set base-error 'reason reason)
        base-error))
  (define error
    (if retry-same-command-id?
        (hash-set with-reason 'retry_same_command_id #t)
        with-reason))
  (json-response
   (hasheq 'ok #f 'error error)
   #:status status
   #:message status-message
   #:headers headers))
