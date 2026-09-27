#lang racket

(require (prefix-in db: db)
         file/sha1
         racket/random
         "../domain/operator-identity.rkt"
         "../domain/security-audit-event.rkt"
         "../security/authorization-policy.rkt"
         "security-audit-service.rkt"
         "../persistence/sqlite-operators.rkt"
         "../security/operator-pin.rkt")

(provide make-operator-service
         operator-service?
         operator-service-load
         operator-service-list
         operator-service-auth-status
         operator-service-create
         operator-service-set-role
         operator-service-set-active
         (struct-out operator-pin-enrollment-succeeded)
         (struct-out operator-pin-enrollment-rejected)
         (struct-out operator-pin-verification)
         (struct-out operator-pin-reset-succeeded)
         (struct-out operator-pin-reset-rejected)
         operator-service-enroll-pin
         operator-service-reset-pin
         operator-service-verify-pin)

(struct operator-service (connection hash-pin verify-pin-provider audit-append!)
  #:transparent)
(struct operator-pin-enrollment-succeeded (operator-id credential-revision)
  #:transparent)
(struct operator-pin-enrollment-rejected (code) #:transparent)
(struct operator-pin-verification (verified? code credential-revision)
  #:transparent)
(struct operator-pin-reset-succeeded (operator-id credential-revision)
  #:transparent)
(struct operator-pin-reset-rejected (code) #:transparent)

(define (check-provider who provider arity name)
  (unless (and (procedure? provider)
               (procedure-arity-includes? provider arity))
    (raise-arguments-error who "invalid credential provider" name provider)))

(define (make-operator-service
         connection
         #:hash-pin [hash-pin hash-operator-pin]
         #:verify-pin [verify-pin verify-operator-pin]
         #:audit-source [audit-source #f]
         #:audit-append! [audit-append! #f])
  (define who 'make-operator-service)
  (unless (db:connection? connection)
    (raise-argument-error who "connection?" connection))
  (check-provider who hash-pin 1 "hash-pin")
  (check-provider who verify-pin 2 "verify-pin")
  (define source
    (or audit-source
        (make-security-audit-source
         'root_cli
         (string-append "audit_root_cli_"
                        (bytes->hex-string (crypto-random-bytes 16)))
         (lambda ()
           (inexact->exact (floor (current-inexact-milliseconds)))))))
  (unless (security-audit-source? source)
    (raise-argument-error who "security-audit-source?" source))
  (define effective-audit-append!
    (or audit-append!
        (lambda (writer-connection event)
          (security-audit-append-required!/in-transaction!
           source writer-connection event))))
  (check-provider who effective-audit-append! 2 "audit-append!")
  (operator-service connection hash-pin verify-pin effective-audit-append!))

(define (check-service who service)
  (unless (operator-service? service)
    (raise-argument-error who "operator-service?" service)))

(define (operator-service-load service operator-id)
  (check-service 'operator-service-load service)
  (load-operator (operator-service-connection service) operator-id))

(define (operator-service-list service)
  (check-service 'operator-service-list service)
  (list-operators (operator-service-connection service)))

(define (operator-service-auth-status service)
  (check-service 'operator-service-auth-status service)
  (define connection (operator-service-connection service))
  (define operators (list-operators connection))
  (define active-cashier-ids
    (db:query-list connection
                   "SELECT cashier_id FROM cashiers WHERE active = 1"))
  (define (enrolled-active? operator)
    (and (operator-identity-active? operator)
         (eq? (operator-identity-credential-state operator) 'enrolled)))
  (define register-ready-count
    (count (lambda (operator)
             (and (enrolled-active? operator)
                  (member (operator-identity-operator-id operator)
                          active-cashier-ids)))
           operators))
  (define approval-ready-count
    (count (lambda (operator)
             (and (enrolled-active? operator)
                  (operator-role-authorized?
                   (operator-identity-role operator)
                   'approval.transaction_void)))
           operators))
  (hasheq
   'operator_count (length operators)
   'active_operator_count (count operator-identity-active? operators)
   'credential_enrolled_count
   (count (lambda (operator)
            (eq? (operator-identity-credential-state operator) 'enrolled))
          operators)
   'active_enrolled_operator_count (count enrolled-active? operators)
   'register_operator_ready_count register-ready-count
   'approval_operator_ready_count approval-ready-count
   'register_auth_ready (positive? register-ready-count)
   'approval_auth_ready (positive? approval-ready-count)
   'audit_event_count
   (db:query-value connection "SELECT COUNT(*) FROM security_audit_events")))

(define (operator-service-create service operator-id display-name role)
  (check-service 'operator-service-create service)
  (create-operator!
   (operator-service-connection service) operator-id display-name role
   #:audit-append! (operator-service-audit-append! service)))

(define (operator-service-set-role service operator-id role)
  (check-service 'operator-service-set-role service)
  (set-operator-role!
   (operator-service-connection service) operator-id role
   #:audit-append! (operator-service-audit-append! service)))

(define (operator-service-set-active service operator-id active?)
  (check-service 'operator-service-set-active service)
  (set-operator-active!
   (operator-service-connection service) operator-id active?
   #:audit-append! (operator-service-audit-append! service)))

(define (operator-service-enroll-pin service operator-id pin)
  (check-service 'operator-service-enroll-pin service)
  (define connection (operator-service-connection service))
  (cond
    [(not (operator-pin-valid? pin))
     (operator-pin-enrollment-rejected 'pin-policy-rejected)]
    [(not (load-operator connection operator-id))
     (operator-pin-enrollment-rejected 'operator-not-found)]
    [(load-operator-pin-record connection operator-id)
     (operator-pin-enrollment-rejected 'credential-already-enrolled)]
    [else
     ;; This intentionally happens before store-initial-operator-pin! enters
     ;; BEGIN IMMEDIATE. The transaction re-reads state and arbitrates races.
     (define password-hash
       ((operator-service-hash-pin service) pin))
     (define stored
       (store-initial-operator-pin!
        connection operator-id password-hash
        #:audit-append! (operator-service-audit-append! service)))
     (cond
       [(operator-pin-store-succeeded? stored)
        (operator-pin-enrollment-succeeded
         operator-id
         (operator-pin-store-succeeded-credential-revision stored))]
       [else
        (operator-pin-enrollment-rejected
         (operator-pin-store-rejected-code stored))])]))

(define (operator-service-verify-pin service operator-id pin)
  (check-service 'operator-service-verify-pin service)
  (define connection (operator-service-connection service))
  (define operator (load-operator connection operator-id))
  (cond
    [(not operator)
     (operator-pin-verification #f 'operator-not-found #f)]
    [(not (operator-identity-active? operator))
     (operator-pin-verification #f 'operator-inactive #f)]
    [else
     (define credential (load-operator-pin-record connection operator-id))
     (cond
       [(not credential)
        (operator-pin-verification #f 'credential-enrollment-required #f)]
       [else
        (define verified?
          ((operator-service-verify-pin-provider service)
           pin
           (operator-pin-record-password-hash credential)))
        (operator-pin-verification
         (and verified? #t)
         (if verified? 'verified 'invalid-credential)
         (operator-pin-record-credential-revision credential))])]))

(define (operator-service-reset-pin service operator-id new-pin)
  (check-service 'operator-service-reset-pin service)
  (define connection (operator-service-connection service))
  (cond
    [(not (operator-pin-valid? new-pin))
     (operator-pin-reset-rejected 'pin-policy-rejected)]
    [(not (load-operator connection operator-id))
     (operator-pin-reset-rejected 'operator-not-found)]
    [else
     (define credential (load-operator-pin-record connection operator-id))
     (if (not credential)
         (operator-pin-reset-rejected 'credential-enrollment-required)
         (let* ([new-hash ((operator-service-hash-pin service) new-pin)]
                [result
                 (rotate-operator-pin!
                  connection operator-id
                  (operator-pin-record-credential-revision credential)
                  new-hash
                  #:audit-event-maker operator-pin-reset-event
                  #:audit-append! (operator-service-audit-append! service))])
           (if (operator-pin-rotation-succeeded? result)
               (operator-pin-reset-succeeded
                operator-id
                (operator-pin-rotation-succeeded-credential-revision result))
               (operator-pin-reset-rejected
                (operator-pin-rotation-rejected-code result)))))]))
