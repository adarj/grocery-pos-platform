#lang racket

(require net/url
         web-server/http
         "http-response.rkt"
         "transaction-http.rkt"
         "../application/transaction-service.rkt"
         "../support/health.rkt")

(provide make-app
         json-response
         not-found-response)

(define (not-found-response)
  (api-error-response
   "not_found"
   "Route not found."
   #:status 404
   #:status-message #"Not Found"))

(define (method-not-allowed-response allowed-method)
  (api-error-response
   "method_not_allowed"
   "Method not allowed."
   #:status 405
   #:status-message #"Method Not Allowed"
   #:headers (list (header #"Allow" allowed-method))))

(define (request-path-segments req)
  (map path/param-path
       (url-path (request-uri req))))

(define (transaction-query-path? path)
  (and (= (length path) 2)
       (equal? (first path) "transactions")
       (string? (second path))
       (positive? (string-length (second path)))))

(define (make-app transaction-service)
  (unless (transaction-service? transaction-service)
    (raise-argument-error
     'make-app "transaction-service?" transaction-service))

  (lambda (req)
    (define method (request-method req))
    (define path (request-path-segments req))

    (cond
      [(equal? path '("health"))
       (if (equal? method #"GET")
           (json-response (current-health))
           (method-not-allowed-response #"GET"))]

      [(equal? path '("transaction-commands"))
       (if (equal? method #"POST")
           (handle-transaction-command-request transaction-service req)
           (method-not-allowed-response #"POST"))]

      [(transaction-query-path? path)
       (if (equal? method #"GET")
           (handle-transaction-query-request
            transaction-service
            (second path))
           (method-not-allowed-response #"GET"))]

      [else
       (not-found-response)])))
