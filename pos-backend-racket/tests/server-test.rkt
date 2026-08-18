#lang racket

(require (prefix-in db: db)
         json
         net/url
         rackunit
         web-server/http
         "../pos/api/server.rkt"
         "../pos/application/transaction-service.rkt"
         "../pos/domain/fake-catalog.rkt"
         "../pos/persistence/transaction-journal-migrations.rkt")

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

(module+ test
  (define connection
    (db:sqlite3-connect #:database 'memory))
  (migrate-transaction-journal! connection)
  (define service
    (make-transaction-service
     connection
     #:catalog-lookup fake-catalog-lookup))
  (define app
    (make-app service))

  (test-case "app factory preserves health endpoint behavior"
    (define response
      (app (make-request #"GET" "/health")))
    (check-equal? (response-code response) 200)
    (define payload (response-jsexpr response))
    (check-true (hash-ref payload 'ok))
    (check-equal? (hash-ref payload 'service) "grocery-pos-core"))

  (test-case "app factory preserves unknown-route behavior"
    (define response
      (app (make-request #"GET" "/transactions")))
    (check-equal? (response-code response) 404)
    (check-equal?
     (hash-ref (hash-ref (response-jsexpr response) 'error) 'code)
     "not_found"))

  (test-case "app factory rejects an invalid transaction service"
    (check-exn exn:fail:contract?
               (lambda () (make-app #f))))

  (db:disconnect connection))
