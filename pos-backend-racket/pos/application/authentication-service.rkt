#lang racket

(require (prefix-in db: db)
         file/sha1
         racket/random
         "security-audit-service.rkt"
         "../domain/operator-identity.rkt"
         "../domain/security-audit-event.rkt"
         "../persistence/sqlite-authentication.rkt"
         "../persistence/sqlite-auth-throttle.rkt"
         "../persistence/sqlite-operators.rkt"
         "../security/operator-pin.rkt"
         "../security/operator-session.rkt")

(provide make-authentication-service
         authentication-service?
         authentication-service-connection
         authentication-service-session-store
         (struct-out authenticated-operator)
         (struct-out authentication-login-succeeded)
         (struct-out authentication-login-failed)
         (struct-out authentication-login-unavailable)
         (struct-out authentication-session-authenticated)
         (struct-out authentication-session-invalid)
         (struct-out authentication-session-unavailable)
         (struct-out authentication-logout-succeeded)
         (struct-out authentication-credential-verification-failed)
         (struct-out authentication-credential-verification-unavailable)
         authentication-service-with-verified-credential
         authentication-service-login
         authentication-service-authenticate
         authentication-service-logout
         authentication-service-record-authorization-denial!)

(define dummy-pin "50627184")
(define default-dummy-password-hash
  (delay (hash-operator-pin dummy-pin)))

(struct authenticated-operator (operator-id display-name role) #:transparent)
(struct authentication-login-succeeded
  (access-token principal session-id absolute-expires-at-epoch-ms)
  #:transparent)
(struct authentication-login-failed () #:transparent)
(struct authentication-login-unavailable () #:transparent)
(struct authentication-session-authenticated (principal session) #:transparent)
(struct authentication-session-invalid () #:transparent)
(struct authentication-session-unavailable () #:transparent)
(struct authentication-logout-succeeded () #:transparent)
(struct authentication-credential-verification-failed () #:transparent)
(struct authentication-credential-verification-unavailable () #:transparent)

(struct authentication-service
  (connection
   session-store
   current-epoch-ms
   verify-pin
   dummy-password-hash
   attempt-lock
   after-verification
   audit-append!)
  #:transparent)

(define (system-current-epoch-ms)
  (inexact->exact (floor (current-inexact-milliseconds))))

(define (system-current-monotonic-ms)
  (inexact->exact (floor (current-inexact-monotonic-milliseconds))))

(define (check-procedure who value arity name)
  (unless (and (procedure? value) (procedure-arity-includes? value arity))
    (raise-arguments-error who "invalid procedure" name value)))

(define (make-authentication-service
         connection
         #:session-store [session-store #f]
         #:current-monotonic-ms
         [current-monotonic-ms system-current-monotonic-ms]
         #:current-epoch-ms [current-epoch-ms system-current-epoch-ms]
         #:verify-pin [verify-pin verify-operator-pin]
         #:dummy-password-hash [dummy-password-hash #f]
         #:after-verification [after-verification void]
         #:audit-source [audit-source #f]
         #:audit-append! [audit-append! #f])
  (define who 'make-authentication-service)
  (unless (db:connection? connection)
    (raise-argument-error who "connection?" connection))
  (check-procedure who current-monotonic-ms 0 "current-monotonic-ms")
  (check-procedure who current-epoch-ms 0 "current-epoch-ms")
  (check-procedure who verify-pin 2 "verify-pin")
  (check-procedure who after-verification 0 "after-verification")
  (define effective-session-store
    (or session-store
        (make-operator-session-store
         #:current-monotonic-ms current-monotonic-ms
         #:current-epoch-ms current-epoch-ms)))
  (unless (operator-session-store? effective-session-store)
    (raise-argument-error who "operator-session-store?" effective-session-store))
  (define effective-dummy-hash
    (or dummy-password-hash (force default-dummy-password-hash)))
  (unless (operator-pin-password-hash-supported? effective-dummy-hash)
    (raise-argument-error
     who "supported-operator-pin-password-hash?" effective-dummy-hash))
  (define source
    (or audit-source
        (make-security-audit-source
         'pos_core
         (string-append "audit_runtime_"
                        (bytes->hex-string (crypto-random-bytes 16)))
         current-epoch-ms)))
  (unless (security-audit-source? source)
    (raise-argument-error who "security-audit-source?" source))
  (define effective-audit-append!
    (or audit-append!
        (lambda (audit-connection event)
          (security-audit-append-required!
           source audit-connection event))))
  (check-procedure who effective-audit-append! 2 "audit-append!")
  (authentication-service
   connection
   effective-session-store
   current-epoch-ms
   verify-pin
   effective-dummy-hash
   (make-semaphore 1)
   after-verification
   effective-audit-append!))

(define (append-auth-audit-best-effort! service event)
  (with-handlers ([exn:fail?
                   (lambda (_exception)
                     (eprintf "security audit append failed\n")
                     #f)])
    ((authentication-service-audit-append! service)
     (authentication-service-connection service) event)
    #t))

(define (authentication-service-record-authorization-denial!
         service authenticated action resource-kind [resource-id #f])
  (define principal
    (authentication-session-authenticated-principal authenticated))
  (define session
    (authentication-session-authenticated-session authenticated))
  (append-auth-audit-best-effort!
   service
   (authorization-denied-event
    (authenticated-operator-operator-id principal)
    (authenticated-operator-role principal)
    (operator-session-session-id session)
    action resource-kind resource-id)))

(define (operator->principal operator)
  (authenticated-operator
   (operator-identity-operator-id operator)
   (operator-identity-display-name operator)
   (operator-identity-role operator)))

(define (attempt-credential-under-lock service operator-id pin on-verified)
  (define connection (authentication-service-connection service))
  (define now ((authentication-service-current-epoch-ms service)))
  (define valid-id?
    (and (string? operator-id) (positive? (string-length operator-id))))
  (define operator (and valid-id? (load-operator connection operator-id)))
  (define credential
    (and operator (load-operator-pin-record connection operator-id)))
  (define throttle
    (and operator (load-operator-login-throttle connection operator-id)))
  (define blocked?
    (and throttle (operator-login-throttle-blocked? throttle now)))
  (define eligible?
    (and operator
         (operator-identity-active? operator)
         credential
         (operator-pin-verification-input-valid? pin)
         (operator-pin-password-hash-supported?
          (operator-pin-record-password-hash credential))
         (not blocked?)))
  (define checked-hash
    (if eligible?
        (operator-pin-record-password-hash credential)
        (authentication-service-dummy-password-hash service)))
  ;; Invalid syntax still incurs the current real Argon2 cost using a fixed
  ;; safe input; database/account distinctions do not get a fast path.
  (define checked-pin
    (if (operator-pin-verification-input-valid? pin) pin dummy-pin))
  (define verified?
    (with-handlers ([exn:fail? (lambda (_exception) #f)])
      ((authentication-service-verify-pin service) checked-pin checked-hash)))
  ((authentication-service-after-verification service))
  (cond
    [(and eligible? verified?)
     (on-verified
      operator
      (operator-pin-record-password-hash credential)
      (operator-pin-record-credential-revision credential))]
    [else
     (when (and operator (not blocked?))
       (record-operator-login-failure! connection operator-id now))
     (authentication-credential-verification-failed)]))

(define (authentication-service-with-verified-credential
         service operator-id pin on-verified)
  (define who 'authentication-service-with-verified-credential)
  (unless (authentication-service? service)
    (raise-argument-error who "authentication-service?" service))
  (check-procedure who on-verified 3 "on-verified")
  (call-with-semaphore
   (authentication-service-attempt-lock service)
   (lambda ()
     (with-handlers ([exn:fail?
                      (lambda (_exception)
                        (authentication-credential-verification-unavailable))])
       (attempt-credential-under-lock
        service operator-id pin on-verified)))))

(define (authentication-service-login service operator-id pin)
  (unless (authentication-service? service)
    (raise-argument-error
     'authentication-service-login "authentication-service?" service))
  (define result
    (authentication-service-with-verified-credential
     service
     operator-id
     pin
     (lambda (_operator password-hash credential-revision)
       (define confirmation
         (confirm-operator-login!
          (authentication-service-connection service)
          operator-id
          password-hash
          credential-revision))
       (cond
         [(operator-login-confirmed? confirmation)
          (define current-operator
            (operator-login-confirmed-operator confirmation))
          (define issued
            (operator-session-store-issue!
             (authentication-service-session-store service)
             operator-id
             credential-revision))
          (with-handlers
              ([exn:fail?
                (lambda (_exception)
                  (operator-session-store-invalidate!
                   (authentication-service-session-store service)
                   (issued-operator-session-access-token issued))
                  (authentication-login-unavailable))])
            ((authentication-service-audit-append! service)
             (authentication-service-connection service)
             (login-succeeded-event
              operator-id
              (operator-identity-role current-operator)
              (issued-operator-session-session-id issued)))
            (authentication-login-succeeded
             (issued-operator-session-access-token issued)
             (operator->principal current-operator)
             (issued-operator-session-session-id issued)
             (issued-operator-session-absolute-expires-at-epoch-ms issued))) ]
         [else (authentication-login-failed)]))))
  (cond
    [(authentication-credential-verification-failed? result)
     (append-auth-audit-best-effort! service (login-failed-event #f))
     (authentication-login-failed)]
    [(authentication-credential-verification-unavailable? result)
     (authentication-login-unavailable)]
    [else
     (when (authentication-login-failed? result)
       (append-auth-audit-best-effort! service (login-failed-event #f)))
     result]))

(define (authentication-service-authenticate service access-token)
  (unless (authentication-service? service)
    (raise-argument-error
     'authentication-service-authenticate "authentication-service?" service))
  (define store (authentication-service-session-store service))
  (define session (operator-session-store-find/observed store access-token))
  (cond
    [(operator-session-expiration? session)
     (append-auth-audit-best-effort!
      service
      (session-expired-event
       (operator-session-expiration-operator-id session)
       (operator-session-expiration-session-id session)
       (operator-session-expiration-reason session)))
     (authentication-session-invalid)]
    [(not session) (authentication-session-invalid)]
    [else
     (with-handlers ([exn:fail?
                      (lambda (_exception)
                        ;; A transient authoritative-state failure is not proof
                        ;; that this capability was revoked. Fail closed for the
                        ;; request but retain it for a later retry.
                        (authentication-session-unavailable))])
       (define connection (authentication-service-connection service))
       (define operator
         (load-operator connection (operator-session-operator-id session)))
       (define credential
         (and operator
              (load-operator-pin-record
               connection (operator-session-operator-id session))))
       (cond
         [(not (and operator
                    (operator-identity-active? operator)
                    credential
                    (= (operator-pin-record-credential-revision credential)
                       (operator-session-credential-revision session))))
         (operator-session-store-invalidate! store access-token)
          (append-auth-audit-best-effort!
           service
           (session-invalidated-event
            (operator-session-operator-id session)
            (operator-session-session-id session)
            (cond
              [(not operator) 'operator_missing]
              [(not (operator-identity-active? operator)) 'operator_disabled]
              [(not credential) 'credential_missing]
              [else 'credential_changed])))
          (authentication-session-invalid)]
         [else
          ;; Refresh only after authoritative security state is confirmed. A
          ;; concurrently replaced/expired register session cannot be revived.
          (define refreshed
            (operator-session-store-refresh! store access-token))
          (if refreshed
              (authentication-session-authenticated
               (operator->principal operator) refreshed)
              (authentication-session-invalid))]))]))

(define (authentication-service-logout service access-token)
  (define authenticated
    (authentication-service-authenticate service access-token))
  (cond
    [(authentication-session-authenticated? authenticated)
     (operator-session-store-invalidate!
      (authentication-service-session-store service) access-token)
     (define session
       (authentication-session-authenticated-session authenticated))
     (append-auth-audit-best-effort!
      service
      (logout-event
       (operator-session-operator-id session)
       (operator-session-session-id session)))
     (authentication-logout-succeeded)]
    [else authenticated]))
