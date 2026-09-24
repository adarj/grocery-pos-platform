#lang racket

(require json
         racket/string
         "../domain/security-audit-event.rkt"
         "strict-json.rkt")

(provide security-audit-event->json
         decode-security-audit-event-json
         supported-security-audit-event-type?)

;; Each event owns an exact, flat JSON shape.  Optional identity evidence is
;; represented by JSON null, never by adding arbitrary fields.
(define schemas
  (hash
   'runtime.started '()
   'auth.login_succeeded '((operator_id . id) (role . role) (session_id . id))
   'auth.login_failed '((operator_id . nullable-id))
   'auth.logout '((operator_id . id) (session_id . id))
   'auth.session_expired '((operator_id . id) (session_id . id)
                           (reason . expiry-reason))
   'auth.session_invalidated '((operator_id . id) (session_id . id)
                               (reason . invalidation-reason))
   'authorization.denied '((operator_id . id) (role . role) (session_id . nullable-id)
                            (action . action) (resource_kind . resource-kind)
                            (resource_id . nullable-id))
   'approval.granted '((approval_id . id) (requester_operator_id . id)
                        (approver_operator_id . id) (command_id . id)
                        (transaction_id . id) (expected_version . nonnegative)
                        (expires_at_epoch_ms . nonnegative))
   'approval.not_granted '((requester_operator_id . id) (command_id . id)
                            (transaction_id . id)
                            (verified_approver_operator_id . nullable-id))
   'approval.required '((requester_operator_id . id) (command_id . id)
                         (transaction_id . id))
   'transaction.void_resolved '((requester_operator_id . id)
                                (approver_operator_id . id) (approval_id . id)
                                (command_id . id) (transaction_id . id)
                                (outcome_kind . outcome-kind)
                                (outcome_code . outcome-code))
   'shift.opened '((operator_id . id) (shift_id . id))
   'shift.closed '((operator_id . id) (owner_operator_id . id)
                   (shift_id . id) (foreign_manager_close . boolean))
   'operator.created '((operator_id . id) (role . role))
   'operator.role_changed '((operator_id . id) (previous_role . role)
                            (new_role . role))
   'operator.active_changed '((operator_id . id) (previous_active . boolean)
                              (new_active . boolean))
   'operator.pin_enrolled '((operator_id . id)
                            (credential_revision . positive))
   'audit.accessed '((operation . audit-operation)
                     (after_sequence . nonnegative) (limit . positive))))

(define (supported-security-audit-event-type? value)
  (and (symbol? value) (hash-has-key? schemas value)))

(define (normalized-value value)
  (cond
    [(eq? value 'null) 'null]
    [(symbol? value) (symbol->string value)]
    [else value]))

(define (one-of? value choices)
  (member (normalized-value value) choices))

(define (valid-field? kind value)
  (case kind
    [(id) (and (string? value) (positive? (string-length value)))]
    [(nullable-id) (or (eq? value 'null) (valid-field? 'id value))]
    [(nonnegative) (and (exact-integer? value) (>= value 0))]
    [(positive) (and (exact-integer? value) (> value 0))]
    [(boolean) (boolean? value)]
    [(role) (one-of? value '("cashier" "supervisor" "manager"))]
    [(expiry-reason) (one-of? value '("idle_timeout" "absolute_timeout"))]
    [(invalidation-reason)
     (one-of? value '("operator_disabled" "credential_changed"
                       "operator_missing" "credential_missing"))]
    [(action)
     (one-of? value
              '("register.read" "cashier_directory.read"
                "transaction.read.own" "transaction.read.any"
                "transaction.operate.own" "receipt.read.own"
                "receipt.read.any" "shift.open.own" "shift.close.own"
                "shift.close.any" "shift.cash_summary.read.own"
                "shift.cash_summary.read.any" "approval.transaction_void"
                "transaction.command.retry"))]
    [(resource-kind)
     (one-of? value '("register" "cashier_directory" "transaction"
                       "receipt" "shift" "transaction_command"))]
    [(outcome-kind)
     (one-of? value '("accepted" "domain_rejected" "not_found"
                       "already_exists" "version_conflict"))]
    [(outcome-code)
     (one-of? value '("accepted" "invalid_transaction_state"
                       "empty_transaction" "insufficient_tender"
                       "line_item_not_found" "unknown_barcode"
                       "transaction_not_found" "transaction_already_exists"
                       "invalid_expected_version" "stale_expected_version"
                       "stream_version_conflict" "register_not_configured"
                       "shift_required" "shift_has_active_transaction"))]
    [(audit-operation) (one-of? value '("list" "verify"))]
    [else #f]))

(define (validate-event! who type fields)
  (define schema (hash-ref schemas type #f))
  (unless schema
    (error who "unsupported security audit event type"))
  (unless (and (hash? fields)
               (= (hash-count fields) (length schema))
               (for/and ([entry (in-list schema)])
                 (define key (car entry))
                 (and (hash-has-key? fields key)
                      (valid-field? (cdr entry) (hash-ref fields key)))))
    (error who "invalid security audit event shape"))
  schema)

(define (security-audit-event->json event)
  (unless (security-audit-event? event)
    (raise-argument-error 'security-audit-event->json
                          "security-audit-event?" event))
  (define fields (security-audit-event-fields event))
  (define schema
    (validate-event! 'security-audit-event->json
                     (security-audit-event-type event) fields))
  ;; Generate a stable field order independent of hash-table iteration order.
  (string-append
   "{"
   (string-join
    (for/list ([entry (in-list schema)])
      (define key (car entry))
      (string-append (jsexpr->string (symbol->string key)) ":"
                     (jsexpr->string (normalized-value (hash-ref fields key)))))
    ",")
   "}"))

(define (decode-security-audit-event-json type text)
  (unless (supported-security-audit-event-type? type)
    (error 'decode-security-audit-event-json "unsupported security audit event type"))
  (define parsed (strict-json-string->jsexpr text))
  (unless (strict-json-success? parsed)
    (error 'decode-security-audit-event-json "malformed security audit JSON"))
  (define fields (strict-json-success-value parsed))
  (validate-event! 'decode-security-audit-event-json type fields)
  fields)
