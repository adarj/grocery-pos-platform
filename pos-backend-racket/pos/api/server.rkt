#lang racket

(require net/url
         web-server/http
         "http-response.rkt"
         "receipt-http.rkt"
         "register-operations-http.rkt"
         "transaction-http.rkt"
         "../application/transaction-service.rkt"
         "../application/register-operations-service.rkt"
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

(define (receipt-query-path? path)
  (and (= (length path) 2)
       (equal? (first path) "receipts")
       (string? (second path))
       (positive? (string-length (second path)))))

(define (shift-close-path? path)
  (and (= (length path) 3)
       (equal? (first path) "shifts")
       (string? (second path))
       (positive? (string-length (second path)))
       (equal? (third path) "close")))

(define (make-app transaction-service [register-service #f])
  (unless (transaction-service? transaction-service)
    (raise-argument-error
     'make-app "transaction-service?" transaction-service))
  (unless (or (not register-service)
              (register-operations-service? register-service))
    (raise-argument-error
     'make-app "(or/c #f register-operations-service?)" register-service))

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

      [(and register-service (equal? path '("register-context")))
       (if (equal? method #"GET")
           (handle-register-context-request register-service)
           (method-not-allowed-response #"GET"))]

      [(and register-service (equal? path '("cashiers")))
       (if (equal? method #"GET")
           (handle-active-cashiers-request register-service)
           (method-not-allowed-response #"GET"))]

      [(and register-service (equal? path '("shifts" "open")))
       (if (equal? method #"POST")
           (handle-open-shift-request register-service req)
           (method-not-allowed-response #"POST"))]

      [(and register-service (shift-close-path? path))
       (if (equal? method #"POST")
           (handle-close-shift-request register-service (second path) req)
           (method-not-allowed-response #"POST"))]

      [(transaction-query-path? path)
       (if (equal? method #"GET")
           (handle-transaction-query-request
            transaction-service
            (second path))
           (method-not-allowed-response #"GET"))]

      [(receipt-query-path? path)
       (if (equal? method #"GET")
           (handle-receipt-query-request
            transaction-service
            (second path))
           (method-not-allowed-response #"GET"))]

      [else
       (not-found-response)])))
