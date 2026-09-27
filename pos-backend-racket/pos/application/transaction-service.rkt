#lang racket

(require (prefix-in db: db)
         file/sha1
         racket/random
         "authentication-service.rkt"
         "security-audit-service.rkt"
         "transaction-command-receipt.rkt"
         "transaction-command.rkt"
         "../domain/canonical-receipt.rkt"
         "../domain/register-operations.rkt"
         "../domain/security-audit-event.rkt"
         "../domain/transaction-command-actor-attribution.rkt"
         "../domain/transaction.rkt"
         (prefix-in op: "../domain/transaction-operational-context.rkt")
         "../persistence/sqlite-register-operations.rkt"
         "../persistence/sqlite-shift-cash-accountability.rkt"
         "../persistence/sqlite-transaction-event-store.rkt"
         "../persistence/transaction-command-actor-attribution-store.rkt"
         "../persistence/transaction-command-receipt-store.rkt"
         "../persistence/transaction-command-unit-of-work.rkt"
         "../persistence/transaction-void-approval-store.rkt"
         "../security/authorization-policy.rkt"
         "../security/transaction-void-approval.rkt")

(provide make-transaction-service
         transaction-service?
         transaction-service-load-transaction
         transaction-service-load-canonical-receipt
         transaction-service-execute-command
         transaction-service-success?
         transaction-service-success-transaction
         transaction-service-success-version
         transaction-service-success-owned-by-principal?
         transaction-service-not-found?
         transaction-service-not-found-transaction-id
         transaction-service-recovery-failed?
         transaction-service-recovery-failed-transaction-id
         transaction-service-recovery-failed-stage
         transaction-service-recovery-failed-code
         transaction-service-recovery-failed-position
         transaction-service-recovery-failed-detail
         transaction-service-recovery-failed-message
         transaction-service-receipt-success?
         transaction-service-receipt-success-receipt
         transaction-service-receipt-not-found?
         transaction-service-receipt-not-found-transaction-id
         transaction-service-receipt-not-available?
         transaction-service-receipt-not-available-transaction-id
         transaction-service-receipt-not-available-reason
         transaction-service-command-resolved?
         transaction-service-command-resolved-receipt
         transaction-service-command-id-reused?
         transaction-service-command-id-reused-command-id
         transaction-service-authorization-denied?
         transaction-service-approval-required?
         transaction-service-command-persistence-failed?
         transaction-service-command-persistence-failed-command-id
         transaction-service-command-persistence-failed-code
         transaction-service-command-persistence-failed-detail
         transaction-service-command-persistence-failed-message)

(struct transaction-service
  (connection
   catalog-lookup
   load-events
   load-receipt
   load-attribution
   legacy-unattributed?
   load-approver-attribution
   legacy-unapproved-void?
   approval-consumer
   commit-command!
   current-epoch-ms
   audit-source))

;; Query results expose authoritative reconstructed transaction state.
(struct transaction-service-success (transaction version)
  #:transparent)

(struct transaction-service-not-found (transaction-id)
  #:transparent)

(struct transaction-service-recovery-failed
  (transaction-id stage code position detail message)
  #:transparent)

;; Receipt reads remain distinct from transaction snapshots because their
;; eligibility and wire model are narrower, while recovery failures retain the
;; same journal/replay result used by the authoritative transaction query.
(struct transaction-service-receipt-success (receipt)
  #:transparent)

(struct transaction-service-receipt-not-found (transaction-id)
  #:transparent)

(struct transaction-service-receipt-not-available (transaction-id reason)
  #:transparent)

;; Mutation results expose only the durable command outcome. In particular, a
;; resolved result does not reveal whether it was newly committed or recovered
;; for an identical retry.
(struct transaction-service-command-resolved (receipt)
  #:transparent)

(struct transaction-service-command-id-reused (command-id)
  #:transparent)

(struct transaction-service-authorization-denied ()
  #:transparent)

(struct transaction-service-approval-required ()
  #:transparent)

(struct transaction-service-command-persistence-failed
  (command-id code detail message)
  #:transparent)

(define (check-procedure who value argument-name)
  (unless (procedure? value)
    (raise-arguments-error
     who
     "expected a procedure"
     argument-name
     value)))

(define (make-transaction-service
         connection
         #:catalog-lookup catalog-lookup
         #:load-events [load-events load-transaction-events]
         #:load-receipt
         [load-receipt load-transaction-command-receipt]
         #:load-attribution
         [load-attribution load-transaction-command-actor-attribution]
         #:legacy-unattributed?
         [legacy-unattributed?
          transaction-command-receipt-legacy-unattributed?]
         #:load-approver-attribution
         [load-approver-attribution
          load-transaction-command-approver-attribution]
         #:legacy-unapproved-void?
         [legacy-unapproved-void?
          transaction-command-receipt-legacy-unapproved-void?]
         #:approval-consumer [approval-consumer #f]
         #:commit-command!
         [commit-command! commit-transaction-command-outcome!]
         #:current-epoch-ms [current-epoch-ms #f]
         #:audit-source [audit-source #f])
  (define who 'make-transaction-service)
  (unless (db:connection? connection)
    (raise-argument-error who "connection?" connection))
  (check-procedure who catalog-lookup "catalog-lookup")
  (check-procedure who load-events "load-events")
  (check-procedure who load-receipt "load-receipt")
  (check-procedure who load-attribution "load-attribution")
  (check-procedure who legacy-unattributed? "legacy-unattributed?")
  (check-procedure who load-approver-attribution "load-approver-attribution")
  (check-procedure who legacy-unapproved-void? "legacy-unapproved-void?")
  (when approval-consumer
    (unless (and (procedure? approval-consumer)
             (procedure-arity-includes? approval-consumer 5))
      (raise-arguments-error
       who "expected a four-argument approval consumer"
       "approval-consumer" approval-consumer)))
  (check-procedure who commit-command! "commit-command!")
  (when current-epoch-ms
    (check-procedure who current-epoch-ms "current-epoch-ms"))
  (define effective-audit-source
    (or audit-source
        (make-security-audit-source
         'pos_core
         (string-append "audit_runtime_"
                        (bytes->hex-string (crypto-random-bytes 16)))
         (lambda ()
           (inexact->exact (floor (current-inexact-milliseconds)))))))
  (unless (security-audit-source? effective-audit-source)
    (raise-argument-error who "security-audit-source?" effective-audit-source))
  (transaction-service
   connection
   catalog-lookup
   load-events
   load-receipt
   load-attribution
   legacy-unattributed?
   load-approver-attribution
   legacy-unapproved-void?
   approval-consumer
   commit-command!
   current-epoch-ms
   effective-audit-source))

(define (audit-transaction-denial! service principal action kind resource-id)
  (security-audit-append-best-effort!
   (transaction-service-audit-source service)
   (transaction-service-connection service)
   (authorization-denied-event
    (authenticated-operator-operator-id principal)
    (authenticated-operator-role principal)
    #f action kind resource-id)))

(define (audit-transaction-approval-required! service principal command)
  (security-audit-append-best-effort!
   (transaction-service-audit-source service)
   (transaction-service-connection service)
   (approval-required-event
    (authenticated-operator-operator-id principal)
    (transaction-command-command-id command)
    (transaction-command-transaction-id command))))

(define (check-service who service)
  (unless (transaction-service? service)
    (raise-argument-error who "transaction-service?" service)))

(define (check-transaction-id who transaction-id)
  (unless (string? transaction-id)
    (raise-argument-error who "string?" transaction-id)))

(define (load-transaction-unrestricted service transaction-id)
  (define who 'load-transaction-unrestricted)
  (check-service who service)
  (check-transaction-id who transaction-id)

  (define journal-result
    ((transaction-service-load-events service)
     (transaction-service-connection service)
     transaction-id))
  (cond
    [(journal-load-failed? journal-result)
     (transaction-service-recovery-failed
      transaction-id
      'journal-load
      (journal-load-failed-code journal-result)
      (journal-load-failed-stream-sequence journal-result)
      (journal-load-failed-detail journal-result)
      (journal-load-failed-message journal-result))]
    [(journal-load-succeeded? journal-result)
     (define events
       (journal-load-succeeded-events journal-result))
     (define version
       (journal-load-succeeded-version journal-result))
     (cond
       [(null? events)
        (transaction-service-not-found transaction-id)]
       [else
        (define replay-result (replay-transaction events))
        (cond
          [(replay-succeeded? replay-result)
           (transaction-service-success
            (replay-succeeded-transaction replay-result)
            version)]
          [else
           (define event-index
             (replay-failed-event-index replay-result))
           (define rejection-code
             (replay-failed-code replay-result))
           (transaction-service-recovery-failed
            transaction-id
            'replay
            rejection-code
            event-index
            #f
            (format
             "transaction event at index ~a was rejected during replay: ~a"
             event-index
             rejection-code))])])]
    [else
     (error who "event store returned an unsupported load result: ~e"
            journal-result)]))

(define (load-canonical-receipt-unrestricted service transaction-id)
  (define current
    (load-transaction-unrestricted service transaction-id))
  (cond
    [(transaction-service-success? current)
     (define derived
       (derive-canonical-receipt
        (transaction-service-success-transaction current)
        (transaction-service-success-version current)))
     (cond
       [(receipt-created? derived)
        (transaction-service-receipt-success
         (receipt-created-receipt derived))]
       [(receipt-unavailable? derived)
        (transaction-service-receipt-not-available
         transaction-id
         (receipt-unavailable-reason derived))]
       [else
        (error
         'transaction-service-load-canonical-receipt
         "receipt derivation returned an unsupported result: ~e"
         derived)])]
    [(transaction-service-not-found? current)
     (transaction-service-receipt-not-found transaction-id)]
    [(transaction-service-recovery-failed? current) current]
    [else
     (error
      'transaction-service-load-canonical-receipt
      "transaction query returned an unsupported result: ~e"
      current)]))

(define (check-principal who principal)
  (unless (authenticated-operator? principal)
    (raise-argument-error who "authenticated-operator?" principal)))

(define (principal-owns-transaction? principal transaction)
  (define context (transaction-operational-context transaction))
  (and context
       (operator-owns-resource?
        (authenticated-operator-operator-id principal)
        (op:transaction-operational-context-cashier-id context))))

(define (transaction-service-success-owned-by-principal? result principal)
  (define who 'transaction-service-success-owned-by-principal?)
  (unless (transaction-service-success? result)
    (raise-argument-error who "transaction-service-success?" result))
  (check-principal who principal)
  (principal-owns-transaction?
   principal
   (transaction-service-success-transaction result)))

(define (principal-can-read-transaction? principal transaction own-permission any-permission)
  (define role (authenticated-operator-role principal))
  (or (operator-role-authorized? role any-permission)
      (and (operator-role-authorized? role own-permission)
           (principal-owns-transaction? principal transaction))))

(define (transaction-service-load-transaction service principal transaction-id)
  (define who 'transaction-service-load-transaction)
  (check-service who service)
  (check-principal who principal)
  (define result (load-transaction-unrestricted service transaction-id))
  (cond
    [(transaction-service-success? result)
     (if (principal-can-read-transaction?
          principal
          (transaction-service-success-transaction result)
          'transaction.read.own
          'transaction.read.any)
         result
         ;; Cashier reads deliberately collapse non-ownership into not-found.
         (begin
           (audit-transaction-denial!
            service principal 'transaction.read.own
            'transaction transaction-id)
           (transaction-service-not-found transaction-id)))]
    [else result]))

(define (transaction-service-load-canonical-receipt
         service principal transaction-id)
  (define who 'transaction-service-load-canonical-receipt)
  (check-service who service)
  (check-principal who principal)
  (define current (load-transaction-unrestricted service transaction-id))
  (cond
    [(transaction-service-success? current)
     (if (principal-can-read-transaction?
          principal
          (transaction-service-success-transaction current)
          'receipt.read.own
          'receipt.read.any)
         (load-canonical-receipt-unrestricted service transaction-id)
         (begin
           (audit-transaction-denial!
            service principal 'receipt.read.own
            'receipt transaction-id)
           (transaction-service-receipt-not-found transaction-id)))]
    [(transaction-service-not-found? current)
     (transaction-service-receipt-not-found transaction-id)]
    [else current]))

(define (domain-rejection-code->outcome-code code)
  (case code
    [(unknown-barcode) "unknown_barcode"]
    [(invalid-transaction-state) "invalid_transaction_state"]
    [(empty-transaction) "empty_transaction"]
    [(insufficient-tender) "insufficient_tender"]
    [(line-item-not-found) "line_item_not_found"]
    [else
     (error
      'domain-rejection-code->outcome-code
      "domain returned an unmapped durable rejection code: ~e"
      code)]))

(define (accepted-plan command decision-version events)
  (transaction-command-commit-plan
   command decision-version 'accepted "accepted" events))

(define (accepted-plan-with-pre-effect
         command decision-version events operational-effect)
  (transaction-command-commit-plan-with-pre-append-effect
   (accepted-plan command decision-version events)
   operational-effect))

(define (accepted-plan-with-post-effect
         command decision-version events operational-effect)
  (transaction-command-commit-plan-with-post-append-effect
   (accepted-plan command decision-version events)
   operational-effect))

(define (receipt-only-plan command decision-version kind code)
  (transaction-command-commit-plan
   command decision-version kind code '()))

(define (map-commit-result command result)
  (cond
    [(transaction-command-commit-resolved? result)
     (transaction-service-command-resolved
      (transaction-command-commit-resolved-receipt result))]
    [(transaction-command-commit-id-reused? result)
     (transaction-service-command-id-reused
      (transaction-command-commit-id-reused-command-id result))]
    [(transaction-command-commit-authorization-denied? result)
     (transaction-service-authorization-denied)]
    [(transaction-command-commit-approval-required? result)
     (transaction-service-approval-required)]
    [(transaction-command-commit-failed? result)
     (transaction-service-command-persistence-failed
      (transaction-command-command-id command)
      (transaction-command-commit-failed-code result)
      (transaction-command-commit-failed-detail result)
      (transaction-command-commit-failed-message result))]
    [else
     (error
      'map-commit-result
      "command unit of work returned an unsupported result: ~e"
      result)]))

(define (commit-plan service principal plan [approval-capability #f])
  (define command
    (transaction-command-commit-plan-command plan))
  (define actor-bound
    (transaction-command-commit-plan-with-actor
     plan (authenticated-operator-operator-id principal)
     (authenticated-operator-credential-revision principal)))
  (define approval-bound
    (if (and approval-capability
             (void-transaction-command? command)
             (transaction-service-approval-consumer service))
        (transaction-command-commit-plan-with-approval
         actor-bound
         approval-capability
         (transaction-service-approval-consumer service))
        actor-bound))
  (map-commit-result
   command
   ((transaction-service-commit-command! service)
    (transaction-service-connection service)
    approval-bound)))

(define (current-epoch-ms service)
  (define clock (transaction-service-current-epoch-ms service))
  (unless clock
    (error 'current-epoch-ms
           "operational transaction planning requires an injected clock"))
  (define value (clock))
  (unless (and (exact-integer? value) (>= value 0))
    (error 'current-epoch-ms
           "clock returned an invalid epoch millisecond value"))
  value)

(define (slot-result->operational-effect result)
  (cond
    [(or (shift-transaction-slot-claimed? result)
         (shift-transaction-slot-released? result))
     (transaction-command-operational-effect-succeeded)]
    [(shift-transaction-slot-rejected? result)
     (transaction-command-operational-effect-rejected
      'domain-rejected
      (case (shift-transaction-slot-rejected-code result)
        [(shift-required) "shift_required"]
        [(shift-has-active-transaction) "shift_has_active_transaction"]
        [else
         (error 'slot-result->operational-effect
                "unsupported shift-slot rejection: ~e"
                result)]))]
    [(shift-transaction-slot-failed? result)
     (transaction-command-operational-effect-failed
      (shift-transaction-slot-failed-code result)
      #f
      (shift-transaction-slot-failed-message result))]
    [else
     (error 'slot-result->operational-effect
            "unsupported shift-slot result: ~e"
            result)]))

(define (claim-slot-effect context transaction-id)
  (lambda (connection)
    (slot-result->operational-effect
     (claim-shift-transaction-slot/in-transaction!
      connection context transaction-id))))

(define (release-slot-effect context transaction-id)
  (lambda (connection)
    (slot-result->operational-effect
     (release-shift-transaction-slot/in-transaction!
      connection context transaction-id))))

(define (dispatch-start-command service principal command)
  ;; Even a structurally valid start command with a nonzero expected version
  ;; must observe the real stream before its deterministic receipt is frozen.
  (define current
    (load-transaction-unrestricted
     service
     (transaction-command-transaction-id command)))
  (cond
    [(transaction-service-recovery-failed? current) current]
    [else
     (define actual-version
       (if (transaction-service-not-found? current)
           0
           (transaction-service-success-version current)))
     (cond
       [(and (transaction-service-current-epoch-ms service)
             (transaction-service-success? current)
             (not
              (principal-owns-transaction?
               principal (transaction-service-success-transaction current))))
        (transaction-service-authorization-denied)]
       [(not (zero? (transaction-command-expected-version command)))
        (commit-plan
         service
         principal
         (receipt-only-plan
          command
          actual-version
          'version-conflict
          "invalid_expected_version"))]
       [(transaction-service-success? current)
        (commit-plan
         service
         principal
         (receipt-only-plan
          command
          actual-version
          'already-exists
          "transaction_already_exists"))]
       [(transaction-service-not-found? current)
        (cond
          [(not (transaction-service-current-epoch-ms service))
           ;; Focused legacy/domain tests can retain the historical composition.
           ;; Production runtime always injects the POS-Core clock and therefore
           ;; always takes the operationally bound branch below.
           (define result
             (start-transaction
              (transaction-command-transaction-id command)))
           (commit-plan
            service
            principal
            (accepted-plan command 0 (start-accepted-events result)))]
          [else
           (define register-context
             (load-register-context
              (transaction-service-connection service)))
           (cond
             [(not (register-context-configured? register-context))
              (commit-plan
               service
               principal
               (receipt-only-plan
                command 0 'domain-rejected "register_not_configured"))]
             [(not (register-context-active-shift register-context))
              (commit-plan
               service
               principal
               (receipt-only-plan
                command 0 'domain-rejected "shift_required"))]
             [(not
               (operator-owns-resource?
                (authenticated-operator-operator-id principal)
                (register-shift-cashier-id
                 (register-context-active-shift register-context))))
              (transaction-service-authorization-denied)]
             [(register-shift-active-transaction-id
               (register-context-active-shift register-context))
              (commit-plan
               service
               principal
               (receipt-only-plan
                command 0 'domain-rejected
                "shift_has_active_transaction"))]
             [else
              (define shift
                (register-context-active-shift register-context))
              (define context
                (op:transaction-operational-context
                 (register-shift-register-id shift)
                 (register-shift-register-display-name shift)
                 (register-shift-cashier-id shift)
                 (register-shift-cashier-display-name shift)
                 (register-shift-shift-id shift)
                 (current-epoch-ms service)))
              (define result
                (start-transaction-with-operational-context
                 (transaction-command-transaction-id command)
                 context))
              (commit-plan
               service
               principal
               (accepted-plan-with-pre-effect
                command
                0
                (start-accepted-events result)
                (claim-slot-effect
                 context
                 (transaction-command-transaction-id command))))])])]
       [else
        (error
         'dispatch-start-command
         "transaction query returned an unsupported result: ~e"
         current)])]))

(define (scan-command->plan service command transaction version)
  (define result
    (scan-barcode
     transaction
     (scan-barcode-command-barcode command)
     (transaction-service-catalog-lookup service)))
  (if (scan-accepted? result)
      (accepted-plan command version (scan-accepted-events result))
      (receipt-only-plan
       command
       version
       'domain-rejected
       (domain-rejection-code->outcome-code
        (scan-rejected-code result)))))

(define (tender-command->plan command transaction version)
  (define result
    (tender-cash transaction (tender-cash-command-amount command)))
  (if (tender-accepted? result)
      (accepted-plan command version (tender-accepted-events result))
      (receipt-only-plan
       command
       version
       'domain-rejected
       (domain-rejection-code->outcome-code
        (tender-rejected-code result)))))

(define (completion-command->plan service command transaction version)
  (define context (transaction-operational-context transaction))
  (define completed-at (and context (current-epoch-ms service)))
  (define result
    (complete-transaction
     transaction
     completed-at))
  (if (completion-accepted? result)
      (if context
          (accepted-plan-with-post-effect
           command
           version
           (completion-accepted-events result)
           (lambda (connection)
             (record-completed-cash-sale/in-transaction!
              connection
              (op:transaction-operational-context-shift-id context)
              (transaction-id transaction)
              (transaction-total transaction)
              completed-at)
             ((release-slot-effect context (transaction-id transaction))
              connection)))
          (accepted-plan command version (completion-accepted-events result)))
      (receipt-only-plan
       command
       version
       'domain-rejected
       (domain-rejection-code->outcome-code
       (completion-rejected-code result)))))

(define (remove-command->plan command transaction version)
  (define result
    (remove-line-item
     transaction
     (remove-line-item-command-line-index command)))
  (if (removal-accepted? result)
      (accepted-plan command version (removal-accepted-events result))
      (receipt-only-plan
       command
       version
       'domain-rejected
       (domain-rejection-code->outcome-code
        (removal-rejected-code result)))))

(define (void-command->plan service command transaction version)
  (define result
    (void-transaction
     transaction
     (and (transaction-operational-context transaction)
          (current-epoch-ms service))))
  (if (void-accepted? result)
      (if (transaction-operational-context transaction)
          (accepted-plan-with-post-effect
           command
           version
           (void-accepted-events result)
           (release-slot-effect
            (transaction-operational-context transaction)
            (transaction-id transaction)))
          (accepted-plan command version (void-accepted-events result)))
      (receipt-only-plan
       command
       version
       'domain-rejected
       (domain-rejection-code->outcome-code
        (void-rejected-code result)))))

(define (fresh-existing-command-plan service command transaction version)
  (cond
    [(scan-barcode-command? command)
     (scan-command->plan service command transaction version)]
    [(tender-cash-command? command)
     (tender-command->plan command transaction version)]
    [(complete-transaction-command? command)
     (completion-command->plan service command transaction version)]
    [(remove-line-item-command? command)
     (remove-command->plan command transaction version)]
    [(void-transaction-command? command)
     (void-command->plan service command transaction version)]
    [else
     (error
      'fresh-existing-command-plan
      "unsupported existing-transaction command: ~e"
      command)]))

(define (dispatch-existing-transaction-command
         service principal command approval-capability)
  (define current
    (load-transaction-unrestricted
     service
     (transaction-command-transaction-id command)))
  (cond
    [(transaction-service-recovery-failed? current) current]
    [(transaction-service-not-found? current)
      (commit-plan
      service
      principal
      (receipt-only-plan
       command 0 'not-found "transaction_not_found")
      approval-capability)]
    [(transaction-service-success? current)
     (define actual-version
       (transaction-service-success-version current))
     (cond
       [(and (transaction-service-current-epoch-ms service)
             (not
              (principal-owns-transaction?
               principal (transaction-service-success-transaction current))))
        (transaction-service-authorization-denied)]
       [(not (= actual-version
                (transaction-command-expected-version command)))
        (commit-plan
         service
         principal
         (receipt-only-plan
          command
          actual-version
          'version-conflict
          "stale_expected_version")
         approval-capability)]
       [else
        (commit-plan
         service
         principal
         (fresh-existing-command-plan
          service
          command
          (transaction-service-success-transaction current)
          actual-version)
         approval-capability)])]
    [else
     (error
      'dispatch-existing-transaction-command
      "transaction query returned an unsupported result: ~e"
      current)]))

(define (dispatch-new-command service principal command approval-capability)
  (if (start-transaction-command? command)
      (dispatch-start-command service principal command)
      (dispatch-existing-transaction-command
       service principal command approval-capability)))

(define (receipt-recovery-failure command result)
  (transaction-service-recovery-failed
   (transaction-command-transaction-id command)
   'receipt-load
   (receipt-load-failed-code result)
   #f
   (receipt-load-failed-detail result)
   (receipt-load-failed-message result)))

(define (transaction-service-execute-command
         service principal command #:approval-capability [approval-capability #f])
  (define who 'transaction-service-execute-command)
  (check-service who service)
  (check-principal who principal)
  (unless (transaction-command? command)
    (raise-argument-error who "transaction-command?" command))
  (when (and approval-capability
             (not (transaction-void-approval-capability? approval-capability)))
    (raise-argument-error
     who "(or/c #f transaction-void-approval-capability?)"
     approval-capability))
  (when (and approval-capability (not (void-transaction-command? command)))
    (raise-arguments-error
     who "approval is valid only for void_transaction" "command" command))

  ;; Known identity is resolved before journal recovery, catalog access, or
  ;; domain decision. The unit of work repeats this check under the final
  ;; writer transaction to close the race after this optimistic read.
  (define receipt-result
    ((transaction-service-load-receipt service)
     (transaction-service-connection service)
     (transaction-command-command-id command)))
  (define outcome
    (cond
    [(receipt-load-found? receipt-result)
     (define existing
       (receipt-load-found-receipt receipt-result))
     (define attribution
       ((transaction-service-load-attribution service)
        (transaction-service-connection service)
        (transaction-command-command-id command)))
     (define legacy-unattributed?
       ((transaction-service-legacy-unattributed? service)
        (transaction-service-connection service)
        (transaction-command-command-id command)))
     (define approver-attribution
       ((transaction-service-load-approver-attribution service)
        (transaction-service-connection service)
        (transaction-command-command-id command)))
     (define legacy-unapproved-void?
       ((transaction-service-legacy-unapproved-void? service)
        (transaction-service-connection service)
        (transaction-command-command-id command)))
     (define void-receipt?
       (void-transaction-command?
        (transaction-command-receipt-command existing)))
     (cond
       [(or (and attribution legacy-unattributed?)
            (and (not attribution) (not legacy-unattributed?)))
        ;; A receipt must carry exactly one immutable provenance category.
        ;; Missing modern attribution and contradictory classification both
       ;; fail closed without exposing the stored payload or outcome.
        (transaction-service-authorization-denied)]
       [(and attribution
             (not
              (operator-owns-resource?
               (authenticated-operator-operator-id principal)
               (transaction-command-actor-attribution-operator-id
                attribution))))
        ;; Another actor cannot probe the command's approval provenance.
        (transaction-service-authorization-denied)]
       [(if void-receipt?
            (or (and approver-attribution legacy-unapproved-void?)
                (and (not approver-attribution)
                     (not legacy-unapproved-void?)))
            (or approver-attribution legacy-unapproved-void?))
        (transaction-service-authorization-denied)]
       [(equal? (transaction-command-receipt-command existing) command)
        (transaction-service-command-resolved existing)]
       [else
        (transaction-service-command-id-reused
         (transaction-command-command-id command))])]
    [(receipt-load-failed? receipt-result)
     (receipt-recovery-failure command receipt-result)]
    [(receipt-load-not-found? receipt-result)
     (if (operator-role-authorized?
         (authenticated-operator-role principal)
          'transaction.operate.own)
         (dispatch-new-command
          service principal command approval-capability)
         (transaction-service-authorization-denied))]
    [else
     (error
      who
      "receipt store returned an unsupported load result: ~e"
      receipt-result)]))
  (cond
    [(transaction-service-authorization-denied? outcome)
     (audit-transaction-denial!
      service principal 'transaction.operate.own
      'transaction_command (transaction-command-command-id command))]
    [(transaction-service-approval-required? outcome)
     (audit-transaction-approval-required! service principal command)])
  outcome)
