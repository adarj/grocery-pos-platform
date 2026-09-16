#lang racket

(require db
         rackunit
         "../pos/application/authentication-service.rkt"
         "../pos/domain/operator-identity.rkt"
         "../pos/persistence/pos-database-migrations.rkt"
         "../pos/persistence/sqlite-auth-throttle.rkt"
         "../pos/security/operator-session.rkt")

(define real-hash
  "$argon2id$v=19$m=19456,t=2,p=1$c2FsdHNhbHRzYWx0c2FsdA$aGFzaGhhc2hoYXNoaGFzaGhhc2hoYXNoaGFzaGhhc2g")
(define dummy-hash
  "$argon2id$v=19$m=19456,t=2,p=1$ZHVtbXlzYWx0ZHVtbXlzYWx0$ZHVtbXloYXNoZHVtbXloYXNoZHVtbXloYXNoZHVtbXloYXNo")
(define good-pin "80421637")

(define (insert-operator! connection id name role active? #:credential? [credential? #t])
  (query-exec connection
              "INSERT INTO operators VALUES (?, ?, ?)"
              id name (if active? 1 0))
  (query-exec connection
              "INSERT INTO operator_roles VALUES (?, ?)"
              id (symbol->string role))
  (when credential?
    (query-exec connection
                "INSERT INTO operator_pin_credentials VALUES (?, ?, 1)"
                id real-hash)))

(define (call-with-authentication procedure
                                  #:after-verification [after-verification void])
  (define connection (sqlite3-connect #:database 'memory))
  (query-exec connection "PRAGMA foreign_keys = ON")
  (migrate-pos-database! connection)
  (insert-operator! connection "cashier-1" "Cashier One" 'cashier #t)
  (insert-operator! connection "inactive" "Inactive" 'cashier #f)
  (insert-operator! connection "unenrolled" "Unenrolled" 'cashier #t
                    #:credential? #f)
  (define now (box 1000))
  (define verify-calls (box '()))
  (define (fake-verify pin hash)
    (set-box! verify-calls (cons hash (unbox verify-calls)))
    (and (string=? pin good-pin) (string=? hash real-hash)))
  (define service
    (make-authentication-service
     connection
     #:current-epoch-ms (lambda () (unbox now))
     #:verify-pin fake-verify
     #:dummy-password-hash dummy-hash
     #:after-verification after-verification
     #:session-store
     (make-operator-session-store
      #:current-monotonic-ms (lambda () (unbox now))
      #:current-epoch-ms (lambda () (unbox now)))))
  (dynamic-wind
    void
    (lambda () (procedure connection service now verify-calls))
    (lambda ()
      (when (connected? connection) (disconnect connection)))))

(define (successful-login service [operator-id "cashier-1"])
  (define result
    (authentication-service-login service operator-id good-pin))
  (check-pred authentication-login-succeeded? result)
  result)

(module+ test
  (test-case "correct credentials issue one safe register session"
    (call-with-authentication
     (lambda (_connection service _now verify-calls)
       (define result (successful-login service))
       (check-regexp-match
        #px"^gpos_s1_[0-9a-f]{64}$"
        (authentication-login-succeeded-access-token result))
       (define principal (authentication-login-succeeded-principal result))
       (check-equal? (authenticated-operator-operator-id principal) "cashier-1")
       (check-equal? (authenticated-operator-display-name principal) "Cashier One")
       (check-equal? (authenticated-operator-role principal) 'cashier)
       (check-equal? (unbox verify-calls) (list real-hash)))))

  (test-case "ineligible identities and wrong PIN share one public result"
    (call-with-authentication
     (lambda (_connection service _now verify-calls)
       (for ([attempt
              (in-list
               (list (list "cashier-1" "80421638")
                     (list "missing" good-pin)
                     (list "inactive" good-pin)
                     (list "unenrolled" good-pin)
                     (list "" good-pin)
                     (list "cashier-1" "short")))])
         (check-pred
          authentication-login-failed?
          (authentication-service-login service (first attempt) (second attempt))))
       (check-not-false (member real-hash (unbox verify-calls)))
       (check-not-false (member dummy-hash (unbox verify-calls)))
       (check-false
        (load-operator-login-throttle
         (authentication-service-connection service) "missing")))))

  (test-case "blocked known operator uses dummy verification without extending state"
    (call-with-authentication
     (lambda (connection service now verify-calls)
       (for ([attempt (in-range 4)])
         (set-box! now (+ 1000 attempt))
         (authentication-service-login service "cashier-1" "80421638"))
       (define before
         (load-operator-login-throttle connection "cashier-1"))
       (set-box! verify-calls '())
       (set-box! now 2000)
       (check-pred authentication-login-failed?
                   (authentication-service-login service "cashier-1" good-pin))
       (check-equal? (unbox verify-calls) (list dummy-hash))
       (check-equal?
        (load-operator-login-throttle connection "cashier-1") before))))

  (test-case "successful login clears durable throttle state"
    (call-with-authentication
     (lambda (connection service now _verify-calls)
       (authentication-service-login service "cashier-1" "80421638")
       (check-not-false
        (load-operator-login-throttle connection "cashier-1"))
       (set-box! now 2000)
       (successful-login service)
       (check-false
        (load-operator-login-throttle connection "cashier-1")))))

  (test-case "authoritative state is re-read after expensive verification"
    (define connection-for-hook (box #f))
    (define fired? #f)
    (call-with-authentication
     (lambda (connection service _now _verify-calls)
       (set-box! connection-for-hook connection)
       (check-pred authentication-login-failed?
                   (authentication-service-login service "cashier-1" good-pin)))
     #:after-verification
     (lambda ()
       (unless fired?
         (set! fired? #t)
         (query-exec (unbox connection-for-hook)
                     "UPDATE operators SET active = 0 WHERE operator_id = 'cashier-1'")))))

  (test-case "new login replaces old token and logout revokes current token"
    (call-with-authentication
     (lambda (_connection service _now _verify-calls)
       (define first (successful-login service))
       (define first-token (authentication-login-succeeded-access-token first))
       (define second (successful-login service))
       (define second-token (authentication-login-succeeded-access-token second))
       (check-pred authentication-session-invalid?
                   (authentication-service-authenticate service first-token))
       (check-pred authentication-session-authenticated?
                   (authentication-service-authenticate service second-token))
       (check-pred authentication-logout-succeeded?
                   (authentication-service-logout service second-token))
       (check-pred authentication-session-invalid?
                   (authentication-service-authenticate service second-token)))))

  (test-case "current security state controls every authenticated request"
    (call-with-authentication
     (lambda (connection service _now _verify-calls)
       (define login (successful-login service))
       (define token (authentication-login-succeeded-access-token login))
       (query-exec connection
                   "UPDATE operator_roles SET role = 'manager' WHERE operator_id = 'cashier-1'")
       (define current (authentication-service-authenticate service token))
       (check-pred authentication-session-authenticated? current)
       (check-equal?
        (authenticated-operator-role
         (authentication-session-authenticated-principal current))
        'manager)
       (query-exec connection
                   "DELETE FROM operator_pin_credentials WHERE operator_id = 'cashier-1'")
       (check-pred authentication-session-invalid?
                   (authentication-service-authenticate service token))
       (query-exec connection
                   "INSERT INTO operator_pin_credentials VALUES ('cashier-1', ?, 1)"
                   real-hash)
       (define revision-login (successful-login service))
       (define revision-token
         (authentication-login-succeeded-access-token revision-login))
       (query-exec connection
                   "UPDATE operator_pin_credentials SET credential_revision = 2 WHERE operator_id = 'cashier-1'")
       (check-pred authentication-session-invalid?
                   (authentication-service-authenticate service revision-token))
       (define next (successful-login service))
       (define next-token (authentication-login-succeeded-access-token next))
       (query-exec connection
                   "UPDATE operators SET active = 0 WHERE operator_id = 'cashier-1'")
       (check-pred authentication-session-invalid?
                   (authentication-service-authenticate service next-token)))))

  (test-case "database availability failure retains rather than revokes session"
    (call-with-authentication
     (lambda (connection service _now _verify-calls)
       (define login (successful-login service))
       (define token (authentication-login-succeeded-access-token login))
       (disconnect connection)
       (check-pred authentication-session-unavailable?
                   (authentication-service-authenticate service token))
       (check-not-false
        (operator-session-store-find
         (authentication-service-session-store service) token)))))

  (test-case "only authoritative authentication success refreshes idle activity"
    (call-with-authentication
     (lambda (connection service now _verify-calls)
       (define login (successful-login service))
       (define token (authentication-login-succeeded-access-token login))
       (define store (authentication-service-session-store service))
       (check-equal?
        (operator-session-last-activity-at-monotonic-ms
         (operator-session-store-current store))
        1000)

       (set-box! now 2000)
       (check-pred authentication-session-authenticated?
                   (authentication-service-authenticate service token))
       (check-equal?
        (operator-session-last-activity-at-monotonic-ms
         (operator-session-store-current store))
        2000)

       (disconnect connection)
       (set-box! now 3000)
       (check-pred authentication-session-unavailable?
                   (authentication-service-authenticate service token))
       (check-equal?
        (operator-session-last-activity-at-monotonic-ms
         (operator-session-store-current store))
        2000))))

  (test-case "definitive authoritative rejection invalidates without refresh"
    (call-with-authentication
     (lambda (connection service now _verify-calls)
       (define login (successful-login service))
       (define token (authentication-login-succeeded-access-token login))
       (set-box! now 2000)
       (query-exec connection
                   "UPDATE operators SET active = 0 WHERE operator_id = 'cashier-1'")
       (check-pred authentication-session-invalid?
                   (authentication-service-authenticate service token))
       (check-false
        (operator-session-store-current
         (authentication-service-session-store service))))))

  (test-case "session-store reconstruction fails secure while throttle is durable"
    (call-with-authentication
     (lambda (connection service now _verify-calls)
       (define login (successful-login service))
       (define token (authentication-login-succeeded-access-token login))
       (authentication-service-login service "cashier-1" "80421638")
       (define reconstructed
         (make-authentication-service
          connection
          #:current-epoch-ms (lambda () (unbox now))
          #:verify-pin (lambda (pin hash)
                         (and (string=? pin good-pin)
                              (string=? hash real-hash)))
          #:dummy-password-hash dummy-hash))
       (check-pred authentication-session-invalid?
                   (authentication-service-authenticate reconstructed token))
       (check-not-false
        (load-operator-login-throttle connection "cashier-1"))))))
