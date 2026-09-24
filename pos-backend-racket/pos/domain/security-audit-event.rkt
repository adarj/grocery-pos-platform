#lang racket

;; Security evidence is deliberately a closed vocabulary.  Callers cannot
;; attach arbitrary request bodies or exception text to an audit event.
(provide security-audit-event?
         security-audit-event-type
         security-audit-event-fields
         runtime-started-event
         login-succeeded-event
         login-failed-event
         logout-event
         session-expired-event
         session-invalidated-event
         authorization-denied-event
         approval-granted-event
         approval-not-granted-event
         approval-required-event
         void-resolved-event
         shift-opened-event
         shift-closed-event
         operator-created-event
         operator-role-changed-event
         operator-active-changed-event
         operator-pin-enrolled-event
         audit-accessed-event)

(struct security-audit-event (type fields))

(define (event type fields)
  (security-audit-event type fields))

(define (runtime-started-event)
  (event 'runtime.started (hash)))

(define (login-succeeded-event operator-id role session-id)
  (event 'auth.login_succeeded
         (hash 'operator_id operator-id 'role role 'session_id session-id)))

(define (login-failed-event operator-id)
  (event 'auth.login_failed
         (hash 'operator_id (or operator-id 'null))))

(define (logout-event operator-id session-id)
  (event 'auth.logout (hash 'operator_id operator-id 'session_id session-id)))

(define (session-expired-event operator-id session-id reason)
  (event 'auth.session_expired
         (hash 'operator_id operator-id 'session_id session-id 'reason reason)))

(define (session-invalidated-event operator-id session-id reason)
  (event 'auth.session_invalidated
         (hash 'operator_id operator-id 'session_id session-id 'reason reason)))

(define (authorization-denied-event operator-id role session-id action
                                    resource-kind resource-id)
  (event 'authorization.denied
         (hash 'operator_id operator-id 'role role
               'session_id (or session-id 'null)
               'action action 'resource_kind resource-kind
               'resource_id (or resource-id 'null))))

(define (approval-granted-event approval-id requester-id approver-id
                                command-id transaction-id expected-version
                                expires-at-epoch-ms)
  (event 'approval.granted
         (hash 'approval_id approval-id 'requester_operator_id requester-id
               'approver_operator_id approver-id 'command_id command-id
               'transaction_id transaction-id 'expected_version expected-version
               'expires_at_epoch_ms expires-at-epoch-ms)))

(define (approval-not-granted-event requester-id command-id transaction-id
                                    [verified-approver-id #f])
  (event 'approval.not_granted
         (hash 'requester_operator_id requester-id 'command_id command-id
               'transaction_id transaction-id
               'verified_approver_operator_id (or verified-approver-id 'null))))

(define (approval-required-event requester-id command-id transaction-id)
  (event 'approval.required
         (hash 'requester_operator_id requester-id 'command_id command-id
               'transaction_id transaction-id)))

(define (void-resolved-event requester-id approver-id approval-id command-id
                             transaction-id outcome-kind outcome-code)
  (event 'transaction.void_resolved
         (hash 'requester_operator_id requester-id
               'approver_operator_id approver-id 'approval_id approval-id
               'command_id command-id 'transaction_id transaction-id
               'outcome_kind outcome-kind 'outcome_code outcome-code)))

(define (shift-opened-event operator-id shift-id)
  (event 'shift.opened (hash 'operator_id operator-id 'shift_id shift-id)))

(define (shift-closed-event operator-id owner-id shift-id foreign?)
  (event 'shift.closed
         (hash 'operator_id operator-id 'owner_operator_id owner-id
               'shift_id shift-id 'foreign_manager_close foreign?)))

(define (operator-created-event operator-id role)
  (event 'operator.created (hash 'operator_id operator-id 'role role)))

(define (operator-role-changed-event operator-id previous-role new-role)
  (event 'operator.role_changed
         (hash 'operator_id operator-id 'previous_role previous-role
               'new_role new-role)))

(define (operator-active-changed-event operator-id previous-active new-active)
  (event 'operator.active_changed
         (hash 'operator_id operator-id 'previous_active previous-active
               'new_active new-active)))

(define (operator-pin-enrolled-event operator-id credential-revision)
  (event 'operator.pin_enrolled
         (hash 'operator_id operator-id
               'credential_revision credential-revision)))

(define (audit-accessed-event operation after-sequence limit)
  (event 'audit.accessed
         (hash 'operation operation 'after_sequence after-sequence
               'limit limit)))
