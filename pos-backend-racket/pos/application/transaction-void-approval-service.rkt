#lang racket

(require file/sha1
         racket/random
         "authentication-service.rkt"
         "security-audit-service.rkt"
         "transaction-command.rkt"
         "transaction-service.rkt"
         "../domain/operator-identity.rkt"
         "../domain/security-audit-event.rkt"
         "../domain/transaction-void-approval.rkt"
         "../persistence/sqlite-authentication.rkt"
         "../persistence/transaction-void-approval-store.rkt"
         "../security/authorization-policy.rkt"
         "../security/transaction-void-approval.rkt")

(provide make-transaction-void-approval-service
         transaction-void-approval-service?
         (struct-out transaction-void-approval-granted)
         (struct-out transaction-void-approval-not-granted)
         (struct-out transaction-void-approval-request-denied)
         (struct-out transaction-void-approval-target-stale)
         (struct-out transaction-void-approval-unavailable)
         transaction-void-approval-service-request)

(struct transaction-void-approval-service
  (authentication-service transaction-service authority audit-source audit-append!))

(struct transaction-void-approval-granted
  (approval-token expires-at-epoch-ms approver-operator-id
                  approver-display-name))
(struct transaction-void-approval-not-granted () #:transparent)
(struct transaction-void-approval-request-denied () #:transparent)
(struct transaction-void-approval-target-stale () #:transparent)
(struct transaction-void-approval-unavailable () #:transparent)

(define (make-transaction-void-approval-service
         authentication-service transaction-service authority
         #:audit-source [audit-source #f]
         #:audit-append! [audit-append! #f])
  (unless (authentication-service? authentication-service)
    (raise-argument-error
     'make-transaction-void-approval-service
     "authentication-service?"
     authentication-service))
  (unless (transaction-service? transaction-service)
    (raise-argument-error
     'make-transaction-void-approval-service
     "transaction-service?"
     transaction-service))
  (unless (transaction-void-approval-authority? authority)
    (raise-argument-error
     'make-transaction-void-approval-service
     "transaction-void-approval-authority?"
     authority))
  (define source
    (or audit-source
        (make-security-audit-source
         'pos_core
         (string-append "audit_runtime_"
                        (bytes->hex-string (crypto-random-bytes 16)))
         (lambda ()
           (inexact->exact (floor (current-inexact-milliseconds)))))))
  (unless (security-audit-source? source)
    (raise-argument-error 'make-transaction-void-approval-service
                          "security-audit-source?" source))
  (define effective-append!
    (or audit-append!
        (lambda (writer-connection event)
          (security-audit-append-required!/in-transaction!
           source writer-connection event))))
  (unless (and (procedure? effective-append!)
               (procedure-arity-includes? effective-append! 2))
    (raise-argument-error 'make-transaction-void-approval-service
                          "two-argument audit append procedure?"
                          effective-append!))
  (transaction-void-approval-service
   authentication-service transaction-service authority source effective-append!))

(define (requester-may-approve-target? service requester command)
  (cond
    [(not (operator-role-authorized?
           (authenticated-operator-role requester)
           'transaction.operate.own))
     (transaction-void-approval-request-denied)]
    [else
     (define target
       (transaction-service-load-transaction
        (transaction-void-approval-service-transaction-service service)
        requester
        (transaction-command-transaction-id command)))
     (cond
       [(transaction-service-success? target)
        (cond
          [(not
            (transaction-service-success-owned-by-principal? target requester))
           (transaction-void-approval-request-denied)]
          [(not (= (transaction-service-success-version target)
                   (transaction-command-expected-version command)))
           (transaction-void-approval-target-stale)]
          [else #t])]
       [(transaction-service-recovery-failed? target)
        (transaction-void-approval-unavailable)]
       [else (transaction-void-approval-target-stale)])]))

(define (confirm-valid-but-ineligible-credential!
         authentication-service operator-id password-hash revision)
  ;; This re-read both closes the credential race and applies the normal
  ;; successful-authentication throttle clearing rule. It creates no session.
  (define confirmed
    (confirm-operator-login!
     (authentication-service-connection authentication-service)
     operator-id
     password-hash
     revision))
  (if (operator-login-confirmed? confirmed)
      (transaction-void-approval-not-granted)
      (transaction-void-approval-not-granted)))

(define (issue-grant-after-verification
         service requester command approver password-hash credential-revision)
  (define authentication-service
    (transaction-void-approval-service-authentication-service service))
  (define requester-id (authenticated-operator-operator-id requester))
  (define approver-id (operator-identity-operator-id approver))
  (cond
    [(or (string=? requester-id approver-id)
         (not (operator-role-authorized?
               (operator-identity-role approver)
               'approval.transaction_void)))
     (confirm-valid-but-ineligible-credential!
      authentication-service approver-id password-hash credential-revision)]
    [else
     (define authority
       (transaction-void-approval-service-authority service))
     (define issued (transaction-void-approval-authority-issue authority))
     (define grant
       (transaction-void-approval-grant
        (issued-transaction-void-approval-approval-id issued)
        (transaction-void-approval-capability-token-digest
         (issued-transaction-void-approval-capability issued))
        (transaction-void-approval-authority-issuer-instance-id authority)
        requester-id
        (authenticated-operator-credential-revision requester)
        approver-id
        credential-revision
        (transaction-command-command-id command)
        (transaction-command-transaction-id command)
        1
        (transaction-command-expected-version command)
        (issued-transaction-void-approval-granted-at-monotonic-ms issued)
        (issued-transaction-void-approval-expires-at-monotonic-ms issued)
        (issued-transaction-void-approval-expires-at-epoch-ms issued)))
     (define stored
       (confirm-and-replace-transaction-void-approval-grant!
        (authentication-service-connection authentication-service)
        grant
        password-hash
        (transaction-void-approval-authority-issuer-instance-id authority)
        (issued-transaction-void-approval-granted-at-monotonic-ms issued)
        #:audit-append!
        (transaction-void-approval-service-audit-append! service)))
     (if (transaction-void-approval-grant-stored? stored)
         (transaction-void-approval-granted
          (issued-transaction-void-approval-token issued)
          (issued-transaction-void-approval-expires-at-epoch-ms issued)
          approver-id
          (operator-identity-display-name approver))
         (transaction-void-approval-not-granted))]))

(define (transaction-void-approval-service-request
         service requester command approver-operator-id approver-pin)
  (define who 'transaction-void-approval-service-request)
  (unless (transaction-void-approval-service? service)
    (raise-argument-error who "transaction-void-approval-service?" service))
  (unless (authenticated-operator? requester)
    (raise-argument-error who "authenticated-operator?" requester))
  (unless (void-transaction-command? command)
    (raise-argument-error who "void-transaction-command?" command))
  (define requester-check
    (requester-may-approve-target? service requester command))
  (cond
    [(not (eq? requester-check #t)) requester-check]
    [else
     (define authentication-service
       (transaction-void-approval-service-authentication-service service))
     (define result
       (authentication-service-with-verified-credential
        authentication-service
        approver-operator-id
        approver-pin
        (lambda (approver password-hash credential-revision)
          (issue-grant-after-verification
           service requester command approver password-hash credential-revision))))
     (define public-result
       (cond
         [(authentication-credential-verification-failed? result)
          (transaction-void-approval-not-granted)]
         [(authentication-credential-verification-unavailable? result)
          (transaction-void-approval-unavailable)]
         [else result]))
     (when (transaction-void-approval-not-granted? public-result)
       (security-audit-append-best-effort!
        (transaction-void-approval-service-audit-source service)
        (authentication-service-connection authentication-service)
        (approval-not-granted-event
         (authenticated-operator-operator-id requester)
         (transaction-command-command-id command)
         (transaction-command-transaction-id command))))
     public-result]))
