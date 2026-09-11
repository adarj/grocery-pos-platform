#lang racket

(require (prefix-in db: db)
         json
         net/http-client
         racket/file
         racket/tcp
         rackunit
         web-server/safety-limits
         "../pos/api/http-safety.rkt"
         "../pos/api/server.rkt"
         "../pos/application/transaction-service.rkt"
         "../pos/domain/fake-catalog.rkt"
         "../pos/persistence/pos-database-migrations.rkt"
         "../pos/support/readiness.rkt")

(define (allocate-loopback-port)
  (define listener (tcp-listen 0 4 #t "127.0.0.1"))
  (define-values (_local-address port _remote-address _remote-port)
    (tcp-addresses listener #t))
  (tcp-close listener)
  port)

(define (http-request port path
                      #:method [method #"GET"]
                      #:headers [headers '()]
                      #:data [data #f])
  (define-values (status response-headers body-port)
    (http-sendrecv
     "127.0.0.1"
     path
     #:port port
     #:method method
     #:headers headers
     #:data data))
  (define body (port->bytes body-port))
  (close-input-port body-port)
  (values status response-headers body))

(define (wait-for-listener port)
  (or
   (for/or ([_attempt (in-range 200)])
     (define ready?
       (with-handlers ([exn:fail? (lambda (_exception) #f)])
         (define-values (status _headers _body)
           (http-request port "/health"))
         (regexp-match? #rx#" 200 " status)))
     (unless ready? (sleep 0.01))
     ready?)
   (error 'wait-for-listener "test server did not start")))

(module+ test
  (test-case "POS HTTP safety policy freezes bounded native server limits"
    (check-equal? pos-http-max-concurrent 64)
    (check-equal? pos-http-max-waiting 64)
    (check-equal? pos-http-request-read-timeout-seconds 10)
    (check-equal? pos-http-max-request-body-bytes (* 64 1024))
    (check-equal? pos-http-response-timeout-seconds 30)
    (check-equal? pos-http-response-send-timeout-seconds 10)
    (check-pred safety-limits? pos-http-safety-limits))

  (test-case "server composition supplies the POS safety policy"
    (define captured #f)
    (define (recording-serve app
                             #:launch-browser? launch-browser?
                             #:quit? quit?
                             #:banner? banner?
                             #:listen-ip listen-ip
                             #:port port
                             #:servlet-path servlet-path
                             #:servlet-regexp servlet-regexp
                             #:safety-limits safety-limits)
      (set! captured
            (list app
                  launch-browser?
                  quit?
                  banner?
                  listen-ip
                  port
                  servlet-path
                  servlet-regexp
                  safety-limits))
      'served)
    (define app (lambda (_request) (void)))
    (check-equal?
     (serve-pos-app
      app "127.0.0.1" 7340 #:serve recording-serve)
     'served)
    (check-eq? (first captured) app)
    (check-equal? (take (rest captured) 6)
                  (list #f #f #f "127.0.0.1" 7340 "/"))
    (check-true (regexp? (list-ref captured 7)))
    (check-eq? (list-ref captured 8) pos-http-safety-limits))

  (test-case "request reader rejects oversized command before durable handling"
    (define directory
      (make-temporary-file "grocery-pos-http-safety-~a" 'directory))
    (define database-path (build-path directory "pos.db"))
    (define connection
      (db:sqlite3-connect #:database database-path #:mode 'create))
    (migrate-pos-database! connection)
    (define service
      (make-transaction-service
       connection
       #:catalog-lookup fake-catalog-lookup))
    (define app
      (make-app
       service
       #:readiness-probe
       (lambda ()
         (runtime-ready current-pos-database-schema-version))))
    (define port (allocate-loopback-port))
    (define server-custodian (make-custodian))
    (define server-output (open-output-string))
    (parameterize ([current-custodian server-custodian]
                   [current-output-port server-output]
                   [current-error-port server-output])
      (thread
       (lambda ()
         (serve-pos-app app "127.0.0.1" port))))
    (dynamic-wind
      (lambda () (wait-for-listener port))
      (lambda ()
        (define command-id "cmd-after-oversized")
        (define oversized-body
          (jsexpr->bytes
           (hasheq
            'schema_version 1
            'command_id command-id
            'transaction_id
            (make-string pos-http-max-request-body-bytes #\x)
            'expected_version 0
            'command_type "start_transaction"
            'payload (hasheq))))
        (check-true
         (> (bytes-length oversized-body)
            pos-http-max-request-body-bytes))
        ;; Racket's request reader may close the connection without a stable
        ;; application response. Either outcome is transport-level rejection.
        (with-handlers ([exn:fail? void])
          (define-values (_status _headers body)
            (http-request
             port
             "/transaction-commands"
             #:method #"POST"
             #:headers '(#"Content-Type: application/json")
             #:data oversized-body))
          (void body))

        (check-equal?
         (db:query-value
          connection
          "SELECT COUNT(*) FROM transaction_command_receipts WHERE command_id = ?"
          command-id)
         0)
        (check-equal?
         (db:query-value connection "SELECT COUNT(*) FROM transaction_events")
         0)

        ;; Reusing the same ID for a normal command proves the oversized body
        ;; did not leave a durable receipt. The focused service then accepts
        ;; exactly one normal transaction start instead of reporting reuse.
        (define valid-body
          (jsexpr->bytes
           (hasheq
            'schema_version 1
            'command_id command-id
            'transaction_id "txn-after-oversized"
            'expected_version 0
            'command_type "start_transaction"
            'payload (hasheq))))
        (define-values (status _headers response-body)
          (http-request
           port
           "/transaction-commands"
           #:method #"POST"
           #:headers '(#"Content-Type: application/json")
           #:data valid-body))
        (check-true (regexp-match? #rx#" 200 " status)
                    (format "unexpected response: ~e ~e"
                            status response-body))
        (define result
          (hash-ref (bytes->jsexpr response-body) 'command_result))
        (check-equal? (hash-ref result 'outcome_kind) "accepted")
        (check-equal? (hash-ref result 'outcome_code) "accepted")
        (check-equal?
         (db:query-value
          connection
          "SELECT COUNT(*) FROM transaction_command_receipts WHERE command_id = ?"
          command-id)
         1)
        (check-equal?
         (db:query-value connection "SELECT COUNT(*) FROM transaction_events")
         1)

        (define-values (health-status _health-headers health-body)
          (http-request port "/health"))
        (check-true (regexp-match? #rx#" 200 " health-status))
        (check-true (hash-ref (bytes->jsexpr health-body) 'ok)))
      (lambda ()
        (custodian-shutdown-all server-custodian)
        (when (db:connected? connection)
          (db:disconnect connection))
        (delete-directory/files directory)))))
