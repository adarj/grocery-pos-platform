#lang racket

(require db
         rackunit
         "../pos/application/authentication-service.rkt"
         "../pos/application/operator-service.rkt"
         "../pos/domain/operator-identity.rkt"
         "../pos/domain/security-audit-event.rkt"
         "../pos/persistence/pos-database-migrations.rkt"
         "../pos/persistence/security-audit-store.rkt"
         "../pos/persistence/sqlite-auth-throttle.rkt"
         "../pos/persistence/sqlite-operators.rkt"
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
  (test-case "all structurally valid login failures audit the same null identity"
    (call-with-authentication
     (lambda (connection service now verify-calls)
       (for ([attempt
              (in-list
               (list (list "unknown-CLAIMED-ID" good-pin)
                     (list "inactive" good-pin)
                     (list "unenrolled" good-pin)
                     (list "cashier-1" "80421638")
                     (list "cashier-1" "not-a-pin")))])
         (check-pred authentication-login-failed?
                     (authentication-service-login
                      service (first attempt) (second attempt))))
       (for ([index (in-range 3)])
         (set-box! now (+ 2000 index))
         (check-pred authentication-login-failed?
                     (authentication-service-login
                      service "cashier-1" "80421638")))
       (set-box! now 2004)
       (check-pred authentication-login-failed?
                   (authentication-service-login service "cashier-1" good-pin))
       (check-not-false (member real-hash (unbox verify-calls)))
       (check-not-false (member dummy-hash (unbox verify-calls)))
       (define failed-json
         (query-list
          connection
          "SELECT event_json FROM security_audit_events WHERE event_type = 'auth.login_failed' ORDER BY sequence"))
       (check-equal? (length failed-json) 9)
       (check-true
        (andmap (lambda (text) (string=? text "{\"operator_id\":null}"))
                failed-json))
       (check-false
        (regexp-match? #rx"unknown-CLAIMED-ID|not-a-pin|\\$argon2id"
                       (format "~s" failed-json))))))

  (test-case "failed required login audit locks both first and replacement attempts"
    (call-with-authentication
     (lambda (connection _service now _calls)
       (insert-operator! connection "cashier-bob" "Bob" 'cashier #t)
       (define sessions
         (make-operator-session-store
          #:current-monotonic-ms (lambda () (unbox now))
          #:current-epoch-ms (lambda () (unbox now))))
       (define fail-audit? (box #t))
       (define attempted-session-id (box #f))
       (define service
         (make-authentication-service
          connection
          #:session-store sessions
          #:verify-pin
          (lambda (pin hash)
            (and (string=? pin good-pin) (string=? hash real-hash)))
          #:dummy-password-hash dummy-hash
          #:audit-append!
          (lambda (writer event)
            (when (unbox fail-audit?)
              (set-box! attempted-session-id
                        (operator-session-session-id
                         (operator-session-store-current sessions)))
              (error 'test "required audit unavailable"))
            (append-security-audit-event!
             writer event
             #:source-kind 'pos_core
             #:source-instance-id "audit_runtime_login_test"
             #:occurred-at-epoch-ms (unbox now)))))
       (check-pred authentication-login-unavailable?
                   (authentication-service-login service "cashier-1" good-pin))
       (check-true (string? (unbox attempted-session-id)))
       (check-false (operator-session-store-current sessions))
       (set-box! fail-audit? #f)
       (define alice (successful-login service))
       (define alice-token (authentication-login-succeeded-access-token alice))
       (set-box! fail-audit? #t)
       (check-pred authentication-login-unavailable?
                   (authentication-service-login service "cashier-bob" good-pin))
       (check-false (operator-session-store-current sessions))
       (check-pred authentication-session-invalid?
                   (authentication-service-authenticate service alice-token))
       (check-equal?
        (query-value connection
                     "SELECT COUNT(*) FROM security_audit_events WHERE event_type = 'auth.login_succeeded'")
        1))))

  (test-case "session audit callbacks run after the process-local semaphore is released"
    (call-with-authentication
     (lambda (connection _service now _calls)
       (define sessions
         (make-operator-session-store
          #:current-monotonic-ms (lambda () (unbox now))
          #:current-epoch-ms (lambda () (unbox now))))
       (define lock-probes (box '()))
       (define (probe-store-lock)
         (define answer (make-channel))
         (define probe
           (thread
            (lambda ()
              (channel-put answer (list (operator-session-store-current sessions))))))
         (define observed (sync/timeout 1 answer))
         (unless observed (kill-thread probe))
         (set-box! lock-probes (cons (and observed #t) (unbox lock-probes))))
       (define service
         (make-authentication-service
          connection
          #:session-store sessions
          #:current-epoch-ms (lambda () (unbox now))
          #:verify-pin
          (lambda (pin hash)
            (and (string=? pin good-pin) (string=? hash real-hash)))
          #:dummy-password-hash dummy-hash
          #:audit-append!
          (lambda (writer event)
            (probe-store-lock)
            (append-security-audit-event!
             writer event
             #:source-kind 'pos_core
             #:source-instance-id "audit_runtime_lock_probe"
             #:occurred-at-epoch-ms (unbox now)))))
       (define logout-token
         (authentication-login-succeeded-access-token (successful-login service)))
       (check-pred authentication-logout-succeeded?
                   (authentication-service-logout service logout-token))
       (define idle-token
         (authentication-login-succeeded-access-token (successful-login service)))
       (set-box! now (+ (unbox now) operator-session-idle-timeout-ms))
       (check-pred authentication-session-invalid?
                   (authentication-service-authenticate service idle-token))
       (define absolute-token
         (authentication-login-succeeded-access-token (successful-login service)))
       (set-box! now (+ (unbox now) operator-session-absolute-timeout-ms))
       (check-pred authentication-session-invalid?
                   (authentication-service-authenticate service absolute-token))
       (define disabled-token
         (authentication-login-succeeded-access-token (successful-login service)))
       (query-exec connection
                   "UPDATE operators SET active = 0 WHERE operator_id = 'cashier-1'")
       (check-pred authentication-session-invalid?
                   (authentication-service-authenticate service disabled-token))
       (query-exec connection
                   "UPDATE operators SET active = 1 WHERE operator_id = 'cashier-1'")
       (define revision-token
         (authentication-login-succeeded-access-token (successful-login service)))
       (query-exec connection
                   "UPDATE operator_pin_credentials SET credential_revision = 2 WHERE operator_id = 'cashier-1'")
       (check-pred authentication-session-invalid?
                   (authentication-service-authenticate service revision-token))
       (check-equal? (length (unbox lock-probes)) 10)
       (check-true (andmap values (unbox lock-probes))))))

  (test-case "best-effort failure/logout audit cannot reverse denial or revocation"
    (call-with-authentication
     (lambda (connection _service now _calls)
       (define fail-audit? (box #f))
       (define sessions
         (make-operator-session-store
          #:current-monotonic-ms (lambda () (unbox now))
          #:current-epoch-ms (lambda () (unbox now))))
       (define service
         (make-authentication-service
          connection
          #:session-store sessions
          #:verify-pin
          (lambda (pin hash)
            (and (string=? pin good-pin) (string=? hash real-hash)))
          #:dummy-password-hash dummy-hash
          #:audit-append!
          (lambda (_connection _event)
            (when (unbox fail-audit?)
              (error 'test "simulated audit failure")))))
       (define login (successful-login service))
       (set-box! fail-audit? #t)
       (check-pred authentication-login-failed?
                   (authentication-service-login
                    service "cashier-1" "80421638"))
       (define authenticated
         (authentication-service-authenticate
          service (authentication-login-succeeded-access-token login)))
       (check-pred authentication-session-authenticated? authenticated)
       (check-not-exn
        (lambda ()
          (authentication-service-record-authorization-denial!
           service authenticated 'cashier_directory.read
           'cashier_directory)))
       (check-pred authentication-logout-succeeded?
                   (authentication-service-logout
                    service (authentication-login-succeeded-access-token login)))
       (check-false (operator-session-store-current sessions))
       (set-box! fail-audit? #f)
       (define expiring (successful-login service))
       (set-box! fail-audit? #t)
       (set-box! now (+ (unbox now) operator-session-idle-timeout-ms))
       (check-pred
        authentication-session-invalid?
        (authentication-service-authenticate
         service (authentication-login-succeeded-access-token expiring)))
       (check-false (operator-session-store-current sessions)))))

  (test-case "observed idle expiry and authoritative disable leave safe audit evidence"
    (call-with-authentication
     (lambda (connection service now _calls)
       (define first (successful-login service))
       (set-box! now (+ (unbox now) operator-session-idle-timeout-ms))
       (check-pred
        authentication-session-invalid?
        (authentication-service-authenticate
         service (authentication-login-succeeded-access-token first)))
       (check-equal?
        (query-value connection
                     "SELECT event_type FROM security_audit_events ORDER BY sequence DESC LIMIT 1")
        "auth.session_expired")
       (define second (successful-login service))
       (query-exec connection
                   "UPDATE operators SET active = 0 WHERE operator_id = 'cashier-1'")
       (check-pred
        authentication-session-invalid?
        (authentication-service-authenticate
         service (authentication-login-succeeded-access-token second)))
       (check-equal?
        (query-value connection
                     "SELECT event_type FROM security_audit_events ORDER BY sequence DESC LIMIT 1")
        "auth.session_invalidated"))))

  (test-case "observed credential rotation invalidates the old session with safe audit reason"
    (call-with-authentication
     (lambda (connection service _now _calls)
       (define login (successful-login service))
       (query-exec connection
                   "UPDATE operator_pin_credentials SET credential_revision = 2 WHERE operator_id = 'cashier-1'")
       (check-pred
        authentication-session-invalid?
        (authentication-service-authenticate
         service (authentication-login-succeeded-access-token login)))
       (check-false
        (operator-session-store-current
         (authentication-service-session-store service)))
       (check-equal?
        (query-value connection
                     "SELECT event_type FROM security_audit_events ORDER BY sequence DESC LIMIT 1")
        "auth.session_invalidated")
       (check-true
        (regexp-match?
         #rx"credential_changed"
         (query-value connection
                      "SELECT event_json FROM security_audit_events ORDER BY sequence DESC LIMIT 1"))))))

  (test-case "required login audit failure invalidates newly issued bearer"
    (call-with-authentication
     (lambda (connection _service now _calls)
       (define sessions
         (make-operator-session-store
          #:current-monotonic-ms (lambda () (unbox now))
          #:current-epoch-ms (lambda () (unbox now))))
       (define failing
         (make-authentication-service
          connection
          #:session-store sessions
          #:verify-pin
          (lambda (pin hash)
            (and (string=? pin good-pin) (string=? hash real-hash)))
          #:dummy-password-hash dummy-hash
          #:audit-append!
          (lambda (_connection _event)
            (error 'test "simulated required audit failure"))))
       (define previous
         (operator-session-store-issue! sessions "cashier-1" 1))
       (check-pred
        authentication-login-unavailable?
        (authentication-service-login failing "cashier-1" good-pin))
       (check-false (operator-session-store-current sessions))
       (check-false
        (operator-session-store-find
         sessions (issued-operator-session-access-token previous))))))

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

(module+ test
  (test-case "self-change verifies old PIN, rotates revision, audits and locks"
    (call-with-authentication
     (lambda (connection _original now _verify-calls)
       (define sessions
         (make-operator-session-store
          #:current-monotonic-ms (lambda () (unbox now))
          #:current-epoch-ms (lambda () (unbox now))))
       (define replacement-pin "48295173")
       (define service
         (make-authentication-service
          connection
          #:session-store sessions
          #:current-epoch-ms (lambda () (unbox now))
          #:verify-pin
          (lambda (pin hash)
            (or (and (string=? pin good-pin) (string=? hash real-hash))
                (and (string=? pin replacement-pin)
                     (string=? hash dummy-hash))))
          #:hash-pin (lambda (pin)
                       (check-equal? pin replacement-pin)
                       dummy-hash)
          #:dummy-password-hash dummy-hash))
       (define login (successful-login service))
       (define token (authentication-login-succeeded-access-token login))
       (check-pred
        authentication-pin-change-policy-rejected?
        (authentication-service-change-pin
         service (authentication-login-succeeded-principal login)
         token good-pin "12345678"))
       (check-pred
        authentication-pin-change-failed?
        (authentication-service-change-pin
         service (authentication-login-succeeded-principal login)
         token "80421638" replacement-pin))
       (check-equal?
        (operator-login-throttle-consecutive-failures
         (load-operator-login-throttle connection "cashier-1"))
        1)
       (define changed
         (authentication-service-change-pin
          service (authentication-login-succeeded-principal login)
          token good-pin replacement-pin))
       (check-pred authentication-pin-change-succeeded? changed)
       (check-equal?
        (authentication-pin-change-succeeded-credential-revision changed) 2)
       (check-equal?
        (operator-pin-record-credential-revision
         (load-operator-pin-record connection "cashier-1")) 2)
       (check-false (load-operator-login-throttle connection "cashier-1"))
       (check-pred authentication-session-invalid?
                   (authentication-service-authenticate service token))
       (check-pred authentication-login-failed?
                   (authentication-service-login service "cashier-1" good-pin))
       (check-pred authentication-login-succeeded?
                   (authentication-service-login
                    service "cashier-1" replacement-pin))
       (check-equal?
        (query-list
         connection
         "SELECT event_type FROM security_audit_events WHERE event_type LIKE 'operator.pin_change%' ORDER BY sequence")
        '("operator.pin_change_failed" "operator.pin_changed"))))

  (test-case "required self-change audit failure rolls back rotation and leaves bearer valid"
    (call-with-authentication
     (lambda (connection _original now _verify-calls)
       (define service
         (make-authentication-service
          connection
          #:current-epoch-ms (lambda () (unbox now))
          #:verify-pin (lambda (pin hash)
                         (and (string=? pin good-pin)
                              (string=? hash real-hash)))
          #:hash-pin (lambda (_pin) dummy-hash)
          #:dummy-password-hash dummy-hash
          #:audit-append-in-transaction!
          (lambda (_writer _event)
            (error 'test "required audit append failed"))))
       (define login (successful-login service))
       (define token (authentication-login-succeeded-access-token login))
       (query-exec
        connection
        "INSERT INTO operator_login_throttle VALUES ('cashier-1', 2, 1000, 1000)")
       (query-exec
        connection
        #<<SQL
INSERT INTO transaction_void_approval_grants
  (approval_id, token_digest, issuer_instance_id, requester_operator_id,
   requester_credential_revision, approver_operator_id,
   approver_credential_revision, command_id, transaction_id,
   command_schema_version, expected_version, granted_at_monotonic_ms,
   expires_at_monotonic_ms, expires_at_epoch_ms)
VALUES ('grant-self-change-rollback', zeroblob(32), 'instance',
        'cashier-1', 1, 'approver', 1, 'command-self-change-rollback',
        'transaction', 1, 1, 100, 190, 1000)
SQL
        )
       (check-pred
        authentication-pin-change-unavailable?
        (authentication-service-change-pin
         service (authentication-login-succeeded-principal login)
         token good-pin "48295173"))
       (check-equal?
        (operator-pin-record-credential-revision
         (load-operator-pin-record connection "cashier-1")) 1)
       (check-equal?
        (operator-pin-record-password-hash
         (load-operator-pin-record connection "cashier-1")) real-hash)
       (check-equal?
        (operator-login-throttle-consecutive-failures
         (load-operator-login-throttle connection "cashier-1")) 2)
       (check-equal?
        (query-value connection
                     "SELECT COUNT(*) FROM transaction_void_approval_grants WHERE approval_id = 'grant-self-change-rollback'")
        1)
       (check-pred authentication-session-authenticated?
                   (authentication-service-authenticate service token))
       (check-pred authentication-login-succeeded?
                   (authentication-service-login service "cashier-1" good-pin))
       (check-pred authentication-login-failed?
                   (authentication-service-login service "cashier-1" "48295173"))
       (check-equal?
        (query-value connection
                     "SELECT COUNT(*) FROM security_audit_events WHERE event_type = 'operator.pin_changed'")
        0))))))

(module+ test
  (test-case "post-commit session cleanup failure cannot report no-commit 503"
    (call-with-authentication
     (lambda (connection _original now _calls)
       (define new-pin "48295173")
       (define service
         (make-authentication-service
          connection
          #:current-epoch-ms (lambda () (unbox now))
          #:verify-pin
          (lambda (pin hash)
            (or (and (string=? pin good-pin) (string=? hash real-hash))
                (and (string=? pin new-pin) (string=? hash dummy-hash))))
          #:hash-pin (lambda (_pin) dummy-hash)
          #:dummy-password-hash dummy-hash
          #:invalidate-session!
          (lambda (_store _token)
            (error 'test "injected post-commit session cleanup failure"))))
       (define login (successful-login service))
       (define token (authentication-login-succeeded-access-token login))
       (check-pred
        authentication-pin-change-succeeded?
        (authentication-service-change-pin
         service (authentication-login-succeeded-principal login)
         token good-pin new-pin))
       (check-equal?
        (operator-pin-record-credential-revision
         (load-operator-pin-record connection "cashier-1")) 2)
       (check-pred authentication-session-invalid?
                   (authentication-service-authenticate service token))
       (check-pred authentication-login-failed?
                   (authentication-service-login service "cashier-1" good-pin))
       (check-pred authentication-login-succeeded?
                   (authentication-service-login service "cashier-1" new-pin)))))

  (test-case "root reset winning during self-change hashing rejects stale self-change"
    (call-with-authentication
     (lambda (connection _original now _calls)
       (define root-reset-count (box 0))
       (define service
         (make-authentication-service
          connection
          #:current-epoch-ms (lambda () (unbox now))
          #:verify-pin
          (lambda (pin hash)
            (and (string=? pin good-pin) (string=? hash real-hash)))
          #:hash-pin
          (lambda (_pin)
            (set-box! root-reset-count (add1 (unbox root-reset-count)))
            (check-pred
             operator-pin-reset-succeeded?
             (operator-service-reset-pin
              (make-operator-service
               connection #:hash-pin (lambda (_pin) dummy-hash))
              "cashier-1" "58310472"))
            real-hash)
          #:dummy-password-hash dummy-hash))
       (define login (successful-login service))
       (check-pred
        authentication-pin-change-failed?
        (authentication-service-change-pin
         service (authentication-login-succeeded-principal login)
         (authentication-login-succeeded-access-token login)
         good-pin "48295173"))
       (check-equal? (unbox root-reset-count) 1)
       (define credential (load-operator-pin-record connection "cashier-1"))
       (check-equal? (operator-pin-record-credential-revision credential) 2)
       (check-equal? (operator-pin-record-password-hash credential) dummy-hash)
       (check-equal?
        (query-list connection
                    "SELECT event_type FROM security_audit_events WHERE event_type IN ('operator.pin_changed', 'operator.pin_reset')")
        '("operator.pin_reset")))))

  (test-case "self-change winning during root hashing rejects stale root reset"
    (call-with-authentication
     (lambda (connection _original now _calls)
       (define service
         (make-authentication-service
          connection
          #:current-epoch-ms (lambda () (unbox now))
          #:verify-pin
          (lambda (pin hash)
            (and (string=? pin good-pin) (string=? hash real-hash)))
          #:hash-pin (lambda (_pin) dummy-hash)
          #:dummy-password-hash dummy-hash))
       (define login (successful-login service))
       (define nested-change-count (box 0))
       (define root
         (make-operator-service
          connection
          #:hash-pin
          (lambda (_pin)
            (set-box! nested-change-count (add1 (unbox nested-change-count)))
            (check-pred
             authentication-pin-change-succeeded?
             (authentication-service-change-pin
              service (authentication-login-succeeded-principal login)
              (authentication-login-succeeded-access-token login)
              good-pin "48295173"))
            real-hash)))
       (define reset (operator-service-reset-pin root "cashier-1" "58310472"))
       (check-pred operator-pin-reset-rejected? reset)
       (check-equal? (operator-pin-reset-rejected-code reset)
                     'credential-concurrently-changed)
       (check-equal? (unbox nested-change-count) 1)
       (define credential (load-operator-pin-record connection "cashier-1"))
       (check-equal? (operator-pin-record-credential-revision credential) 2)
       (check-equal? (operator-pin-record-password-hash credential) dummy-hash)
       (check-equal?
        (query-list connection
                    "SELECT event_type FROM security_audit_events WHERE event_type IN ('operator.pin_changed', 'operator.pin_reset')")
        '("operator.pin_changed")))))

  (test-case "one self-change wins when two verified changes share a revision"
    (call-with-authentication
     (lambda (connection _original now _calls)
       (define (service-with-hash hash-pin)
         (make-authentication-service
          connection
          #:current-epoch-ms (lambda () (unbox now))
          #:verify-pin
          (lambda (pin hash)
            (and (string=? pin good-pin) (string=? hash real-hash)))
          #:hash-pin hash-pin
          #:dummy-password-hash dummy-hash))
       (define inner (service-with-hash (lambda (_pin) dummy-hash)))
       (define login (successful-login inner))
       (define principal (authentication-login-succeeded-principal login))
       (define token (authentication-login-succeeded-access-token login))
       (define outer
         (service-with-hash
          (lambda (_pin)
            (check-pred authentication-pin-change-succeeded?
                        (authentication-service-change-pin
                         inner principal token good-pin "48295173"))
            real-hash)))
       (check-pred authentication-pin-change-failed?
                   (authentication-service-change-pin
                    outer principal token good-pin "58310472"))
       (define credential (load-operator-pin-record connection "cashier-1"))
       (check-equal? (operator-pin-record-credential-revision credential) 2)
       (check-equal? (operator-pin-record-password-hash credential) dummy-hash)
       (check-equal?
        (query-value connection
                     "SELECT COUNT(*) FROM security_audit_events WHERE event_type = 'operator.pin_changed'")
        1)))))

(module+ test
  (test-case "a live bearer does not bypass credential verification throttle"
    (call-with-authentication
     (lambda (connection service now _calls)
       (define login (successful-login service))
       (query-exec
        connection
        "INSERT INTO operator_login_throttle VALUES ('cashier-1', 4, 1000, 6000)")
       (check-pred
        authentication-pin-change-failed?
        (authentication-service-change-pin
         service (authentication-login-succeeded-principal login)
         (authentication-login-succeeded-access-token login)
         good-pin "48295173"))
       (check-equal?
        (operator-pin-record-credential-revision
         (load-operator-pin-record connection "cashier-1")) 1)
       (check-true
        (operator-login-throttle-blocked?
         (load-operator-login-throttle connection "cashier-1")
         (unbox now)))
       (check-equal?
        (query-list connection
                    "SELECT event_type FROM security_audit_events WHERE event_type LIKE 'operator.pin_change%'")
        '("operator.pin_change_failed"))))))
