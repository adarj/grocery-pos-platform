#lang racket

(require (prefix-in db: db)
         "../application/transaction-command-receipt.rkt"
         "../application/transaction-command.rkt"
         "transaction-command-codec.rkt")

(provide insert-transaction-command-receipt!
         load-transaction-command-receipt
         receipt-insert-succeeded?
         receipt-insert-rejected?
         receipt-insert-rejected-code
         receipt-load-found?
         receipt-load-found-receipt
         receipt-load-not-found?
         receipt-load-failed?
         receipt-load-failed-code
         receipt-load-failed-detail
         receipt-load-failed-message)

(struct receipt-insert-succeeded ()
  #:transparent)

(struct receipt-insert-rejected (code)
  #:transparent)

(struct receipt-load-found (receipt)
  #:transparent)

(struct receipt-load-not-found ()
  #:transparent)

(struct receipt-load-failed (code detail message)
  #:transparent)

(define outcome-kind->text
  (hasheq 'accepted "accepted"
          'domain-rejected "domain_rejected"
          'not-found "not_found"
          'already-exists "already_exists"
          'version-conflict "version_conflict"))

(define outcome-text->kind
  (hash "accepted" 'accepted
        "domain_rejected" 'domain-rejected
        "not_found" 'not-found
        "already_exists" 'already-exists
        "version_conflict" 'version-conflict))

(define insert-receipt-sql
  #<<SQL
INSERT INTO transaction_command_receipts
  (command_id,
   transaction_id,
   command_schema_version,
   command_type,
   expected_version,
   command_json,
   outcome_kind,
   outcome_code,
   outcome_stream_version)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(command_id) DO NOTHING
SQL
  )

(define select-receipt-sql
  #<<SQL
SELECT command_id,
       typeof(command_id),
       transaction_id,
       typeof(transaction_id),
       command_schema_version,
       typeof(command_schema_version),
       command_type,
       typeof(command_type),
       expected_version,
       typeof(expected_version),
       command_json,
       typeof(command_json),
       outcome_kind,
       typeof(outcome_kind),
       outcome_code,
       typeof(outcome_code),
       outcome_stream_version,
       typeof(outcome_stream_version)
FROM transaction_command_receipts
WHERE command_id = ?
SQL
  )

(define (check-connection who connection)
  (unless (db:connection? connection)
    (raise-argument-error who "connection?" connection)))

(define (check-command-id who command-id)
  (unless (and (string? command-id)
               (positive? (string-length command-id)))
    (raise-argument-error who "non-empty string?" command-id)))

(define (insert-transaction-command-receipt! connection receipt)
  (define who 'insert-transaction-command-receipt!)
  (check-connection who connection)
  (unless (transaction-command-receipt? receipt)
    (raise-argument-error
     who "transaction-command-receipt?" receipt))

  (define command
    (transaction-command-receipt-command receipt))
  (define representation
    (transaction-command->jsexpr command))
  (define command-id (hash-ref representation 'command_id))
  (db:query-exec
   connection
   insert-receipt-sql
   command-id
   (hash-ref representation 'transaction_id)
   (hash-ref representation 'schema_version)
   (hash-ref representation 'command_type)
   (hash-ref representation 'expected_version)
   (transaction-command->json-string command)
   (hash-ref outcome-kind->text
             (transaction-command-receipt-outcome-kind receipt))
   (transaction-command-receipt-outcome-code receipt)
   (transaction-command-receipt-outcome-stream-version receipt))

  (define changed-row-count
    (db:query-value connection "SELECT changes()"))
  (cond
    [(= changed-row-count 1) (receipt-insert-succeeded)]
    [(and (= changed-row-count 0)
          (= 1
             (db:query-value
              connection
              #<<SQL
SELECT COUNT(*)
FROM transaction_command_receipts
WHERE command_id = ?
SQL
              command-id)))
     (receipt-insert-rejected 'command-id-conflict)]
    [else
     (error who "receipt insert changed an unexpected row count: ~e"
            changed-row-count)]))

(define (row-value row field-index)
  (vector-ref row (* field-index 2)))

(define (row-storage-type row field-index)
  (vector-ref row (add1 (* field-index 2))))

(define (stored-text? row field-index #:non-empty? [non-empty? #f])
  (define value (row-value row field-index))
  (and (equal? (row-storage-type row field-index) "text")
       (string? value)
       (or (not non-empty?)
           (positive? (string-length value)))))

(define (stored-integer? row field-index predicate)
  (define value (row-value row field-index))
  (and (equal? (row-storage-type row field-index) "integer")
       (exact-integer? value)
       (predicate value)))

(define (invalid-envelope-field row)
  (cond
    [(not (stored-text? row 0 #:non-empty? #t)) 'command-id]
    [(not (stored-text? row 1 #:non-empty? #t)) 'transaction-id]
    [(not (stored-integer? row 2 positive?)) 'command-schema-version]
    [(not (stored-text? row 3 #:non-empty? #t)) 'command-type]
    [(not (stored-integer? row 4 (lambda (value) (>= value 0))))
     'expected-version]
    [(not (stored-text? row 5)) 'command-json]
    [else #f]))

(define (load-failure code detail message)
  (receipt-load-failed code detail message))

(define (decode-outcome-kind row)
  (define value (row-value row 6))
  (and (stored-text? row 6 #:non-empty? #t)
       (hash-ref outcome-text->kind value #f)))

(define (load-transaction-command-receipt connection command-id)
  (define who 'load-transaction-command-receipt)
  (check-connection who connection)
  (check-command-id who command-id)

  (define row
    (db:query-maybe-row connection select-receipt-sql command-id))
  (cond
    [(not row) (receipt-load-not-found)]
    [else
     (define invalid-field (invalid-envelope-field row))
     (cond
       [invalid-field
        (load-failure
         'invalid-envelope
         invalid-field
         (format "command receipt envelope field ~a has an invalid value"
                 invalid-field))]
       [else
        (define decoded
          (json-string->transaction-command (row-value row 5)))
        (cond
          [(command-decode-failure? decoded)
           (load-failure
            'command-decode-failure
            (command-decode-failure-code decoded)
            (command-decode-failure-message decoded))]
          [else
           (define command
             (command-decode-success-command decoded))
           (define representation
             (transaction-command->jsexpr command))
           (define outcome-kind (decode-outcome-kind row))
           (cond
             [(not (string=? (row-value row 0)
                             (transaction-command-command-id command)))
              (load-failure
               'command-id-mismatch
               'command-id
               "receipt command_id disagrees with command_json")]
             [(not (string=? (row-value row 1)
                             (transaction-command-transaction-id command)))
              (load-failure
               'transaction-id-mismatch
               'transaction-id
               "receipt transaction_id disagrees with command_json")]
             [(not (= (row-value row 2)
                      (hash-ref representation 'schema_version)))
              (load-failure
               'command-schema-version-mismatch
               'command-schema-version
               "receipt command_schema_version disagrees with command_json")]
             [(not (string=? (row-value row 3)
                             (hash-ref representation 'command_type)))
              (load-failure
               'command-type-mismatch
               'command-type
               "receipt command_type disagrees with command_json")]
             [(not (= (row-value row 4)
                      (transaction-command-expected-version command)))
              (load-failure
               'expected-version-mismatch
               'expected-version
               "receipt expected_version disagrees with command_json")]
             [(not outcome-kind)
              (load-failure
               'invalid-outcome-kind
               'outcome-kind
               "receipt outcome_kind is invalid")]
             [(not (stored-text? row 7 #:non-empty? #t))
              (load-failure
               'invalid-outcome-code
               'outcome-code
               "receipt outcome_code must be non-empty text")]
             [(not (stored-integer? row 8
                                    (lambda (value) (>= value 0))))
              (load-failure
               'invalid-outcome-stream-version
               'outcome-stream-version
               "receipt outcome_stream_version must be a nonnegative integer")]
             [else
              (receipt-load-found
               (transaction-command-receipt
                command
                outcome-kind
                (row-value row 7)
                (row-value row 8)))])])])]))
