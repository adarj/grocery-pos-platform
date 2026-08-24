#lang racket

(require (prefix-in db: db)
         "../domain/transaction-event.rkt"
         "transaction-event-codec.rkt")

(provide append-transaction-events!
         prepare-transaction-events
         prepared-transaction-event-batch?
         transaction-stream-version/in-transaction
         append-prepared-transaction-events/in-transaction!
         load-transaction-events
         journal-append-succeeded?
         journal-append-succeeded-new-version
         journal-append-rejected?
         journal-append-rejected-code
         journal-append-rejected-actual-version
         journal-load-succeeded?
         journal-load-succeeded-events
         journal-load-succeeded-version
         journal-load-failed?
         journal-load-failed-code
         journal-load-failed-stream-sequence
         journal-load-failed-detail
         journal-load-failed-message)

(struct journal-append-succeeded (new-version)
  #:transparent)

(struct journal-append-rejected (code actual-version)
  #:transparent)

(struct journal-load-succeeded (events version)
  #:transparent)

(struct journal-load-failed (code stream-sequence detail message)
  #:transparent)

(struct encoded-event (schema-version type json)
  #:transparent)

;; The constructor and fields remain private. Persistence composition code can
;; only obtain a prepared batch by serializing valid domain events through
;; prepare-transaction-events.
(struct prepared-transaction-event-batch (events encoded-events))

(define insert-event-sql
  #<<SQL
INSERT INTO transaction_events
  (transaction_id, stream_sequence, schema_version, event_type, event_json)
VALUES (?, ?, ?, ?, ?)
SQL
  )

(define select-stream-sql
  #<<SQL
SELECT transaction_id,
       stream_sequence,
       schema_version,
       event_type,
       event_json
FROM transaction_events
WHERE transaction_id = ?
ORDER BY stream_sequence ASC
SQL
  )

(define (check-connection who connection)
  (unless (db:connection? connection)
    (raise-argument-error who "connection?" connection)))

(define (check-transaction-id who transaction-id)
  (unless (string? transaction-id)
    (raise-argument-error who "string?" transaction-id)))

(define (check-expected-version who expected-version)
  (unless (exact-nonnegative-integer? expected-version)
    (raise-argument-error
     who
     "exact-nonnegative-integer?"
     expected-version)))

(define (check-event-list who events)
  (unless (and (list? events)
               (andmap transaction-event? events))
    (raise-argument-error who "(listof transaction-event?)" events)))

(define (encode-event event)
  (define representation
    (transaction-event->jsexpr event))
  (encoded-event
   (hash-ref representation 'schema_version)
   (hash-ref representation 'event_type)
   (transaction-event->json-string event)))

(define (prepare-transaction-events events)
  (define who 'prepare-transaction-events)
  (check-event-list who events)
  (when (null? events)
    (raise-arguments-error
     who
     "event batch must not be empty"
     "events"
     events))
  (prepared-transaction-event-batch
   events
   (map encode-event events)))

(define (transaction-stream-version/in-transaction connection transaction-id)
  (define who 'transaction-stream-version/in-transaction)
  (check-connection who connection)
  (check-transaction-id who transaction-id)
  (unless (db:in-transaction? connection)
    (raise-arguments-error
     who
     "requires an active caller-owned database transaction"
     "connection"
     connection))
  (define version
    (db:query-value
     connection
     #<<SQL
SELECT COALESCE(MAX(stream_sequence), 0)
FROM transaction_events
WHERE transaction_id = ?
SQL
     transaction-id))
  (unless (exact-nonnegative-integer? version)
    (error who "journal stream version is invalid: ~e" version))
  version)

(define (validate-stream-identity transaction-id actual-version events)
  (cond
    [(zero? actual-version)
     (define first-event (first events))
     (cond
       [(not (transaction-start-event? first-event))
        (journal-append-rejected
         'first-event-not-transaction-started
         actual-version)]
       [(not (string=?
              transaction-id
              (transaction-start-event-transaction-id first-event)))
        (journal-append-rejected
         'stream-identity-mismatch
         actual-version)]
       [(ormap transaction-start-event? (rest events))
        (journal-append-rejected
         'transaction-already-started
         actual-version)]
       [else #f])]
    [(ormap transaction-start-event? events)
     (journal-append-rejected
      'transaction-already-started
      actual-version)]
    [else #f]))

(define (append-prepared-transaction-events/in-transaction!
         connection
         transaction-id
         expected-version
         prepared-batch)
  (define who
    'append-prepared-transaction-events/in-transaction!)
  (check-connection who connection)
  (check-transaction-id who transaction-id)
  (check-expected-version who expected-version)
  (unless (prepared-transaction-event-batch? prepared-batch)
    (raise-argument-error
     who
     "prepared-transaction-event-batch?"
     prepared-batch))
  (unless (db:in-transaction? connection)
    (raise-arguments-error
     who
     "requires an active caller-owned database transaction"
     "connection"
     connection))

  (define events
    (prepared-transaction-event-batch-events prepared-batch))
  (define encoded-events
    (prepared-transaction-event-batch-encoded-events prepared-batch))
  (define actual-version
    (transaction-stream-version/in-transaction
     connection transaction-id))
  (cond
    [(not (= actual-version expected-version))
     (journal-append-rejected
      'stream-version-conflict
      actual-version)]
    [else
     (define identity-failure
       (validate-stream-identity
        transaction-id
        actual-version
        events))
     (cond
       [identity-failure identity-failure]
       [else
        (for ([encoded (in-list encoded-events)]
              [sequence (in-naturals (add1 actual-version))])
          (db:query-exec
           connection
           insert-event-sql
           transaction-id
           sequence
           (encoded-event-schema-version encoded)
           (encoded-event-type encoded)
           (encoded-event-json encoded)))
        (journal-append-succeeded
         (+ actual-version (length events)))])]))

(define (append-transaction-events! connection
                                    transaction-id
                                    expected-version
                                    events)
  (define who 'append-transaction-events!)
  (check-connection who connection)
  (check-transaction-id who transaction-id)
  (check-expected-version who expected-version)
  (check-event-list who events)

  (cond
    [(null? events)
     (journal-append-rejected 'empty-event-list #f)]
    [else
     ;; Complete serialization before opening the write transaction. A codec
     ;; failure therefore cannot leave even the first event of a batch stored.
     (define prepared-batch (prepare-transaction-events events))
     (db:call-with-transaction
      connection
      (lambda ()
        ;; BEGIN IMMEDIATE reserves the SQLite writer before this read, so a
        ;; competing writer cannot commit between the version check and inserts.
        (append-prepared-transaction-events/in-transaction!
         connection
         transaction-id
         expected-version
         prepared-batch))
      #:option 'immediate)]))

(define (load-failure code sequence detail message)
  (journal-load-failed code sequence detail message))

(define (invalid-envelope-field transaction-id
                                sequence
                                schema-version
                                event-type
                                event-json)
  (cond
    [(not (string? transaction-id)) 'transaction-id]
    [(not (and (exact-integer? sequence) (> sequence 0)))
     'stream-sequence]
    [(not (and (exact-integer? schema-version) (> schema-version 0)))
     'schema-version]
    [(not (string? event-type)) 'event-type]
    [(not (string? event-json)) 'event-json]
    [else #f]))

(define (load-transaction-events connection transaction-id)
  (define who 'load-transaction-events)
  (check-connection who connection)
  (check-transaction-id who transaction-id)

  (define rows
    (db:query-rows connection select-stream-sql transaction-id))
  (let loop ([remaining rows]
             [expected-sequence 1]
             [events-reversed '()])
    (cond
      [(null? remaining)
       (journal-load-succeeded
        (reverse events-reversed)
        (sub1 expected-sequence))]
      [else
       (define row (first remaining))
       (define row-transaction-id (vector-ref row 0))
       (define sequence (vector-ref row 1))
       (define envelope-version (vector-ref row 2))
       (define envelope-type (vector-ref row 3))
       (define event-json (vector-ref row 4))
       (define invalid-field
         (invalid-envelope-field row-transaction-id
                                 sequence
                                 envelope-version
                                 envelope-type
                                 event-json))
       (cond
         [invalid-field
          (load-failure
           'invalid-envelope
           (and (exact-integer? sequence) sequence)
           invalid-field
           (format "journal envelope field ~a has an invalid value"
                   invalid-field))]
         [(not (= sequence expected-sequence))
          (load-failure
           'sequence-corruption
           sequence
           expected-sequence
           (format "expected stream sequence ~a but found ~a"
                   expected-sequence
                   sequence))]
         [(not (string=? row-transaction-id transaction-id))
          (load-failure
           'stream-identity-mismatch
           sequence
           row-transaction-id
           "journal row stream ID does not match the requested stream")]
         [else
          (define decoded
            (json-string->transaction-event event-json))
          (cond
            [(event-decode-failure? decoded)
             (load-failure
              'event-decode-failure
              sequence
              (event-decode-failure-code decoded)
              (event-decode-failure-message decoded))]
            [else
             (define event
               (event-decode-success-event decoded))
             (define canonical-representation
               (transaction-event->jsexpr event))
             (define canonical-version
               (hash-ref canonical-representation 'schema_version))
             (define canonical-type
               (hash-ref canonical-representation 'event_type))
             (cond
               [(not (= envelope-version canonical-version))
                (load-failure
                 'schema-version-mismatch
                 sequence
                 envelope-version
                 "journal schema_version disagrees with event_json")]
               [(not (string=? envelope-type canonical-type))
                (load-failure
                 'event-type-mismatch
                 sequence
                 envelope-type
                 "journal event_type disagrees with event_json")]
               [(and (= sequence 1)
                     (not (transaction-start-event? event)))
                (load-failure
                 'invalid-first-event
                 sequence
                 canonical-type
                 "the first stream event is not transaction_started")]
               [(and (> sequence 1)
                     (transaction-start-event? event))
                (load-failure
                 'duplicate-transaction-started
                 sequence
                 canonical-type
                 "transaction_started appears after the first stream event")]
               [(and (transaction-start-event? event)
                     (not (string=?
                           transaction-id
                           (transaction-start-event-transaction-id event))))
                (load-failure
                 'stream-identity-mismatch
                 sequence
                 (transaction-start-event-transaction-id event)
                 "transaction_started ID disagrees with the journal stream ID")]
               [else
                (loop (rest remaining)
                      (add1 expected-sequence)
                      (cons event events-reversed))])])])])))
