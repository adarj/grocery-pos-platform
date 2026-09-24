#lang racket

(require (prefix-in db: db)
         "../application/transaction-command.rkt"
         "../domain/security-audit-event.rkt"
         "../domain/transaction-void-approval.rkt"
         "sqlite-auth-throttle.rkt"
         "../security/authorization-policy.rkt"
         "../security/transaction-void-approval.rkt")

(provide replace-transaction-void-approval-grant!/in-transaction!
         (struct-out transaction-void-approval-grant-stored)
         (struct-out transaction-void-approval-grant-not-stored)
         confirm-and-replace-transaction-void-approval-grant!
         revoke-transaction-void-approval-grants-for-operator!/in-transaction!
         (struct-out transaction-void-approval-consumed)
         (struct-out transaction-void-approval-rejected)
         consume-transaction-void-approval!/in-transaction!
         insert-transaction-command-approver-attribution!
         load-transaction-command-approver-attribution
         transaction-command-receipt-legacy-unapproved-void?)

(struct transaction-void-approval-consumed (attribution) #:transparent)
(struct transaction-void-approval-rejected () #:transparent)
(struct transaction-void-approval-grant-stored () #:transparent)
(struct transaction-void-approval-grant-not-stored () #:transparent)

(define (check-connection who connection)
  (unless (db:connection? connection)
    (raise-argument-error who "connection?" connection)))

(define (require-writer-transaction who connection)
  (check-connection who connection)
  (unless (db:in-transaction? connection)
    (raise-arguments-error
     who "operation requires an existing writer transaction" "connection" connection)))

(define (replace-transaction-void-approval-grant!/in-transaction!
         connection grant current-issuer-instance-id monotonic-now)
  (define who 'replace-transaction-void-approval-grant!/in-transaction!)
  (require-writer-transaction who connection)
  (unless (transaction-void-approval-grant? grant)
    (raise-argument-error who "transaction-void-approval-grant?" grant))
  (unless (and (string? current-issuer-instance-id)
               (positive? (string-length current-issuer-instance-id)))
    (raise-argument-error who "non-empty-string?" current-issuer-instance-id))
  (unless (and (exact-integer? monotonic-now) (>= monotonic-now 0))
    (raise-argument-error who "exact-nonnegative-integer?" monotonic-now))
  ;; Values from an older process use an unrelated monotonic epoch and are
  ;; safely discarded. Current-process expirations are also opportunistically
  ;; pruned; neither case can resurrect a capability.
  (db:query-exec
   connection
   #<<SQL
DELETE FROM transaction_void_approval_grants
WHERE issuer_instance_id <> ?
   OR (issuer_instance_id = ? AND expires_at_monotonic_ms <= ?)
SQL
   current-issuer-instance-id current-issuer-instance-id monotonic-now)
  (define existing-scope
    (db:query-maybe-row
     connection
     #<<SQL
SELECT requester_operator_id, requester_credential_revision,
       transaction_id, command_schema_version,
       expected_version
FROM transaction_void_approval_grants
WHERE command_id = ?
SQL
     (transaction-void-approval-grant-command-id grant)))
  ;; A lost response may be replaced only by another approval for the same
  ;; exact void command. A reused command ID cannot silently change purpose.
  (if (and existing-scope
           (not (equal?
                 existing-scope
                 (vector
                  (transaction-void-approval-grant-requester-operator-id grant)
                  (transaction-void-approval-grant-requester-credential-revision grant)
                  (transaction-void-approval-grant-transaction-id grant)
                  (transaction-void-approval-grant-command-schema-version grant)
                  (transaction-void-approval-grant-expected-version grant)))))
      #f
      (begin
        (db:query-exec
         connection
         "DELETE FROM transaction_void_approval_grants WHERE command_id = ?"
         (transaction-void-approval-grant-command-id grant))
        (db:query-exec
         connection
         #<<SQL
INSERT INTO transaction_void_approval_grants
  (approval_id, token_digest, issuer_instance_id, requester_operator_id,
   requester_credential_revision, approver_operator_id,
   approver_credential_revision, command_id,
   transaction_id, command_schema_version, expected_version,
   granted_at_monotonic_ms, expires_at_monotonic_ms, expires_at_epoch_ms)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
SQL
         (transaction-void-approval-grant-approval-id grant)
         (transaction-void-approval-grant-token-digest grant)
         (transaction-void-approval-grant-issuer-instance-id grant)
         (transaction-void-approval-grant-requester-operator-id grant)
         (transaction-void-approval-grant-requester-credential-revision grant)
         (transaction-void-approval-grant-approver-operator-id grant)
         (transaction-void-approval-grant-approver-credential-revision grant)
         (transaction-void-approval-grant-command-id grant)
         (transaction-void-approval-grant-transaction-id grant)
         (transaction-void-approval-grant-command-schema-version grant)
         (transaction-void-approval-grant-expected-version grant)
         (transaction-void-approval-grant-granted-at-monotonic-ms grant)
         (transaction-void-approval-grant-expires-at-monotonic-ms grant)
         (transaction-void-approval-grant-expires-at-epoch-ms grant))
        #t)))

;; Argon2 verification has already completed before this function is called.
;; This short writer boundary confirms that the exact credential remains
;; current, clears the shared durable throttle after successful credential
;; authentication, rechecks approval privilege, and replaces the scoped grant.
(define (confirm-and-replace-transaction-void-approval-grant!
         connection grant expected-password-hash issuer-instance-id monotonic-now
         #:audit-append! audit-append!)
  (define who 'confirm-and-replace-transaction-void-approval-grant!)
  (check-connection who connection)
  (unless (transaction-void-approval-grant? grant)
    (raise-argument-error who "transaction-void-approval-grant?" grant))
  (unless (and (string? expected-password-hash)
               (positive? (string-length expected-password-hash)))
    (raise-argument-error who "non-empty-string?" expected-password-hash))
  (db:call-with-transaction
   connection
   (lambda ()
     (define row
       (db:query-maybe-row
        connection
        #<<SQL
SELECT assignment.role, credential.credential_revision
FROM operators AS operator
JOIN operator_roles AS assignment
  ON assignment.operator_id = operator.operator_id
JOIN operator_pin_credentials AS credential
  ON credential.operator_id = operator.operator_id
WHERE operator.operator_id = ?
  AND operator.active = 1
  AND credential.password_hash = ?
  AND credential.credential_revision = ?
SQL
        (transaction-void-approval-grant-approver-operator-id grant)
        expected-password-hash
        (transaction-void-approval-grant-approver-credential-revision grant)))
     (cond
       [(not (and row
                  (requester-still-authorized?
                   connection
                   (transaction-void-approval-grant-requester-operator-id grant)
                   (transaction-void-approval-grant-requester-credential-revision grant))))
        (transaction-void-approval-grant-not-stored)]
       [else
        ;; Correct current credentials clear the normal login throttle even if
        ;; a concurrent role change makes this particular approval ineligible.
        (clear-operator-login-throttle!
         connection
         (transaction-void-approval-grant-approver-operator-id grant))
        (if (operator-role-authorized?
             (string->symbol (vector-ref row 0))
             'approval.transaction_void)
            (if (replace-transaction-void-approval-grant!/in-transaction!
                 connection grant issuer-instance-id monotonic-now)
                (begin
                  (audit-append!
                   connection
                   (approval-granted-event
                    (transaction-void-approval-grant-approval-id grant)
                    (transaction-void-approval-grant-requester-operator-id grant)
                    (transaction-void-approval-grant-approver-operator-id grant)
                    (transaction-void-approval-grant-command-id grant)
                    (transaction-void-approval-grant-transaction-id grant)
                    (transaction-void-approval-grant-expected-version grant)
                    (transaction-void-approval-grant-expires-at-epoch-ms grant)))
                  (transaction-void-approval-grant-stored))
                (transaction-void-approval-grant-not-stored))
            (transaction-void-approval-grant-not-stored))]))
   #:option 'immediate))

(define (row->grant row)
  (and row
       (apply transaction-void-approval-grant (vector->list row))))

(define (load-grant-by-digest connection token-digest)
  (row->grant
   (db:query-maybe-row
    connection
    #<<SQL
SELECT approval_id, token_digest, issuer_instance_id, requester_operator_id,
       requester_credential_revision,
       approver_operator_id, approver_credential_revision, command_id,
       transaction_id, command_schema_version, expected_version,
       granted_at_monotonic_ms, expires_at_monotonic_ms, expires_at_epoch_ms
FROM transaction_void_approval_grants
WHERE token_digest = ?
SQL
    token-digest)))

(define (grant-matches-command? grant issuer-instance-id requester-operator-id
                                requester-credential-revision command monotonic-now)
  (and
   (string=? (transaction-void-approval-grant-issuer-instance-id grant)
             issuer-instance-id)
   (string=? (transaction-void-approval-grant-requester-operator-id grant)
             requester-operator-id)
   (= (transaction-void-approval-grant-requester-credential-revision grant)
      requester-credential-revision)
   (not (string=? requester-operator-id
                  (transaction-void-approval-grant-approver-operator-id grant)))
   (void-transaction-command? command)
   (string=? (transaction-void-approval-grant-command-id grant)
             (transaction-command-command-id command))
   (string=? (transaction-void-approval-grant-transaction-id grant)
             (transaction-command-transaction-id command))
   (= (transaction-void-approval-grant-command-schema-version grant) 1)
   (= (transaction-void-approval-grant-expected-version grant)
      (transaction-command-expected-version command))
   (< monotonic-now
      (transaction-void-approval-grant-expires-at-monotonic-ms grant))))

(define (approver-still-authorized? connection grant)
  (define row
    (db:query-maybe-row
     connection
     #<<SQL
SELECT assignment.role, credential.credential_revision
FROM operators AS operator
JOIN operator_roles AS assignment
  ON assignment.operator_id = operator.operator_id
JOIN operator_pin_credentials AS credential
  ON credential.operator_id = operator.operator_id
WHERE operator.operator_id = ?
  AND operator.active = 1
SQL
     (transaction-void-approval-grant-approver-operator-id grant)))
  (and row
       (= (vector-ref row 1)
          (transaction-void-approval-grant-approver-credential-revision grant))
       (operator-role-authorized?
        (string->symbol (vector-ref row 0))
        'approval.transaction_void)))

(define (requester-still-authorized? connection requester-operator-id
                                     requester-credential-revision)
  (define row
    (db:query-maybe-row
     connection
     #<<SQL
SELECT assignment.role, credential.credential_revision
FROM operators AS operator
JOIN operator_roles AS assignment
  ON assignment.operator_id = operator.operator_id
JOIN operator_pin_credentials AS credential
  ON credential.operator_id = operator.operator_id
WHERE operator.operator_id = ?
  AND operator.active = 1
SQL
     requester-operator-id))
  (and row
       (= (vector-ref row 1) requester-credential-revision)
       (operator-role-authorized?
        (string->symbol (vector-ref row 0))
        'transaction.operate.own)))

(define (consume-transaction-void-approval!/in-transaction!
         connection capability issuer-instance-id requester-operator-id
         requester-credential-revision command monotonic-now)
  (define who 'consume-transaction-void-approval!/in-transaction!)
  (require-writer-transaction who connection)
  (unless (transaction-void-approval-capability? capability)
    (raise-argument-error who "transaction-void-approval-capability?" capability))
  (unless (void-transaction-command? command)
    (raise-argument-error who "void-transaction-command?" command))
  (unless (and (exact-integer? monotonic-now) (>= monotonic-now 0))
    (raise-argument-error who "exact-nonnegative-integer?" monotonic-now))
  (define grant
    (load-grant-by-digest
     connection
     (transaction-void-approval-capability-token-digest capability)))
  (cond
    [(not (and grant
               (grant-matches-command?
                grant issuer-instance-id requester-operator-id
                requester-credential-revision command monotonic-now)
               (requester-still-authorized?
                connection requester-operator-id requester-credential-revision)
               (approver-still-authorized? connection grant)
               (>= (transaction-void-approval-grant-expires-at-epoch-ms grant)
                   transaction-void-approval-lifetime-ms)))
     (transaction-void-approval-rejected)]
    [else
     (db:query-exec
      connection
      "DELETE FROM transaction_void_approval_grants WHERE approval_id = ? AND token_digest = ?"
      (transaction-void-approval-grant-approval-id grant)
      (transaction-void-approval-grant-token-digest grant))
     (if (= (db:query-value connection "SELECT changes()") 1)
         (transaction-void-approval-consumed
          (transaction-command-approver-attribution
           (transaction-command-command-id command)
           (transaction-void-approval-grant-approval-id grant)
           (transaction-void-approval-grant-approver-operator-id grant)
           (transaction-void-approval-grant-approver-credential-revision grant)
           (- (transaction-void-approval-grant-expires-at-epoch-ms grant)
              transaction-void-approval-lifetime-ms)))
         (transaction-void-approval-rejected))]))

(define (revoke-transaction-void-approval-grants-for-operator!/in-transaction!
         connection operator-id)
  (define who 'revoke-transaction-void-approval-grants-for-operator!/in-transaction!)
  (require-writer-transaction who connection)
  (unless (and (string? operator-id) (positive? (string-length operator-id)))
    (raise-argument-error who "non-empty-string?" operator-id))
  (db:query-exec
   connection
   #<<SQL
DELETE FROM transaction_void_approval_grants
WHERE requester_operator_id = ? OR approver_operator_id = ?
SQL
   operator-id operator-id)
  (void))

(define (insert-transaction-command-approver-attribution!
         connection attribution)
  (check-connection 'insert-transaction-command-approver-attribution! connection)
  (unless (transaction-command-approver-attribution? attribution)
    (raise-argument-error
     'insert-transaction-command-approver-attribution!
     "transaction-command-approver-attribution?"
     attribution))
  (db:query-exec
   connection
   #<<SQL
INSERT INTO transaction_command_approver_attributions
  (command_id, approval_id, approver_operator_id,
   approver_credential_revision, approved_at_epoch_ms)
VALUES (?, ?, ?, ?, ?)
SQL
   (transaction-command-approver-attribution-command-id attribution)
   (transaction-command-approver-attribution-approval-id attribution)
   (transaction-command-approver-attribution-approver-operator-id attribution)
   (transaction-command-approver-attribution-approver-credential-revision attribution)
   (transaction-command-approver-attribution-approved-at-epoch-ms attribution))
  (void))

(define (load-transaction-command-approver-attribution connection command-id)
  (check-connection 'load-transaction-command-approver-attribution connection)
  (define row
    (db:query-maybe-row
     connection
     #<<SQL
SELECT command_id, approval_id, approver_operator_id,
       approver_credential_revision, approved_at_epoch_ms
FROM transaction_command_approver_attributions
WHERE command_id = ?
SQL
     command-id))
  (and row
       (apply transaction-command-approver-attribution
              (vector->list row))))

(define (transaction-command-receipt-legacy-unapproved-void?
         connection command-id)
  (check-connection
   'transaction-command-receipt-legacy-unapproved-void? connection)
  (= 1
     (db:query-value
      connection
      #<<SQL
SELECT COUNT(*)
FROM transaction_command_legacy_unapproved_void_receipts
WHERE command_id = ?
SQL
      command-id)))
