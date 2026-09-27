#lang racket

(require (prefix-in db: db)
         json
         net/url
         rackunit
         web-server/http
         "../pos/api/server.rkt"
         "../pos/application/authentication-service.rkt"
         "../pos/application/register-operations-service.rkt"
         "../pos/application/transaction-service.rkt"
         "../pos/domain/fake-catalog.rkt"
         "../pos/persistence/pos-database-migrations.rkt"
         "../pos/security/operator-session.rkt"
         "../pos/support/readiness.rkt")

(define password-hash
  "$argon2id$v=19$m=19456,t=2,p=1$c2FsdHNhbHRzYWx0c2FsdA$aGFzaGhhc2hoYXNoaGFzaGhhc2hoYXNoaGFzaGhhc2g")
(define dummy-hash
  "$argon2id$v=19$m=19456,t=2,p=1$ZHVtbXlzYWx0ZHVtbXlzYWx0$ZHVtbXloYXNoZHVtbXloYXNoZHVtbXloYXNoZHVtbXloYXNo")

(define (make-request method path #:body [body #f] #:headers [headers '()])
  (request method
           (string->url path)
           (if body
               (cons (header #"Content-Type" #"application/json") headers)
               headers)
           (delay '())
           body
           "127.0.0.1" 7340 "127.0.0.1"))

(define (response-json response)
  (define output (open-output-bytes))
  ((response-output response) output)
  (bytes->jsexpr (get-output-bytes output)))

(define (response-header response name)
  (define found (headers-assq* name (response-headers response)))
  (and found (header-value found)))

(define (bearer-header token)
  (header #"Authorization" (string->bytes/utf-8 (string-append "Bearer " token))))

(define command-body
  (jsexpr->bytes
   (hasheq 'schema_version 1
           'command_id "anonymous-command"
           'transaction_id "anonymous-transaction"
           'expected_version 0
           'command_type "start_transaction"
           'payload (hasheq))))

(module+ test
  (define connection (db:sqlite3-connect #:database 'memory))
  (db:query-exec connection "PRAGMA foreign_keys = ON")
  (migrate-pos-database! connection)
  (db:query-exec connection "INSERT INTO operators VALUES ('operator-1', 'Operator One', 1)")
  (db:query-exec connection "INSERT INTO operator_roles VALUES ('operator-1', 'cashier')")
  (db:query-exec connection
                 "INSERT INTO operator_pin_credentials VALUES ('operator-1', ?, 1)"
                 password-hash)
  (db:query-exec connection
                 "INSERT INTO operators VALUES ('inactive', 'Inactive', 0)")
  (db:query-exec connection
                 "INSERT INTO operator_roles VALUES ('inactive', 'cashier')")
  (db:query-exec connection
                 "INSERT INTO operator_pin_credentials VALUES ('inactive', ?, 1)"
                 password-hash)
  (db:query-exec connection
                 "INSERT INTO operators VALUES ('unenrolled', 'Unenrolled', 1)")
  (db:query-exec connection
                 "INSERT INTO operator_roles VALUES ('unenrolled', 'cashier')")
  (db:query-exec connection
                 "INSERT INTO operators VALUES ('blocked', 'Blocked', 1)")
  (db:query-exec connection
                 "INSERT INTO operator_roles VALUES ('blocked', 'cashier')")
  (db:query-exec connection
                 "INSERT INTO operator_pin_credentials VALUES ('blocked', ?, 1)"
                 password-hash)
  (define auth-service
    (make-authentication-service
     connection
     #:verify-pin
     (lambda (pin hash)
       (or (and (string=? pin "80421637") (string=? hash password-hash))
           (and (string=? pin "48295173") (string=? hash dummy-hash))))
     #:hash-pin (lambda (_pin) dummy-hash)
     #:dummy-password-hash dummy-hash))
  (define app
    (make-app
     (make-transaction-service connection #:catalog-lookup fake-catalog-lookup)
     (make-register-operations-service
      connection
      #:current-epoch-ms (lambda () 1000)
      #:generate-shift-id (lambda () "shift-test"))
     #:authentication-service auth-service
     #:readiness-probe
     (lambda () (runtime-ready current-pos-database-schema-version))))

  (test-case "health readiness and login remain public"
    (check-equal? (response-code (app (make-request #"GET" "/health"))) 200)
    (check-equal? (response-code (app (make-request #"GET" "/ready"))) 200)
    (define login
      (app
       (make-request
        #"POST" "/auth/login"
        #:body
        (jsexpr->bytes
         (hasheq 'operator_id "operator-1" 'pin "80421637")))))
    (check-equal? (response-code login) 200)
    (check-equal? (response-header login #"Cache-Control") #"no-store")
    (define body (response-json login))
    (check-true (hash-ref body 'ok))
    (check-equal? (hash-ref body 'token_type) "Bearer")
    (define session (hash-ref body 'session))
    (check-equal? (hash-ref session 'idle_timeout_seconds) 300)
    (check-equal?
     (hash-ref session 'permissions)
     '("register.read"
       "transaction.read.own"
       "transaction.operate.own"
       "receipt.read.own"
       "shift.open.own"
       "shift.close.own"
       "shift.cash_summary.read.own"))
    (check-false (hash-has-key? session 'credential_revision)))

  (test-case "anonymous transaction request is rejected before business effects"
    (define response
      (app (make-request #"POST" "/transaction-commands" #:body command-body)))
    (check-equal? (response-code response) 401)
    (check-equal?
     (hash-ref (hash-ref (response-json response) 'error) 'code)
     "authentication_required")
    (check-equal? (response-header response #"WWW-Authenticate") #"Bearer")
    (check-equal?
     (db:query-value connection "SELECT COUNT(*) FROM transaction_events") 0)
    (check-equal?
     (db:query-value connection "SELECT COUNT(*) FROM transaction_command_receipts") 0))

  (test-case "every protected route rejects a missing bearer before its handler"
    (for ([protected-request
           (in-list
            (list
             (make-request #"GET" "/auth/session")
             (make-request #"POST" "/auth/logout")
             (make-request #"POST" "/auth/change-pin" #:body #"{}")
             (make-request #"POST" "/transaction-commands" #:body command-body)
             (make-request #"GET" "/transactions/transaction-1")
             (make-request #"GET" "/receipts/transaction-1")
             (make-request #"GET" "/register-context")
             (make-request #"GET" "/cashiers")
             (make-request #"POST" "/shifts/open" #:body #"{}")
             (make-request #"POST" "/shifts/shift-1/close" #:body #"{}")
             (make-request #"GET" "/shifts/shift-1/cash-summary")))])
      (define response (app protected-request))
      (check-equal? (response-code response) 401)
      (check-equal?
       (hash-ref (hash-ref (response-json response) 'error) 'code)
       "authentication_required")))

  (test-case "session and logout use only the Authorization bearer transport"
    (define login
      (response-json
       (app
        (make-request
         #"POST" "/auth/login"
         #:body
         (jsexpr->bytes
          (hasheq 'operator_id "operator-1" 'pin "80421637"))))))
    (define token (hash-ref login 'access_token))
    (define auth-header (bearer-header token))
    (define session-response
      (app (make-request #"GET" "/auth/session" #:headers (list auth-header))))
    (check-equal? (response-code session-response) 200)
    (define session-body (response-json session-response))
    (check-equal?
     (hash-ref (hash-ref session-body 'session) 'operator_id) "operator-1")
    (check-equal?
     (hash-ref (hash-ref session-body 'session) 'permissions)
     '("register.read"
       "transaction.read.own"
       "transaction.operate.own"
       "receipt.read.own"
       "shift.open.own"
       "shift.close.own"
       "shift.cash_summary.read.own"))
    (check-false (regexp-match? (regexp-quote token) (format "~s" session-body)))
    (define logout-response
      (app (make-request #"POST" "/auth/logout" #:headers (list auth-header))))
    (check-equal? (response-code logout-response) 200)
    (check-equal?
     (response-code
      (app (make-request #"GET" "/auth/session" #:headers (list auth-header))))
     401))

  (test-case "malformed and conflicting Authorization headers are generic"
    (for ([headers
           (in-list
            (list
             (list (header #"Authorization" #"Basic abc"))
             (list (header #"Authorization" #"Bearer gpos_s1_short"))
             (list (header #"Authorization"
                           #"Bearer gpos_s1_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
                   (header #"authorization"
                           #"Bearer gpos_s1_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"))))])
      (define response
        (app (make-request #"GET" "/register-context" #:headers headers)))
      (check-equal? (response-code response) 401)
      (check-equal?
       (hash-ref (hash-ref (response-json response) 'error) 'code)
       "authentication_required")))

  (test-case "login account-state failures use one public envelope"
    (define now (inexact->exact (floor (current-inexact-milliseconds))))
    (db:query-exec
     connection
     "INSERT INTO operator_login_throttle VALUES ('blocked', 4, ?, ?)"
     now
     (+ now 60000))
    (for ([operator-id
           (in-list '("missing" "operator-1" "inactive" "unenrolled" "blocked"))]
          [pin
           (in-list '("80421637" "80421638" "80421637" "80421637" "80421637"))])
      (define response
        (app
         (make-request
          #"POST" "/auth/login"
          #:body (jsexpr->bytes (hasheq 'operator_id operator-id 'pin pin)))))
      (check-equal? (response-code response) 401)
      (check-equal?
       (response-json response)
       (hasheq 'ok #f
               'error
               (hasheq 'code "authentication_failed"
                       'message "Operator sign-in failed.")))))

  (test-case "change-pin is strict, step-up protected and revokes its bearer"
    (define login
      (response-json
       (app (make-request
             #"POST" "/auth/login"
             #:body
             (jsexpr->bytes
              (hasheq 'operator_id "operator-1" 'pin "80421637"))))))
    (define token (hash-ref login 'access_token))
    (define headers (list (bearer-header token)))
    (define extra
      (app (make-request
            #"POST" "/auth/change-pin" #:headers headers
            #:body
            (jsexpr->bytes
             (hasheq 'current_pin "80421637" 'new_pin "48295173"
                     'operator_id "inactive")))))
    (check-equal? (response-code extra) 400)
    (check-equal?
     (db:query-value connection
                     "SELECT credential_revision FROM operator_pin_credentials WHERE operator_id = 'operator-1'")
     1)
    (define wrong
      (app (make-request
            #"POST" "/auth/change-pin" #:headers headers
            #:body
            (jsexpr->bytes
             (hasheq 'current_pin "80421638" 'new_pin "48295173")))))
    (check-equal? (response-code wrong) 403)
    (check-equal?
     (hash-ref (hash-ref (response-json wrong) 'error) 'code)
     "credential_change_failed")
    (check-equal?
     (response-code
      (app (make-request #"GET" "/auth/session" #:headers headers)))
     200)
    (define changed
      (app (make-request
            #"POST" "/auth/change-pin" #:headers headers
            #:body
            (jsexpr->bytes
             (hasheq 'current_pin "80421637" 'new_pin "48295173")))))
    (check-equal? (response-code changed) 200)
    (check-equal? (response-header changed #"Cache-Control") #"no-store")
    (check-equal? (hash-ref (response-json changed) 'credential_revision) 2)
    (check-true (hash-ref (response-json changed) 'reauthentication_required))
    (check-equal?
     (response-code
      (app (make-request #"GET" "/auth/session" #:headers headers)))
     401)
    (check-equal?
     (response-code
      (app (make-request #"GET" "/register-context" #:headers headers)))
     401)
    (check-equal?
     (response-code
      (app (make-request #"POST" "/transaction-commands"
                         #:headers headers #:body command-body)))
     401)
    (check-equal?
     (db:query-value connection "SELECT COUNT(*) FROM transaction_command_receipts")
     0)
    (check-equal?
     (response-code
      (app (make-request #"POST" "/auth/login"
                         #:body (jsexpr->bytes
                                 (hasheq 'operator_id "operator-1"
                                         'pin "80421637")))))
     401)
    (check-equal?
     (response-code
      (app (make-request #"POST" "/auth/login"
                         #:body (jsexpr->bytes
                                 (hasheq 'operator_id "operator-1"
                                         'pin "48295173")))))
     200)
    (check-equal?
     (db:query-value connection
                     "SELECT COUNT(*) FROM security_audit_events WHERE event_type = 'operator.pin_changed'")
     1))

  (db:disconnect connection))
