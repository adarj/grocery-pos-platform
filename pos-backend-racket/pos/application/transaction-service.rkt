#lang racket

(require (prefix-in db: db)
         "../domain/money.rkt"
         "../domain/transaction.rkt"
         "../persistence/sqlite-transaction-event-store.rkt")

(provide make-transaction-service
         transaction-service?
         transaction-service-load-transaction
         transaction-service-start-transaction
         transaction-service-scan-barcode
         transaction-service-tender-cash
         transaction-service-complete-transaction
         transaction-service-success?
         transaction-service-success-transaction
         transaction-service-success-version
         transaction-service-domain-rejected?
         transaction-service-domain-rejected-code
         transaction-service-domain-rejected-transaction
         transaction-service-domain-rejected-version
         transaction-service-not-found?
         transaction-service-not-found-transaction-id
         transaction-service-already-exists?
         transaction-service-already-exists-transaction-id
         transaction-service-already-exists-version
         transaction-service-stream-conflict?
         transaction-service-stream-conflict-transaction-id
         transaction-service-stream-conflict-expected-version
         transaction-service-stream-conflict-actual-version
         transaction-service-persistence-failed?
         transaction-service-persistence-failed-transaction-id
         transaction-service-persistence-failed-code
         transaction-service-persistence-failed-detail
         transaction-service-recovery-failed?
         transaction-service-recovery-failed-transaction-id
         transaction-service-recovery-failed-stage
         transaction-service-recovery-failed-code
         transaction-service-recovery-failed-position
         transaction-service-recovery-failed-detail
         transaction-service-recovery-failed-message)

(struct transaction-service (connection load-events append-events!))

(struct transaction-service-success (transaction version)
  #:transparent)

(struct transaction-service-domain-rejected (code transaction version)
  #:transparent)

(struct transaction-service-not-found (transaction-id)
  #:transparent)

(struct transaction-service-already-exists (transaction-id version)
  #:transparent)

(struct transaction-service-stream-conflict
  (transaction-id expected-version actual-version)
  #:transparent)

(struct transaction-service-persistence-failed (transaction-id code detail)
  #:transparent)

(struct transaction-service-recovery-failed
  (transaction-id stage code position detail message)
  #:transparent)

(struct accepted-domain-decision (transaction events)
  #:transparent)

(struct rejected-domain-decision (code transaction)
  #:transparent)

(define (make-transaction-service
         connection
         #:load-events [load-events load-transaction-events]
         #:append-events! [append-events! append-transaction-events!])
  (unless (db:connection? connection)
    (raise-argument-error
     'make-transaction-service
     "connection?"
     connection))
  (unless (procedure? load-events)
    (raise-argument-error
     'make-transaction-service
     "procedure?"
     load-events))
  (unless (procedure? append-events!)
    (raise-argument-error
     'make-transaction-service
     "procedure?"
     append-events!))
  (transaction-service connection load-events append-events!))

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

(define (commit-domain-decision service
                                transaction-id
                                expected-version
                                decision)
  (define events
    (accepted-domain-decision-events decision))
  (define provisional-transaction
    (accepted-domain-decision-transaction decision))
  (define append-result
    ((transaction-service-append-events! service)
     (transaction-service-connection service)
     transaction-id
     expected-version
     events))
  (cond
    [(journal-append-succeeded? append-result)
     (define committed-version
       (journal-append-succeeded-new-version append-result))
     (define expected-committed-version
       (+ expected-version (length events)))
     (if (= committed-version expected-committed-version)
         (transaction-service-success
          provisional-transaction
          committed-version)
         (transaction-service-persistence-failed
          transaction-id
          'unexpected-stream-version
          committed-version))]
    [(journal-append-rejected? append-result)
     (define code
       (journal-append-rejected-code append-result))
     (define actual-version
       (journal-append-rejected-actual-version append-result))
     (if (eq? code 'stream-version-conflict)
         (transaction-service-stream-conflict
          transaction-id
          expected-version
          actual-version)
         (transaction-service-persistence-failed
          transaction-id
          code
          actual-version))]
    [else
     (error 'commit-domain-decision
            "event store returned an unsupported append result: ~e"
            append-result)]))

(define (transaction-service-start-transaction service transaction-id)
  (define who 'transaction-service-start-transaction)
  (check-service who service)
  (check-transaction-id who transaction-id)

  (define current
    (transaction-service-load-transaction service transaction-id))
  (cond
    [(transaction-service-not-found? current)
     (define domain-result
       (start-transaction transaction-id))
     (commit-domain-decision
      service
      transaction-id
      0
      (accepted-domain-decision
       (start-accepted-transaction domain-result)
       (start-accepted-events domain-result)))]
    [(transaction-service-success? current)
     (transaction-service-already-exists
      transaction-id
      (transaction-service-success-version current))]
    [else current]))

(define (persist-existing-command service transaction-id decide)
  (define current
    (transaction-service-load-transaction service transaction-id))
  (cond
    [(transaction-service-success? current)
     (define current-transaction
       (transaction-service-success-transaction current))
     (define current-version
       (transaction-service-success-version current))
     (define decision (decide current-transaction))
     (cond
       [(accepted-domain-decision? decision)
        (commit-domain-decision
         service
         transaction-id
         current-version
         decision)]
       [(rejected-domain-decision? decision)
        (transaction-service-domain-rejected
         (rejected-domain-decision-code decision)
         (rejected-domain-decision-transaction decision)
         current-version)]
       [else
        (error 'persist-existing-command
               "domain adapter returned an unsupported decision: ~e"
               decision)])]
    [else current]))

(define (transaction-service-scan-barcode service
                                          transaction-id
                                          barcode
                                          catalog-lookup)
  (define who 'transaction-service-scan-barcode)
  (check-service who service)
  (check-transaction-id who transaction-id)
  (unless (string? barcode)
    (raise-argument-error who "string?" barcode))
  (unless (procedure? catalog-lookup)
    (raise-argument-error who "procedure?" catalog-lookup))

  (persist-existing-command
   service
   transaction-id
   (lambda (current-transaction)
     (define result
       (scan-barcode current-transaction barcode catalog-lookup))
     (if (scan-accepted? result)
         (accepted-domain-decision
          (scan-accepted-transaction result)
          (scan-accepted-events result))
         (rejected-domain-decision
          (scan-rejected-code result)
          (scan-rejected-transaction result))))))

(define (transaction-service-tender-cash service transaction-id amount)
  (define who 'transaction-service-tender-cash)
  (check-service who service)
  (check-transaction-id who transaction-id)
  (unless (money? amount)
    (raise-argument-error who "money?" amount))

  (persist-existing-command
   service
   transaction-id
   (lambda (current-transaction)
     (define result
       (tender-cash current-transaction amount))
     (if (tender-accepted? result)
         (accepted-domain-decision
          (tender-accepted-transaction result)
          (tender-accepted-events result))
         (rejected-domain-decision
          (tender-rejected-code result)
          (tender-rejected-transaction result))))))

(define (transaction-service-complete-transaction service transaction-id)
  (define who 'transaction-service-complete-transaction)
  (check-service who service)
  (check-transaction-id who transaction-id)

  (persist-existing-command
   service
   transaction-id
   (lambda (current-transaction)
     (define result
       (complete-transaction current-transaction))
     (if (completion-accepted? result)
         (accepted-domain-decision
          (completion-accepted-transaction result)
          (completion-accepted-events result))
         (rejected-domain-decision
          (completion-rejected-code result)
          (completion-rejected-transaction result))))))
