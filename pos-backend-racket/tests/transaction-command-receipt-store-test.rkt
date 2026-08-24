#lang racket

(require db
         json
         racket/file
         rackunit
         "../pos/application/transaction-command-receipt.rkt"
         "../pos/application/transaction-command.rkt"
         "../pos/domain/money.rkt"
         "../pos/persistence/transaction-command-codec.rkt"
         "../pos/persistence/transaction-command-receipt-store.rkt"
         "../pos/persistence/pos-database-migrations.rkt")

(define start-command
  (start-transaction-command "cmd-start" "txn-001" 0))
(define scan-command
  (scan-barcode-command "cmd-scan" "txn-001" 1 "049000001234"))
(define tender-command
  (tender-cash-command "cmd-tender" "txn-001" 2 (money 500)))
(define completion-command
  (complete-transaction-command "cmd-complete" "txn-001" 3))

(define (accepted-receipt command version)
  (transaction-command-receipt command 'accepted "accepted" version))

(define (call-with-store procedure)
  (define connection (sqlite3-connect #:database 'memory))
  (dynamic-wind
    void
    (lambda ()
      (migrate-pos-database! connection)
      (procedure connection))
    (lambda () (disconnect connection))))

(define (loaded-receipt connection command-id)
  (define result
    (load-transaction-command-receipt connection command-id))
  (check-pred receipt-load-found? result)
  (receipt-load-found-receipt result))

(define (check-load-failure connection command-id expected-code)
  (define result
    (load-transaction-command-receipt connection command-id))
  (check-pred receipt-load-failed? result)
  (check-equal? (receipt-load-failed-code result) expected-code)
  (check-pred string? (receipt-load-failed-message result)))

(define raw-insert-sql
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
SQL
  )

(define (raw-insert! connection
                     #:command-id [command-id "cmd-raw"]
                     #:transaction-id [transaction-id "txn-001"]
                     #:schema-version [schema-version 1]
                     #:command-type [command-type "start_transaction"]
                     #:expected-version [expected-version 0]
                     #:command-json
                     [command-json
                      (transaction-command->json-string start-command)]
                     #:outcome-kind [outcome-kind "accepted"]
                     #:outcome-code [outcome-code "accepted"]
                     #:outcome-stream-version [outcome-stream-version 1])
  (query-exec connection
              raw-insert-sql
              command-id
              transaction-id
              schema-version
              command-type
              expected-version
              command-json
              outcome-kind
              outcome-code
              outcome-stream-version))

(module+ test
  (test-case "all command variants insert and load as equal typed receipts"
    (call-with-store
     (lambda (connection)
       (for ([receipt
              (in-list
               (list (accepted-receipt start-command 1)
                     (accepted-receipt scan-command 2)
                     (accepted-receipt tender-command 3)
                     (accepted-receipt completion-command 4)))])
         (define insert-result
           (insert-transaction-command-receipt! connection receipt))
         (check-pred receipt-insert-succeeded? insert-result)
         (check-equal?
          (loaded-receipt
           connection
           (transaction-command-command-id
            (transaction-command-receipt-command receipt)))
          receipt))

       (define loaded-tender
         (loaded-receipt connection "cmd-tender"))
       (define tender
         (transaction-command-receipt-command loaded-tender))
       (check-equal? (tender-cash-command-amount tender) (money 500))
       (check-true
        (exact-integer?
         (money-minor-units (tender-cash-command-amount tender)))))))

  (test-case "all supported outcome kinds and versions round trip"
    (call-with-store
     (lambda (connection)
       (for ([kind (in-list '(accepted
                              domain-rejected
                              not-found
                              already-exists
                              version-conflict))]
             [kind-text (in-list '("accepted"
                                   "domain_rejected"
                                   "not_found"
                                   "already_exists"
                                   "version_conflict"))]
             [version (in-naturals 0)])
         (define command-id (format "cmd-~a" kind-text))
         (define receipt
           (transaction-command-receipt
            (start-transaction-command command-id "txn-outcomes" 0)
            kind
            (format "~a_code" kind-text)
            version))
         (check-pred
          receipt-insert-succeeded?
          (insert-transaction-command-receipt! connection receipt))
         (check-equal? (loaded-receipt connection command-id) receipt)))))

  (test-case "insert derives the complete envelope from Command Schema v1"
    (call-with-store
     (lambda (connection)
       (insert-transaction-command-receipt!
        connection
        (accepted-receipt scan-command 2))

       (define row
         (query-row
          connection
          #<<SQL
SELECT command_id,
       transaction_id,
       command_schema_version,
       command_type,
       expected_version,
       command_json
FROM transaction_command_receipts
WHERE command_id = 'cmd-scan'
SQL
          ))
       (define representation (transaction-command->jsexpr scan-command))
       (check-equal? (vector-ref row 0)
                     (hash-ref representation 'command_id))
       (check-equal? (vector-ref row 1)
                     (hash-ref representation 'transaction_id))
       (check-equal? (vector-ref row 2)
                     (hash-ref representation 'schema_version))
       (check-equal? (vector-ref row 3)
                     (hash-ref representation 'command_type))
       (check-equal? (vector-ref row 4)
                     (hash-ref representation 'expected_version))
       (define decoded
         (json-string->transaction-command (vector-ref row 5)))
       (check-pred command-decode-success? decoded)
       (check-equal? (command-decode-success-command decoded)
                     scan-command))))

  (test-case "missing command ID returns a successful not-found result"
    (call-with-store
     (lambda (connection)
       (check-pred
        receipt-load-not-found?
        (load-transaction-command-receipt connection "cmd-missing")))))

  (test-case "global command IDs cannot overwrite an existing receipt"
    (call-with-store
     (lambda (connection)
       (define original
         (accepted-receipt start-command 1))
       (insert-transaction-command-receipt! connection original)
       (define original-row
         (query-row
          connection
          "SELECT * FROM transaction_command_receipts WHERE command_id = 'cmd-start'"))

       (for ([duplicate
              (in-list
               (list original
                     (transaction-command-receipt
                      (start-transaction-command
                       "cmd-start" "txn-DIFFERENT" 0)
                      'already-exists
                      "transaction_already_exists"
                      7)))])
         (define result
           (insert-transaction-command-receipt! connection duplicate))
         (check-pred receipt-insert-rejected? result)
         (check-equal? (receipt-insert-rejected-code result)
                       'command-id-conflict))

       (check-equal?
        (query-value
         connection
         "SELECT COUNT(*) FROM transaction_command_receipts")
        1)
       (check-equal?
        (query-row
         connection
         "SELECT * FROM transaction_command_receipts WHERE command_id = 'cmd-start'")
        original-row)
       (check-equal? (loaded-receipt connection "cmd-start") original))))

  (test-case "load compares logical commands instead of raw JSON formatting"
    (call-with-store
     (lambda (connection)
       (raw-insert!
        connection
        #:command-id "cmd-scan-format"
        #:expected-version 1
        #:command-type "scan_barcode"
        #:command-json
        #<<JSON
 { "payload" : { "barcode" : "04900000123\u0034" }, "command_type" : "scan_barcode", "expected_version" : 1, "transaction_id" : "txn-001", "command_id" : "cmd-scan-format", "schema_version" : 1 }
JSON
        )
       (define receipt
         (loaded-receipt connection "cmd-scan-format"))
       (check-equal?
        (transaction-command-receipt-command receipt)
        (scan-barcode-command
         "cmd-scan-format" "txn-001" 1 "049000001234")))))

  (test-case "receipt survives a file-backed SQLite close and reopen"
    (define database-path
      (make-temporary-file "grocery-pos-receipts-~a.sqlite"))
    (dynamic-wind
      void
      (lambda ()
        (define writer
          (sqlite3-connect #:database database-path #:mode 'create))
        (dynamic-wind
          void
          (lambda ()
            (migrate-pos-database! writer)
            (insert-transaction-command-receipt!
             writer
             (accepted-receipt tender-command 3)))
          (lambda () (disconnect writer)))

        (define reader
          (sqlite3-connect #:database database-path #:mode 'read/write))
        (dynamic-wind
          void
          (lambda ()
            (check-equal?
             (loaded-receipt reader "cmd-tender")
             (accepted-receipt tender-command 3)))
          (lambda () (disconnect reader))))
      (lambda ()
        (when (file-exists? database-path)
          (delete-file database-path)))))

  (test-case "caller-owned transaction rollback removes a receipt insert"
    (call-with-store
     (lambda (connection)
       (define insert-returned? #f)
       (check-exn
        exn:fail?
        (lambda ()
          (call-with-transaction
           connection
           (lambda ()
             (check-pred
              receipt-insert-succeeded?
              (insert-transaction-command-receipt!
               connection
               (accepted-receipt start-command 1)))
             (set! insert-returned? #t)
             (error 'test "force caller rollback")))))
       (check-true insert-returned?)
       (check-pred
        receipt-load-not-found?
        (load-transaction-command-receipt connection "cmd-start")))))

  (test-case "load fails closed for command-envelope corruption"
    (define cases
      (list
       (list "command ID mismatch"
             (lambda (connection)
               (query-exec
                connection
                "UPDATE transaction_command_receipts SET command_id = 'cmd-other'"))
             "cmd-other"
             'command-id-mismatch)
       (list "transaction ID mismatch"
             (lambda (connection)
               (query-exec
                connection
                "UPDATE transaction_command_receipts SET transaction_id = 'txn-other'"))
             "cmd-start"
             'transaction-id-mismatch)
       (list "schema version mismatch"
             (lambda (connection)
               (query-exec
                connection
                "UPDATE transaction_command_receipts SET command_schema_version = 2"))
             "cmd-start"
             'command-schema-version-mismatch)
       (list "command type mismatch"
             (lambda (connection)
               (query-exec
                connection
                "UPDATE transaction_command_receipts SET command_type = 'scan_barcode'"))
             "cmd-start"
             'command-type-mismatch)
       (list "expected version mismatch"
             (lambda (connection)
               (query-exec
                connection
                "UPDATE transaction_command_receipts SET expected_version = 1"))
             "cmd-start"
             'expected-version-mismatch)))

    (for ([case (in-list cases)])
      (call-with-store
       (lambda (connection)
         (insert-transaction-command-receipt!
          connection
          (accepted-receipt start-command 1))
         ((second case) connection)
         (check-load-failure connection (third case) (fourth case))))))

  (test-case "load fails closed for malformed or unsupported command JSON"
    (for ([command-json
           (in-list
            (list "{not-json"
                  (jsexpr->string
                   (hash-set (transaction-command->jsexpr start-command)
                             'schema_version
                             2))))])
      (call-with-store
       (lambda (connection)
         (insert-transaction-command-receipt!
          connection
          (accepted-receipt start-command 1))
         (query-exec
          connection
          "UPDATE transaction_command_receipts SET command_json = ?"
          command-json)
         (check-load-failure
          connection "cmd-start" 'command-decode-failure)))))

  (test-case "load fails closed for malformed SQLite envelope storage"
    (call-with-store
     (lambda (connection)
       (insert-transaction-command-receipt!
        connection
        (accepted-receipt start-command 1))
       (query-exec connection "PRAGMA ignore_check_constraints = ON")
       (query-exec
        connection
        "UPDATE transaction_command_receipts SET expected_version = 'damaged'")
       (check-load-failure connection "cmd-start" 'invalid-envelope))))

  (test-case "load fails closed for corrupt outcome metadata"
    (define cases
      (list
       (list "future_kind" "accepted" 1 'invalid-outcome-kind)
       (list "accepted" "" 1 'invalid-outcome-code)
       (list "accepted" "accepted" -1
             'invalid-outcome-stream-version)))
    (for ([case (in-list cases)])
      (call-with-store
       (lambda (connection)
         (insert-transaction-command-receipt!
          connection
          (accepted-receipt start-command 1))
         (query-exec connection "PRAGMA ignore_check_constraints = ON")
         (query-exec
          connection
          #<<SQL
UPDATE transaction_command_receipts
SET outcome_kind = ?,
    outcome_code = ?,
    outcome_stream_version = ?
SQL
          (first case)
          (second case)
          (third case))
         (check-load-failure connection "cmd-start" (fourth case))))))

  (test-case "SQLite constraints reject invalid receipt values"
    (call-with-store
     (lambda (connection)
       (define invalid-inserts
         (list
          (lambda () (raw-insert! connection #:command-id ""))
          (lambda ()
            (raw-insert! connection
                         #:command-id "cmd-empty-transaction"
                         #:transaction-id ""))
          (lambda ()
            (raw-insert! connection
                         #:command-id "cmd-negative-expected"
                         #:expected-version -1))
          (lambda ()
            (raw-insert! connection
                         #:command-id "cmd-invalid-kind"
                         #:outcome-kind "future_kind"))
          (lambda ()
            (raw-insert! connection
                         #:command-id "cmd-empty-code"
                         #:outcome-code ""))
          (lambda ()
            (raw-insert! connection
                         #:command-id "cmd-negative-outcome-version"
                         #:outcome-stream-version -1))))
       (for ([insert! (in-list invalid-inserts)])
         (check-exn exn:fail:sql? insert!)))))
)
