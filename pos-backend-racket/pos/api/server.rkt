#lang racket

(require net/url
         web-server/http
         web-server/servlet-env
         "http-safety.rkt"
         "http-response.rkt"
         "receipt-http.rkt"
         "register-operations-http.rkt"
         "transaction-http.rkt"
         "../application/transaction-service.rkt"
         "../application/register-operations-service.rkt"
         "../support/health.rkt"
         "../support/readiness.rkt")

(provide make-app
         serve-pos-app
         json-response
         not-found-response)

(define service-name "grocery-pos-core")

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

(define (internal-error-response)
  (api-error-response
   "internal_error"
   "An internal service error occurred."
   #:status 500
   #:status-message #"Internal Server Error"))

(define (readiness-response readiness-probe)
  (define result
    (with-handlers ([exn:fail?
                     (lambda (_exception)
                       (runtime-not-ready 'database_unavailable))])
      (readiness-probe)))
  (cond
    [(runtime-ready? result)
     (json-response
      (hasheq 'ok #t
              'service service-name
              'status "ready"
              'database_schema_version
              (runtime-ready-database-schema-version result)))]
    [(runtime-not-ready? result)
     (json-response
      (hasheq 'ok #f
              'service service-name
              'status "not_ready"
              'reason
              (symbol->string (runtime-not-ready-reason result)))
      #:status 503
      #:message #"Service Unavailable")]
    [else
     (error 'readiness-response
            "readiness probe returned an unsupported result")]))

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

(define (shift-cash-summary-path? path)
  (and (= (length path) 3)
       (equal? (first path) "shifts")
       (string? (second path))
       (positive? (string-length (second path)))
       (equal? (third path) "cash-summary")))

(define (make-app transaction-service
                  [register-service #f]
                  #:readiness-probe readiness-probe)
  (unless (transaction-service? transaction-service)
    (raise-argument-error
     'make-app "transaction-service?" transaction-service))
  (unless (or (not register-service)
              (register-operations-service? register-service))
    (raise-argument-error
     'make-app "(or/c #f register-operations-service?)" register-service))
  (unless (and (procedure? readiness-probe)
               (procedure-arity-includes? readiness-probe 0))
    (raise-argument-error
     'make-app "zero-argument procedure?" readiness-probe))

  (lambda (req)
    (with-handlers ([exn:fail? (lambda (_exception)
                                 (internal-error-response))])
      (define method (request-method req))
      (define path (request-path-segments req))

      (cond
        [(equal? path '("health"))
         (if (equal? method #"GET")
             (json-response (current-health))
             (method-not-allowed-response #"GET"))]

        [(equal? path '("ready"))
         (if (equal? method #"GET")
             (readiness-response readiness-probe)
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

        [(and register-service (shift-cash-summary-path? path))
         (if (equal? method #"GET")
             (handle-shift-cash-summary-request register-service (second path))
             (method-not-allowed-response #"GET"))]

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
         (not-found-response)]))))

(define (serve-pos-app app
                       host
                       port
                       #:serve [serve-proc serve/servlet])
  (unless (procedure? app)
    (raise-argument-error 'serve-pos-app "procedure?" app))
  (unless (procedure? serve-proc)
    (raise-argument-error 'serve-pos-app "procedure?" serve-proc))
  (serve-proc
   app
   #:launch-browser? #f
   #:quit? #f
   #:banner? #f
   #:listen-ip host
   #:port port
   #:servlet-path "/"
   #:servlet-regexp #rx""
   #:safety-limits pos-http-safety-limits))
