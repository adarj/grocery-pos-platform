#lang racket

(require (prefix-in db: db)
         file/sha1
         racket/random
         racket/string
         "../application/transaction-command-receipt.rkt"
         "../application/transaction-command.rkt"
         "../domain/transaction-command-actor-attribution.rkt"
         "../domain/transaction-void-approval.rkt"
         "../domain/transaction-event.rkt"
         "../domain/security-audit-event.rkt"
         "security-audit-store.rkt"
         "sqlite-transaction-event-store.rkt"
         "transaction-command-actor-attribution-store.rkt"
         "transaction-command-receipt-store.rkt"
         "transaction-void-approval-store.rkt")

(provide (struct-out transaction-command-commit-plan)
         transaction-command-commit-plan-with-actor
         transaction-command-commit-plan-with-approval
         transaction-command-commit-plan-with-pre-append-effect
         transaction-command-commit-plan-with-post-append-effect
         (struct-out transaction-command-operational-effect-succeeded)
         (struct-out transaction-command-operational-effect-rejected)
         (struct-out transaction-command-operational-effect-failed)
         (struct-out transaction-command-commit-resolved)
         (struct-out transaction-command-commit-id-reused)
         (struct-out transaction-command-commit-authorization-denied)
         (struct-out transaction-command-commit-approval-required)
         (struct-out transaction-command-commit-failed)
         commit-transaction-command-outcome!)

;; A plan captures a provisional application decision. The guard makes the
;; distinction between accepted facts and receipt-only outcomes explicit:
;; accepted commands must supply events, while rejected/conflict outcomes must
;; never smuggle events into transaction truth.
(struct transaction-command-commit-plan
  (command
   decision-stream-version
   outcome-kind
   outcome-code
   events
   [pre-append-effect #:auto #:mutable]
   [post-append-effect #:auto #:mutable]
   [actor-operator-id #:auto #:mutable]
   [approval-capability #:auto #:mutable]
   [approval-consumer #:auto #:mutable])
  #:auto-value #f
  #:transparent
  #:guard
  (lambda (command
           decision-stream-version
           outcome-kind
           outcome-code
           events
           type-name)
    ;; Reuse the durable receipt value's validation for the command, outcome
    ;; category, code, and nonnegative version.
    (define validated-receipt
      (transaction-command-receipt
       command
       outcome-kind
       outcome-code
       decision-stream-version))
    (unless (and (list? events)
                 (andmap transaction-event? events))
      (raise-argument-error
       type-name
       "(listof transaction-event?)"
       events))
    (cond
      [(eq? outcome-kind 'accepted)
       (when (null? events)
         (raise-arguments-error
          type-name
          "an accepted commit plan requires at least one event"
          "events"
          events))]
      [(pair? events)
       (raise-arguments-error
        type-name
        "a non-accepted commit plan must not contain events"
        "outcome-kind"
        outcome-kind
        "events"
        events)])
    (values
     (transaction-command-receipt-command validated-receipt)
     decision-stream-version
     (transaction-command-receipt-outcome-kind validated-receipt)
     (transaction-command-receipt-outcome-code validated-receipt)
     (for/list ([event (in-list events)]) event))))

(define (transaction-command-commit-plan-with-actor plan operator-id)
  (define who 'transaction-command-commit-plan-with-actor)
  (unless (transaction-command-commit-plan? plan)
    (raise-argument-error who "transaction-command-commit-plan?" plan))
  (unless (and (string? operator-id) (positive? (string-length operator-id)))
    (raise-argument-error who "non-empty string?" operator-id))
  (define existing
    (transaction-command-commit-plan-actor-operator-id plan))
  (when (and existing (not (string=? existing operator-id)))
    (raise-arguments-error
     who "commit plan is already bound to a different actor"
     "existing operator ID" existing
     "requested operator ID" operator-id))
  (set-transaction-command-commit-plan-actor-operator-id!
   plan (string->immutable-string operator-id))
  plan)

(define (transaction-command-commit-plan-with-approval
         plan capability consume-approval!)
  (define who 'transaction-command-commit-plan-with-approval)
  (unless (transaction-command-commit-plan? plan)
    (raise-argument-error who "transaction-command-commit-plan?" plan))
  (unless (void-transaction-command?
           (transaction-command-commit-plan-command plan))
    (raise-arguments-error
     who "approval may be attached only to void_transaction" "plan" plan))
  (unless capability
    (raise-argument-error who "approval-capability" capability))
  (unless (and (procedure? consume-approval!)
               (procedure-arity-includes? consume-approval! 4))
    (raise-argument-error who "four-argument-procedure?" consume-approval!))
  (set-transaction-command-commit-plan-approval-capability! plan capability)
  (set-transaction-command-commit-plan-approval-consumer!
   plan consume-approval!)
  plan)

;; Operational coordination is attached only by application composition after
;; the ordinary transaction decision has produced a valid plan. The effect is
;; invoked inside the same BEGIN IMMEDIATE boundary as event and receipt writes.
(define (set-operational-effect! who plan effect setter)
  (unless (transaction-command-commit-plan? plan)
    (raise-argument-error
     who
     "transaction-command-commit-plan?"
     plan))
  (unless (and (procedure? effect) (procedure-arity-includes? effect 1))
    (raise-argument-error
     who
     "one-argument-procedure?"
     effect))
  (unless (eq? (transaction-command-commit-plan-outcome-kind plan) 'accepted)
    (raise-arguments-error
     who
     "operational effects are valid only for accepted provisional plans"
     "outcome kind"
     (transaction-command-commit-plan-outcome-kind plan)))
  (setter plan effect)
  plan)

(define (transaction-command-commit-plan-with-pre-append-effect plan effect)
  (set-operational-effect!
   'transaction-command-commit-plan-with-pre-append-effect
   plan
   effect
   set-transaction-command-commit-plan-pre-append-effect!))

(define (transaction-command-commit-plan-with-post-append-effect plan effect)
  (set-operational-effect!
   'transaction-command-commit-plan-with-post-append-effect
   plan
   effect
   set-transaction-command-commit-plan-post-append-effect!))

(struct transaction-command-operational-effect-succeeded () #:transparent)
(struct transaction-command-operational-effect-rejected
  (outcome-kind outcome-code)
  #:transparent
  #:guard
  (lambda (outcome-kind outcome-code type-name)
    (define receipt
      (transaction-command-receipt
       (start-transaction-command "validation" "validation" 0)
       outcome-kind
       outcome-code
       0))
    (when (eq? outcome-kind 'accepted)
      (raise-arguments-error
       type-name "operational rejection cannot be accepted"))
    (values (transaction-command-receipt-outcome-kind receipt)
            (transaction-command-receipt-outcome-code receipt))))
(struct transaction-command-operational-effect-failed
  (code detail message)
  #:transparent)

;; A resolved result intentionally does not reveal whether the receipt was
;; newly inserted or loaded for an identical retry.
(struct transaction-command-commit-resolved (receipt)
  #:transparent)

(struct transaction-command-commit-id-reused (command-id)
  #:transparent)

(struct transaction-command-commit-authorization-denied ()
  #:transparent)

(struct transaction-command-commit-approval-required ()
  #:transparent)

(struct transaction-command-commit-failed (code detail message)
  #:transparent)

(define default-audit-source-instance-id
  (string-append "audit_runtime_"
                 (bytes->hex-string (crypto-random-bytes 16))))

(define (default-audit-append! connection event)
  (append-security-audit-event!/in-transaction!
   connection event #:source-kind 'pos_core
   #:source-instance-id default-audit-source-instance-id
   #:occurred-at-epoch-ms
   (inexact->exact (floor (current-inexact-milliseconds)))))

;; Stable persistence failures that occur after event insertion must leave the
;; transaction callback abnormally. Returning a failure normally would cause
;; call-with-transaction to commit an event-only history.
(struct exn:fail:transaction-command-commit exn:fail (result)
  #:transparent)

(define (abort-transaction! result)
  (raise
   (exn:fail:transaction-command-commit
    (transaction-command-commit-failed-message result)
    (current-continuation-marks)
    result)))

(define (check-procedure who value argument-name)
  (unless (procedure? value)
    (raise-arguments-error
     who
     "expected a procedure"
     argument-name
     value)))

(define (receipt-load-failure-result result)
  (transaction-command-commit-failed
   'receipt-load-failure
   (receipt-load-failed-code result)
   (receipt-load-failed-message result)))

(define (insert-receipt-or-abort!
         connection receipt actor-operator-id approver-attribution
         insert-receipt! insert-attribution! insert-approver-attribution!)
  (define result
    (insert-receipt! connection receipt))
  (cond
    [(receipt-insert-succeeded? result)
     (insert-attribution!
      connection
      (transaction-command-actor-attribution
       (transaction-command-command-id
        (transaction-command-receipt-command receipt))
       actor-operator-id))
     (when approver-attribution
       (insert-approver-attribution! connection approver-attribution))
     receipt]
    [(receipt-insert-rejected? result)
     (abort-transaction!
      (transaction-command-commit-failed
       'receipt-insert-conflict
       (receipt-insert-rejected-code result)
       "command receipt insertion conflicted after the authoritative duplicate check"))]
    [else
     (error
      'commit-transaction-command-outcome!
      "receipt store returned an unsupported insert result: ~e"
      result)]))

(define (resolved-after-insert
         connection receipt actor-operator-id approver-attribution
         insert-receipt! insert-attribution! insert-approver-attribution!)
  (transaction-command-commit-resolved
   (insert-receipt-or-abort!
    connection receipt actor-operator-id approver-attribution
    insert-receipt! insert-attribution! insert-approver-attribution!)))

(define (resolve-unused-command!
         connection
         plan
         prepared-events
         insert-receipt!
         insert-attribution!
         insert-approver-attribution!
         stream-version)
  (let/ec return
  (define command
    (transaction-command-commit-plan-command plan))
  (define transaction-id
    (transaction-command-transaction-id command))
  (define decision-version
    (transaction-command-commit-plan-decision-stream-version plan))
  (define actor-operator-id
    (transaction-command-commit-plan-actor-operator-id plan))
  ;; Approval is checked and consumed before any stream/version decision, but
  ;; inside this same outer writer transaction. Consequently every durable
  ;; void outcome consumes one grant and carries approver evidence, while a
  ;; later persistence abort rolls the grant deletion back.
  (define approval-result
    (and
     (void-transaction-command? command)
     (let ([capability
            (transaction-command-commit-plan-approval-capability plan)]
           [consumer
            (transaction-command-commit-plan-approval-consumer plan)])
       (and capability consumer
            (consumer connection capability actor-operator-id command)))))
  (when (and (void-transaction-command? command)
             (not (transaction-void-approval-consumed? approval-result)))
    (return (transaction-command-commit-approval-required)))
  (define approver-attribution
    (and approval-result
         (transaction-void-approval-consumed-attribution approval-result)))
  (define actual-version
    (stream-version connection transaction-id))

  (cond
    [(not (= actual-version decision-version))
     ;; The application decision is obsolete. Freeze only the final race-time
     ;; conflict observed under the writer reservation.
     (resolved-after-insert
      connection
      (transaction-command-receipt
       command
       'version-conflict
       "stream_version_conflict"
      actual-version)
      actor-operator-id approver-attribution
      insert-receipt! insert-attribution! insert-approver-attribution!)]
    [(eq? (transaction-command-commit-plan-outcome-kind plan) 'accepted)
     (define effect
       (transaction-command-commit-plan-pre-append-effect plan))
     (define effect-result
       (if effect
           (effect connection)
           (transaction-command-operational-effect-succeeded)))
     (cond
       [(transaction-command-operational-effect-rejected? effect-result)
        (resolved-after-insert
         connection
         (transaction-command-receipt
          command
          (transaction-command-operational-effect-rejected-outcome-kind
           effect-result)
          (transaction-command-operational-effect-rejected-outcome-code
           effect-result)
          decision-version)
         actor-operator-id approver-attribution
         insert-receipt! insert-attribution! insert-approver-attribution!)]
       [(transaction-command-operational-effect-failed? effect-result)
        (abort-transaction!
         (transaction-command-commit-failed
          (transaction-command-operational-effect-failed-code effect-result)
          (transaction-command-operational-effect-failed-detail effect-result)
          (transaction-command-operational-effect-failed-message effect-result)))]
       [(transaction-command-operational-effect-succeeded? effect-result)
        (define append-result
          (append-prepared-transaction-events/in-transaction!
           connection
           transaction-id
           decision-version
           prepared-events))
        (cond
          [(journal-append-succeeded? append-result)
           (define post-effect
             (transaction-command-commit-plan-post-append-effect plan))
           (define post-result
             (if post-effect
                 (post-effect connection)
                 (transaction-command-operational-effect-succeeded)))
           (cond
             [(transaction-command-operational-effect-succeeded? post-result)
              (resolved-after-insert
               connection
               (transaction-command-receipt
                command
                'accepted
                (transaction-command-commit-plan-outcome-code plan)
                (journal-append-succeeded-new-version append-result))
               actor-operator-id approver-attribution
               insert-receipt! insert-attribution! insert-approver-attribution!)]
             [(transaction-command-operational-effect-failed? post-result)
              (abort-transaction!
               (transaction-command-commit-failed
                (transaction-command-operational-effect-failed-code post-result)
                (transaction-command-operational-effect-failed-detail post-result)
                (transaction-command-operational-effect-failed-message post-result)))]
             [(transaction-command-operational-effect-rejected? post-result)
              (abort-transaction!
               (transaction-command-commit-failed
                'post-append-operational-rejection
                (transaction-command-operational-effect-rejected-outcome-code
                 post-result)
                "post-append operational state rejected an already-decided command"))]
             [else
              (error
               'commit-transaction-command-outcome!
               "post-append operational effect returned an unsupported result: ~e"
               post-result)])]
          [(journal-append-rejected? append-result)
           (abort-transaction!
            (transaction-command-commit-failed
             'event-append-rejected
             (journal-append-rejected-code append-result)
             "prepared transaction events were rejected during atomic commit"))]
          [else
           (error
            'commit-transaction-command-outcome!
            "event store returned an unsupported append result: ~e"
            append-result)])]
       [else
        (error
         'commit-transaction-command-outcome!
         "operational effect returned an unsupported result: ~e"
         effect-result)])]
    [else
     (resolved-after-insert
      connection
      (transaction-command-receipt
       command
       (transaction-command-commit-plan-outcome-kind plan)
       (transaction-command-commit-plan-outcome-code plan)
       decision-version)
      actor-operator-id approver-attribution
      insert-receipt! insert-attribution! insert-approver-attribution!)])))

(define (commit-transaction-command-outcome!
         connection
         plan
         #:insert-receipt!
         [insert-receipt! insert-transaction-command-receipt!]
         #:insert-attribution!
         [insert-attribution! insert-transaction-command-actor-attribution!]
         #:insert-approver-attribution!
         [insert-approver-attribution!
          insert-transaction-command-approver-attribution!]
         #:load-approver-attribution
         [load-approver-attribution
          load-transaction-command-approver-attribution]
         #:legacy-unapproved-void?
         [legacy-unapproved-void?
          transaction-command-receipt-legacy-unapproved-void?]
         #:audit-append! [audit-append! default-audit-append!]
         #:stream-version
         [stream-version transaction-stream-version/in-transaction])
  (define who 'commit-transaction-command-outcome!)
  (unless (db:connection? connection)
    (raise-argument-error who "connection?" connection))
  (unless (transaction-command-commit-plan? plan)
    (raise-argument-error
     who "transaction-command-commit-plan?" plan))
  (unless (and (string? (transaction-command-commit-plan-actor-operator-id plan))
               (positive?
                (string-length
                 (transaction-command-commit-plan-actor-operator-id plan))))
    (raise-arguments-error
     who
     "commit plan requires an authenticated actor"
     "plan"
     plan))
  (when (db:in-transaction? connection)
    (raise-arguments-error
     who
     "must own the outer database transaction"
     "connection"
     connection))
  (check-procedure who insert-receipt! "insert-receipt!")
  (check-procedure who insert-attribution! "insert-attribution!")
  (check-procedure
   who insert-approver-attribution! "insert-approver-attribution!")
  (check-procedure who load-approver-attribution "load-approver-attribution")
  (check-procedure who legacy-unapproved-void? "legacy-unapproved-void?")
  (check-procedure who stream-version "stream-version")
  (check-procedure who audit-append! "audit-append!")

  ;; Complete Schema v1 serialization before BEGIN IMMEDIATE. The prepared
  ;; representation is opaque and can only be produced by the event codec.
  (define prepared-events
    (and (eq? (transaction-command-commit-plan-outcome-kind plan) 'accepted)
         (prepare-transaction-events
          (transaction-command-commit-plan-events plan))))
  (define command
    (transaction-command-commit-plan-command plan))
  (define command-id
    (transaction-command-command-id command))

  (with-handlers
      ([exn:fail:transaction-command-commit?
        exn:fail:transaction-command-commit-result])
    (db:call-with-transaction
     connection
     (lambda ()
       ;; Duplicate lookup deliberately precedes every stream read. A delayed
       ;; retry must recover its original outcome even after the stream moves.
       (define load-result
         (load-transaction-command-receipt connection command-id))
       (cond
         [(receipt-load-found? load-result)
          (define existing
            (receipt-load-found-receipt load-result))
          (define attribution
            (load-transaction-command-actor-attribution connection command-id))
          (define legacy-unattributed?
            (transaction-command-receipt-legacy-unattributed?
             connection command-id))
          (define approver-attribution
            (load-approver-attribution connection command-id))
          (define legacy-unapproved-void-receipt?
            (legacy-unapproved-void? connection command-id))
          (define void-receipt?
            (void-transaction-command?
             (transaction-command-receipt-command existing)))
          (cond
            [(or (and attribution legacy-unattributed?)
                 (and (not attribution) (not legacy-unattributed?)))
             ;; The final writer check must not treat a broken modern receipt
             ;; as historical merely because its actor row is absent.
             (transaction-command-commit-authorization-denied)]
            [(and attribution
                  (not
                   (string=?
                    (transaction-command-actor-attribution-operator-id
                     attribution)
                    (transaction-command-commit-plan-actor-operator-id plan))))
             ;; Requester ownership precedes any approval-provenance probe.
             (transaction-command-commit-authorization-denied)]
            [(if void-receipt?
                 (or (and approver-attribution
                          legacy-unapproved-void-receipt?)
                     (and (not approver-attribution)
                          (not legacy-unapproved-void-receipt?)))
                 (or approver-attribution legacy-unapproved-void-receipt?))
             ;; Modern missing approval evidence is never reclassified as a
             ;; historical unapproved void merely because the row is absent.
             (transaction-command-commit-authorization-denied)]
            [(equal? (transaction-command-receipt-command existing) command)
             (transaction-command-commit-resolved existing)]
            [else (transaction-command-commit-id-reused command-id)])]
         [(receipt-load-failed? load-result)
          (receipt-load-failure-result load-result)]
         [(receipt-load-not-found? load-result)
          (define fresh-result
            (resolve-unused-command!
             connection
             plan
             prepared-events
             insert-receipt!
             insert-attribution!
             insert-approver-attribution!
             stream-version))
          (when (and (void-transaction-command? command)
                     (transaction-command-commit-resolved? fresh-result))
            (define approver (load-approver-attribution connection command-id))
            (unless (transaction-command-approver-attribution? approver)
              (abort-transaction!
               (transaction-command-commit-failed
                'audit-evidence-missing #f
                "fresh approved void has no durable approver evidence")))
            (define receipt
              (transaction-command-commit-resolved-receipt fresh-result))
            (with-handlers
                ([exn:fail?
                  (lambda (_exception)
                    (abort-transaction!
                     (transaction-command-commit-failed
                      'audit-append-failed #f
                      "required void security audit could not be appended")))])
              (audit-append!
               connection
               (void-resolved-event
                (transaction-command-commit-plan-actor-operator-id plan)
                (transaction-command-approver-attribution-approver-operator-id
                 approver)
                (transaction-command-approver-attribution-approval-id approver)
                command-id
                (transaction-command-transaction-id command)
                (string-replace
                 (symbol->string (transaction-command-receipt-outcome-kind
                                  receipt))
                 "-" "_")
                (transaction-command-receipt-outcome-code receipt)))))
          fresh-result]
         [else
          (error
           who
           "receipt store returned an unsupported load result: ~e"
           load-result)]))
     #:option 'immediate)))
