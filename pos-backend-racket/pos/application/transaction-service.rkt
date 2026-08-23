#lang racket

(require (prefix-in db: db)
         "transaction-command-receipt.rkt"
         "transaction-command.rkt"
         "../domain/canonical-receipt.rkt"
         "../domain/transaction.rkt"
         "../persistence/sqlite-transaction-event-store.rkt"
         "../persistence/transaction-command-receipt-store.rkt"
         "../persistence/transaction-command-unit-of-work.rkt")

(provide make-transaction-service
         transaction-service?
         transaction-service-load-transaction
         transaction-service-load-canonical-receipt
         transaction-service-execute-command
         transaction-service-success?
         transaction-service-success-transaction
         transaction-service-success-version
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
         transaction-service-command-persistence-failed?
         transaction-service-command-persistence-failed-command-id
         transaction-service-command-persistence-failed-code
         transaction-service-command-persistence-failed-detail
         transaction-service-command-persistence-failed-message)

(struct transaction-service
  (connection catalog-lookup load-events load-receipt commit-command!))

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
         #:commit-command!
         [commit-command! commit-transaction-command-outcome!])
  (define who 'make-transaction-service)
  (unless (db:connection? connection)
    (raise-argument-error who "connection?" connection))
  (check-procedure who catalog-lookup "catalog-lookup")
  (check-procedure who load-events "load-events")
  (check-procedure who load-receipt "load-receipt")
  (check-procedure who commit-command! "commit-command!")
  (transaction-service
   connection catalog-lookup load-events load-receipt commit-command!))

(define (check-service who service)
  (unless (transaction-service? service)
    (raise-argument-error who "transaction-service?" service)))

(define (check-transaction-id who transaction-id)
  (unless (string? transaction-id)
    (raise-argument-error who "string?" transaction-id)))

(define (transaction-service-load-transaction service transaction-id)
  (define who 'transaction-service-load-transaction)
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

(define (transaction-service-load-canonical-receipt service transaction-id)
  (define current
    (transaction-service-load-transaction service transaction-id))
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

(define (commit-plan service plan)
  (define command
    (transaction-command-commit-plan-command plan))
  (map-commit-result
   command
   ((transaction-service-commit-command! service)
    (transaction-service-connection service)
    plan)))

(define (dispatch-start-command service command)
  ;; Even a structurally valid start command with a nonzero expected version
  ;; must observe the real stream before its deterministic receipt is frozen.
  (define current
    (transaction-service-load-transaction
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
       [(not (zero? (transaction-command-expected-version command)))
        (commit-plan
         service
         (receipt-only-plan
          command
          actual-version
          'version-conflict
          "invalid_expected_version"))]
       [(transaction-service-success? current)
        (commit-plan
         service
         (receipt-only-plan
          command
          actual-version
          'already-exists
          "transaction_already_exists"))]
       [(transaction-service-not-found? current)
        (define result
          (start-transaction
           (transaction-command-transaction-id command)))
        (commit-plan
         service
         (accepted-plan command 0 (start-accepted-events result)))]
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

(define (completion-command->plan command transaction version)
  (define result
    (complete-transaction transaction))
  (if (completion-accepted? result)
      (accepted-plan command version (completion-accepted-events result))
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

(define (void-command->plan command transaction version)
  (define result (void-transaction transaction))
  (if (void-accepted? result)
      (accepted-plan command version (void-accepted-events result))
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
     (completion-command->plan command transaction version)]
    [(remove-line-item-command? command)
     (remove-command->plan command transaction version)]
    [(void-transaction-command? command)
     (void-command->plan command transaction version)]
    [else
     (error
      'fresh-existing-command-plan
      "unsupported existing-transaction command: ~e"
      command)]))

(define (dispatch-existing-transaction-command service command)
  (define current
    (transaction-service-load-transaction
     service
     (transaction-command-transaction-id command)))
  (cond
    [(transaction-service-recovery-failed? current) current]
    [(transaction-service-not-found? current)
     (commit-plan
      service
      (receipt-only-plan
       command 0 'not-found "transaction_not_found"))]
    [(transaction-service-success? current)
     (define actual-version
       (transaction-service-success-version current))
     (cond
       [(not (= actual-version
                (transaction-command-expected-version command)))
        (commit-plan
         service
         (receipt-only-plan
          command
          actual-version
          'version-conflict
          "stale_expected_version"))]
       [else
        (commit-plan
         service
         (fresh-existing-command-plan
          service
          command
          (transaction-service-success-transaction current)
          actual-version))])]
    [else
     (error
      'dispatch-existing-transaction-command
      "transaction query returned an unsupported result: ~e"
      current)]))

(define (dispatch-new-command service command)
  (if (start-transaction-command? command)
      (dispatch-start-command service command)
      (dispatch-existing-transaction-command service command)))

(define (receipt-recovery-failure command result)
  (transaction-service-recovery-failed
   (transaction-command-transaction-id command)
   'receipt-load
   (receipt-load-failed-code result)
   #f
   (receipt-load-failed-detail result)
   (receipt-load-failed-message result)))

(define (transaction-service-execute-command service command)
  (define who 'transaction-service-execute-command)
  (check-service who service)
  (unless (transaction-command? command)
    (raise-argument-error who "transaction-command?" command))

  ;; Known identity is resolved before journal recovery, catalog access, or
  ;; domain decision. The unit of work repeats this check under the final
  ;; writer transaction to close the race after this optimistic read.
  (define receipt-result
    ((transaction-service-load-receipt service)
     (transaction-service-connection service)
     (transaction-command-command-id command)))
  (cond
    [(receipt-load-found? receipt-result)
     (define existing
       (receipt-load-found-receipt receipt-result))
     (if (equal? (transaction-command-receipt-command existing)
                 command)
         (transaction-service-command-resolved existing)
         (transaction-service-command-id-reused
          (transaction-command-command-id command)))]
    [(receipt-load-failed? receipt-result)
     (receipt-recovery-failure command receipt-result)]
    [(receipt-load-not-found? receipt-result)
     (dispatch-new-command service command)]
    [else
     (error
      who
      "receipt store returned an unsupported load result: ~e"
      receipt-result)]))
