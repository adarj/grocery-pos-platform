#lang racket

(require (prefix-in db: db)
         json
         net/url
         rackunit
         web-server/http
         "../pos/api/server.rkt"
         "../pos/application/transaction-service.rkt"
         "../pos/domain/fake-catalog.rkt"
         "../pos/persistence/pos-database-migrations.rkt"
         "../pos/support/readiness.rkt"
         "support/authentication.rkt")

(define (make-request method path)
  (request method
           (string->url path)
           '()
           (delay '())
           #f
           "127.0.0.1"
           7340
           "127.0.0.1"))

(define (response-jsexpr response)
  (define output (open-output-bytes))
  ((response-output response) output)
  (bytes->jsexpr (get-output-bytes output)))

(define (response-header response name)
  (define found (headers-assq* name (response-headers response)))
  (and found (header-value found)))

(module+ test
  (define connection
    (db:sqlite3-connect #:database 'memory))
  (migrate-pos-database! connection)
  (define service
    (make-transaction-service
     connection
     #:catalog-lookup fake-catalog-lookup))
  (define auth-service (make-test-authentication-service connection))
  (define app
    (make-app
     service
     #:authentication-service auth-service
     #:readiness-probe
     (lambda ()
       (runtime-ready current-pos-database-schema-version))))

  (test-case "app factory preserves health endpoint behavior"
    (define response
      (app (make-request #"GET" "/health")))
    (check-equal? (response-code response) 200)
    (define payload (response-jsexpr response))
    (check-true (hash-ref payload 'ok))
    (check-equal? (hash-ref payload 'service) "grocery-pos-core"))

  (test-case "health remains process-only and never invokes readiness"
    (define health-only-app
      (make-app
       service
       #:authentication-service auth-service
       #:readiness-probe
       (lambda () (error 'readiness "health must not probe SQLite"))))
    (check-equal?
     (response-code (health-only-app (make-request #"GET" "/health")))
     200))

  (test-case "ready endpoint reports current database schema"
    (define response (app (make-request #"GET" "/ready")))
    (check-equal? (response-code response) 200)
    (check-equal?
     (response-jsexpr response)
     (hasheq 'ok #t
             'service "grocery-pos-core"
             'status "ready"
             'database_schema_version
             current-pos-database-schema-version)))

  (test-case "ready endpoint sanitizes stable unavailable reasons"
    (for ([reason (in-list '(runtime_stopped
                             database_missing
                             database_unavailable
                             database_schema_not_current))])
      (define unavailable-app
        (make-app
         service
         #:authentication-service auth-service
         #:readiness-probe (lambda () (runtime-not-ready reason))))
      (define response
        (unavailable-app (make-request #"GET" "/ready")))
      (check-equal? (response-code response) 503)
      (check-equal?
       (response-jsexpr response)
       (hasheq 'ok #f
               'service "grocery-pos-core"
               'status "not_ready"
               'reason (symbol->string reason)))))

  (test-case "readiness exceptions are unavailable without leaked details"
    (define unavailable-app
      (make-app
       service
       #:authentication-service auth-service
       #:readiness-probe
       (lambda () (error 'probe "secret SQLite diagnostics"))))
    (define response
      (unavailable-app (make-request #"GET" "/ready")))
    (check-equal? (response-code response) 503)
    (define bytes
      (let ([output (open-output-bytes)])
        ((response-output response) output)
        (get-output-bytes output)))
    (check-false (regexp-match? #rx"secret" (bytes->string/utf-8 bytes)))
    (check-equal?
     (hash-ref (response-jsexpr response) 'reason)
     "database_unavailable"))

  (test-case "top-level application exceptions remain generic JSON"
    (define invalid-app
      (make-app
       service
       #:authentication-service auth-service
       #:readiness-probe (lambda () 'invalid-result)))
    (define response (invalid-app (make-request #"GET" "/ready")))
    (check-equal? (response-code response) 500)
    (check-equal?
     (hash-ref (hash-ref (response-jsexpr response) 'error) 'code)
     "internal_error"))

  (test-case "ready endpoint rejects other methods with Allow GET"
    (define response (app (make-request #"POST" "/ready")))
    (check-equal? (response-code response) 405)
    (check-equal? (response-header response #"Allow") #"GET"))

  (test-case "app factory preserves unknown-route behavior"
    (define response
      (app (make-request #"GET" "/transactions")))
    (check-equal? (response-code response) 404)
    (check-equal?
     (hash-ref (hash-ref (response-jsexpr response) 'error) 'code)
     "not_found"))

  (test-case "app factory rejects an invalid transaction service"
    (check-exn exn:fail:contract?
               (lambda ()
                 (make-app
                  #f
                  #:authentication-service auth-service
                  #:readiness-probe runtime-ready)))
    (check-exn exn:fail:contract?
               (lambda ()
                 (make-app
                  service
                  #:authentication-service auth-service
                  #:readiness-probe #f)))
    (check-exn exn:fail:contract?
               (lambda ()
                 (make-app
                  service
                  #:authentication-service #f
                  #:readiness-probe runtime-ready))))

  (db:disconnect connection))
