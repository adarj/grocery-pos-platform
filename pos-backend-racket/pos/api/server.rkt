#lang racket

(require json
         net/url
         web-server/http
         "../application/transaction-service.rkt"
         "../support/health.rkt")

(provide make-app
         json-response
         not-found-response)

(define (jsexpr->utf8-bytes value)
  (string->bytes/utf-8 (jsexpr->string value)))

(define (json-response value
                       #:status [status 200]
                       #:message [message #"OK"])
  (response/full
   status
   message
   (current-seconds)
   #"application/json; charset=utf-8"
   '()
   (list (jsexpr->utf8-bytes value))))

(define (not-found-response)
  (json-response
   (hasheq
    'ok #f
    'error "not_found"
    'message "Route not found")
   #:status 404
   #:message #"Not Found"))

(define (request-path-segments req)
  (map path/param-path
       (url-path (request-uri req))))

(define (make-app transaction-service)
  (unless (transaction-service? transaction-service)
    (raise-argument-error
     'make-app "transaction-service?" transaction-service))

  ;; The service is intentionally captured before transaction routes exist.
  ;; This establishes explicit composition without turning it into a global.
  (lambda (req)
    (define method (request-method req))
    (define path (request-path-segments req))

    (cond
      [(and (equal? method #"GET")
            (equal? path '("health")))
       (json-response (current-health))]

      [else
       (not-found-response)])))
