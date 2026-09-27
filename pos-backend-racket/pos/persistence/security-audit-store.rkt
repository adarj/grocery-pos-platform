#lang racket

(require (prefix-in db: db)
         file/sha1
         "../domain/security-audit-event.rkt"
         "security-audit-event-codec.rkt")

(provide append-security-audit-event!
         append-security-audit-event!/in-transaction!
         verify-security-audit-ledger
         list-security-audit-events
         security-audit-ledger-valid?
         security-audit-ledger-valid-event-count
         security-audit-ledger-invalid?
         security-audit-ledger-invalid-sequence
         security-audit-ledger-invalid-reason)

(struct security-audit-ledger-valid (event-count tail-hash) #:transparent)
(struct security-audit-ledger-invalid (sequence reason) #:transparent)

(define audit-domain #"grocery-pos/security-audit/v1\0")
(define genesis-hash (make-bytes 32 0))

(define (u64 value)
  (unless (and (exact-integer? value)
               (<= 0 value)
               (< value (expt 2 63)))
    (error 'security-audit-hash "invalid integer field"))
  (integer->integer-bytes value 8 #f #t))

(define (length-prefixed bytes)
  (bytes-append (u64 (bytes-length bytes)) bytes))

(define (audit-row-hash sequence schema-version occurred-at-epoch-ms
                        source-kind source-instance-id event-type event-json
                        previous-hash)
  (sha256-bytes
   (bytes-append
    audit-domain
    (u64 sequence)
    (u64 schema-version)
    (u64 occurred-at-epoch-ms)
    (length-prefixed (string->bytes/utf-8 source-kind))
    (length-prefixed (string->bytes/utf-8 source-instance-id))
    (length-prefixed (string->bytes/utf-8 event-type))
    (length-prefixed (string->bytes/utf-8 event-json))
    previous-hash)))

(define (source-kind->string source-kind)
  (unless (memq source-kind '(pos_core root_cli))
    (raise-argument-error 'append-security-audit-event!
                          "(or/c 'pos_core 'root_cli)" source-kind))
  (symbol->string source-kind))

(define (append-security-audit-event!/in-transaction!
         connection event
         #:source-kind source-kind
         #:source-instance-id source-instance-id
         #:occurred-at-epoch-ms occurred-at-epoch-ms)
  (unless (db:in-transaction? connection)
    (error 'append-security-audit-event!/in-transaction!
           "an active SQLite writer transaction is required"))
  (unless (and (string? source-instance-id)
               (positive? (string-length source-instance-id)))
    (raise-argument-error 'append-security-audit-event!/in-transaction!
                          "non-empty string?" source-instance-id))
  (define event-json (security-audit-event->json event))
  (define source-text (source-kind->string source-kind))
  (define event-type (symbol->string (security-audit-event-type event)))
  ;; Tail allocation is performed only after the caller owns the writer.
  (define tail
    (db:query-maybe-row
     connection
     "SELECT sequence, event_hash FROM security_audit_events ORDER BY sequence DESC LIMIT 1"))
  (define sequence (if tail (add1 (vector-ref tail 0)) 1))
  (define previous-hash (if tail (vector-ref tail 1) genesis-hash))
  (define event-hash
    (audit-row-hash sequence 1 occurred-at-epoch-ms source-text
                    source-instance-id event-type event-json previous-hash))
  (db:query-exec
   connection
   #<<SQL
INSERT INTO security_audit_events
  (sequence, schema_version, occurred_at_epoch_ms, source_kind,
   source_instance_id, event_type, event_json, previous_event_hash,
   event_hash)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
SQL
   sequence 1 occurred-at-epoch-ms source-text source-instance-id
   event-type event-json previous-hash event-hash)
  sequence)

(define (append-security-audit-event!
         connection event
         #:source-kind source-kind
         #:source-instance-id source-instance-id
         #:occurred-at-epoch-ms occurred-at-epoch-ms)
  (when (db:in-transaction? connection)
    (error 'append-security-audit-event!
           "standalone append cannot run inside another transaction"))
  (db:call-with-transaction
   connection
   (lambda ()
     (append-security-audit-event!/in-transaction!
      connection event
      #:source-kind source-kind
      #:source-instance-id source-instance-id
      #:occurred-at-epoch-ms occurred-at-epoch-ms))
   #:option 'immediate))

(define (valid-hash? value)
  (and (bytes? value) (= (bytes-length value) 32)))

(define (verify-security-audit-ledger connection)
  ;; in-query streams rows instead of materializing an unbounded security log.
  (define expected-sequence 1)
  (define previous-hash genesis-hash)
  (with-handlers ([exn:fail?
                   (lambda (_exception)
                     (security-audit-ledger-invalid
                      expected-sequence 'invalid_row))])
    (for ([(sequence schema-version occurred-at-epoch-ms source-kind
                     source-instance-id event-type event-json stored-previous
                     stored-hash)
           (db:in-query
            connection
            #<<SQL
SELECT sequence, schema_version, occurred_at_epoch_ms, source_kind,
       source_instance_id, event_type, event_json, previous_event_hash,
       event_hash
FROM security_audit_events
ORDER BY sequence ASC
SQL
            )])
      (unless (and (exact-integer? sequence)
                   (= sequence expected-sequence)
                   (= schema-version 1)
                   (exact-integer? occurred-at-epoch-ms)
                   (>= occurred-at-epoch-ms 0)
                   (member source-kind '("pos_core" "root_cli"))
                   (string? source-instance-id)
                   (positive? (string-length source-instance-id))
                   (string? event-type)
                   (string? event-json)
                   (valid-hash? stored-previous)
                   (valid-hash? stored-hash)
                   (bytes=? stored-previous previous-hash))
        (error 'verify-security-audit-ledger "invalid audit row"))
      (decode-security-audit-event-json (string->symbol event-type) event-json)
      (unless (bytes=?
               stored-hash
               (audit-row-hash sequence schema-version occurred-at-epoch-ms
                               source-kind source-instance-id event-type
                               event-json stored-previous))
        (error 'verify-security-audit-ledger "audit hash mismatch"))
      (set! previous-hash stored-hash)
      (set! expected-sequence (add1 expected-sequence)))
    (security-audit-ledger-valid (sub1 expected-sequence) previous-hash)))

(define (list-security-audit-events connection after-sequence limit)
  (unless (and (exact-integer? after-sequence) (>= after-sequence 0))
    (raise-argument-error 'list-security-audit-events
                          "exact-nonnegative-integer?" after-sequence))
  (unless (and (exact-integer? limit) (<= 1 limit 1000))
    (raise-argument-error 'list-security-audit-events
                          "integer from 1 through 1000" limit))
  (for/list ([row
              (in-list
               (db:query-rows
                connection
                #<<SQL
SELECT sequence, occurred_at_epoch_ms, source_kind, source_instance_id,
       event_type, event_json, event_hash
FROM security_audit_events
WHERE sequence > ?
ORDER BY sequence ASC
LIMIT ?
SQL
                after-sequence limit))])
    (define event-type (vector-ref row 4))
    (hash 'sequence (vector-ref row 0)
          'occurred_at_epoch_ms (vector-ref row 1)
          'source_kind (vector-ref row 2)
          'source_instance_id (vector-ref row 3)
          'event_type event-type
          'event (decode-security-audit-event-json
                  (string->symbol event-type) (vector-ref row 5))
          'event_hash (bytes->hex-string (vector-ref row 6)))))
