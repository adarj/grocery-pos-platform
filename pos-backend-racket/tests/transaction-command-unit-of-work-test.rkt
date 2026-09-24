#lang racket

(require (prefix-in db: db)
         racket/file
         rackunit
         "../pos/application/transaction-command-receipt.rkt"
         "../pos/application/transaction-command.rkt"
         "../pos/domain/money.rkt"
         "../pos/domain/transaction-event.rkt"
         "../pos/persistence/sqlite-transaction-event-store.rkt"
         "../pos/persistence/sqlite-connection.rkt"
         "../pos/persistence/transaction-command-receipt-store.rkt"
         (rename-in "../pos/persistence/transaction-command-unit-of-work.rkt"
                    [transaction-command-commit-plan
                     transaction-command-commit-plan/without-actor])
         "../pos/persistence/pos-database-migrations.rkt")

(define (transaction-command-commit-plan . fields)
  (transaction-command-commit-plan-with-actor
   (apply transaction-command-commit-plan/without-actor fields)
   "unit-of-work-test-operator" 1))

(define apples
  (sale-item-added "049000001234" "Test Apples" (money 199)))
(define bananas
  (sale-item-added "000000000002" "Test Bananas" (money 250)))
(define tendered
  (cash-tendered (money 500)))
(define completed
  (transaction-completed))

(define (started transaction-id)
  (transaction-started transaction-id))

(define (call-with-store procedure)
  (define connection
    (db:sqlite3-connect #:database 'memory))
  (dynamic-wind
    void
    (lambda ()
      (migrate-pos-database! connection)
      (db:query-exec connection
                      "INSERT INTO operators VALUES ('unit-of-work-test-operator', 'Test', 1)")
      (db:query-exec connection
                      "INSERT INTO operator_roles VALUES ('unit-of-work-test-operator', 'cashier')")
      (db:query-exec connection
                      "INSERT INTO operator_pin_credentials VALUES ('unit-of-work-test-operator', '$argon2id$fixture', 1)")
      (procedure connection))
    (lambda () (db:disconnect connection))))

(define (seed-file-backed-actor! connection)
  (db:query-exec connection
                  "INSERT INTO operators VALUES ('unit-of-work-test-operator', 'Test', 1)")
  (db:query-exec connection
                  "INSERT INTO operator_roles VALUES ('unit-of-work-test-operator', 'cashier')")
  (db:query-exec connection
                  "INSERT INTO operator_pin_credentials VALUES ('unit-of-work-test-operator', '$argon2id$fixture', 1)"))

(define (append! connection transaction-id expected-version events)
  (define result
    (append-transaction-events!
     connection transaction-id expected-version events))
  (check-pred journal-append-succeeded? result)
  result)

(define (loaded-events connection transaction-id)
  (define result
    (load-transaction-events connection transaction-id))
  (check-pred journal-load-succeeded? result)
  (journal-load-succeeded-events result))

(define (loaded-version connection transaction-id)
  (define result
    (load-transaction-events connection transaction-id))
  (check-pred journal-load-succeeded? result)
  (journal-load-succeeded-version result))

(define (loaded-receipt connection command-id)
  (define result
    (load-transaction-command-receipt connection command-id))
  (check-pred receipt-load-found? result)
  (receipt-load-found-receipt result))

(define (mark-receipt-as-pre-v9! connection command-id)
  (db:query-exec
   connection
   "INSERT INTO transaction_command_legacy_unattributed_receipts (command_id) VALUES (?)"
   command-id))

(define (resolved-receipt result)
  (check-pred transaction-command-commit-resolved? result)
  (transaction-command-commit-resolved-receipt result))

(define (check-conflict-receipt receipt command actual-version)
  (check-equal? (transaction-command-receipt-command receipt) command)
  (check-equal? (transaction-command-receipt-outcome-kind receipt)
                'version-conflict)
  (check-equal? (transaction-command-receipt-outcome-code receipt)
                "stream_version_conflict")
  (check-equal?
   (transaction-command-receipt-outcome-stream-version receipt)
   actual-version))

(module+ test
  (test-case "commit plans reject contradictory outcome and event shapes"
    (define command
      (start-transaction-command "cmd-start" "txn-001" 0))
    (check-exn
     exn:fail:contract?
     (lambda ()
       (transaction-command-commit-plan
        command 0 'accepted "accepted" '())))
    (check-exn
     exn:fail:contract?
     (lambda ()
       (transaction-command-commit-plan
        command
        0
        'domain-rejected
        "invalid_transaction_state"
        (list (started "txn-001")))))
    (check-exn
     exn:fail:contract?
     (lambda ()
       (transaction-command-commit-plan
        command -1 'not-found "transaction_not_found" '())))
    (check-exn
     exn:fail:contract?
     (lambda ()
       (transaction-command-commit-plan
        command 0 'future-outcome "future" '()))))

  (test-case "unit of work owns and refuses a nested outer transaction"
    (call-with-store
     (lambda (connection)
       (define plan
         (transaction-command-commit-plan
          (start-transaction-command "cmd-nested" "txn-nested" 0)
          0
          'accepted
          "accepted"
          (list (started "txn-nested"))))
       (db:call-with-transaction
        connection
        (lambda ()
          (check-exn
           exn:fail:contract?
           (lambda ()
             (commit-transaction-command-outcome! connection plan))))
        #:option 'immediate)
       (check-equal?
        (db:query-value connection "SELECT COUNT(*) FROM transaction_events")
        0)
       (check-equal?
        (db:query-value
         connection
         "SELECT COUNT(*) FROM transaction_command_receipts")
        0))))

  (test-case "accepted events and receipt commit atomically"
    (call-with-store
     (lambda (connection)
       (append! connection "txn-001" 0 (list (started "txn-001")))
       (define command
         (scan-barcode-command
          "cmd-scan" "txn-001" 1 "049000001234"))
       (define result
         (commit-transaction-command-outcome!
          connection
          (transaction-command-commit-plan
           command 1 'accepted "accepted" (list apples))))
       (define receipt (resolved-receipt result))

       (check-equal? receipt
                     (transaction-command-receipt
                      command 'accepted "accepted" 2))
       (check-equal? (loaded-events connection "txn-001")
                     (list (started "txn-001") apples))
       (check-equal? (loaded-receipt connection "cmd-scan") receipt))))

  (test-case "deterministic domain rejection commits only its receipt"
    (call-with-store
     (lambda (connection)
       (append! connection "txn-rejected" 0
                (list (started "txn-rejected")))
       (define command
         (scan-barcode-command
          "cmd-rejected" "txn-rejected" 1 "000000000000"))
       (define result
         (commit-transaction-command-outcome!
          connection
          (transaction-command-commit-plan
           command 1 'domain-rejected "unknown_barcode" '())))
       (define receipt (resolved-receipt result))

       (check-equal? receipt
                     (transaction-command-receipt
                      command 'domain-rejected "unknown_barcode" 1))
       (check-equal? (loaded-version connection "txn-rejected") 1)
       (check-equal? (loaded-events connection "txn-rejected")
                     (list (started "txn-rejected"))))))

  (test-case "not-found outcome persists at decision version zero"
    (call-with-store
     (lambda (connection)
       (define command
         (scan-barcode-command
          "cmd-not-found" "txn-missing" 5 "049000001234"))
       (define receipt
         (resolved-receipt
          (commit-transaction-command-outcome!
           connection
           (transaction-command-commit-plan
            command 0 'not-found "transaction_not_found" '()))))

       (check-equal? receipt
                     (transaction-command-receipt
                      command 'not-found "transaction_not_found" 0))
       (check-equal? (loaded-version connection "txn-missing") 0))))

  (test-case "already-exists uses the decision version, not expected version"
    (call-with-store
     (lambda (connection)
       (append! connection "txn-existing" 0
                (list (started "txn-existing") apples))
       (define command
         (start-transaction-command "cmd-existing" "txn-existing" 0))
       (define receipt
         (resolved-receipt
          (commit-transaction-command-outcome!
           connection
           (transaction-command-commit-plan
            command
            2
            'already-exists
            "transaction_already_exists"
            '()))))

       (check-equal? receipt
                     (transaction-command-receipt
                      command
                      'already-exists
                      "transaction_already_exists"
                      2))
       (check-equal? (loaded-version connection "txn-existing") 2))))

  (test-case "stale expected-version outcome persists when version is stable"
    (call-with-store
     (lambda (connection)
       (append! connection "txn-stale" 0
                (list (started "txn-stale") apples bananas))
       (define command
         (complete-transaction-command "cmd-stale" "txn-stale" 2))
       (define receipt
         (resolved-receipt
          (commit-transaction-command-outcome!
           connection
           (transaction-command-commit-plan
            command
            3
            'version-conflict
            "stale_expected_version"
            '()))))

       (check-equal? receipt
                     (transaction-command-receipt
                      command
                      'version-conflict
                      "stale_expected_version"
                      3))
       (check-equal? (loaded-version connection "txn-stale") 3))))

  (test-case "accepted provisional outcome is replaced after a version race"
    (call-with-store
     (lambda (connection)
       (append! connection "txn-race-accepted" 0
                (list (started "txn-race-accepted") bananas))
       (define command
         (scan-barcode-command
          "cmd-race-accepted"
          "txn-race-accepted"
          1
          "049000001234"))
       (define receipt
         (resolved-receipt
          (commit-transaction-command-outcome!
           connection
           (transaction-command-commit-plan
            command 1 'accepted "accepted" (list apples)))))

       (check-conflict-receipt receipt command 2)
       (check-equal? (loaded-events connection "txn-race-accepted")
                     (list (started "txn-race-accepted") bananas)))))

  (test-case "domain rejection is replaced after a version race"
    (call-with-store
     (lambda (connection)
       (append! connection "txn-race-rejection" 0
                (list (started "txn-race-rejection") bananas))
       (define command
         (scan-barcode-command
          "cmd-race-rejection"
          "txn-race-rejection"
          1
          "000000000000"))
       (define receipt
         (resolved-receipt
          (commit-transaction-command-outcome!
           connection
           (transaction-command-commit-plan
            command 1 'domain-rejected "unknown_barcode" '()))))

       (check-conflict-receipt receipt command 2)
       (check-equal? (loaded-events connection "txn-race-rejection")
                     (list (started "txn-race-rejection") bananas)))))

  (test-case "not-found outcome is replaced when another writer creates stream"
    (call-with-store
     (lambda (connection)
       (append! connection "txn-race-not-found" 0
                (list (started "txn-race-not-found")))
       (define command
         (scan-barcode-command
          "cmd-race-not-found"
          "txn-race-not-found"
          5
          "049000001234"))
       (define receipt
         (resolved-receipt
          (commit-transaction-command-outcome!
           connection
           (transaction-command-commit-plan
            command 0 'not-found "transaction_not_found" '()))))

       (check-conflict-receipt receipt command 1)
       (check-equal? (loaded-events connection "txn-race-not-found")
                     (list (started "txn-race-not-found"))))))

  (test-case "already-exists outcome is replaced when stream advances"
    (call-with-store
     (lambda (connection)
       (append! connection "txn-race-existing" 0
                (list (started "txn-race-existing") apples bananas tendered))
       (define command
         (start-transaction-command
          "cmd-race-existing" "txn-race-existing" 0))
       (define receipt
         (resolved-receipt
          (commit-transaction-command-outcome!
           connection
           (transaction-command-commit-plan
            command
            3
            'already-exists
            "transaction_already_exists"
            '()))))

       (check-conflict-receipt receipt command 4)
       (check-equal? (loaded-version connection "txn-race-existing") 4))))

  (test-case "same-command retry returns its unchanged existing receipt"
    (call-with-store
     (lambda (connection)
       (append! connection "txn-duplicate" 0
                (list (started "txn-duplicate")))
       (define command
         (scan-barcode-command
          "cmd-duplicate" "txn-duplicate" 1 "049000001234"))
       (define original
         (transaction-command-receipt command 'accepted "accepted" 2))
       (check-pred
        receipt-insert-succeeded?
        (insert-transaction-command-receipt! connection original))
       (mark-receipt-as-pre-v9! connection "cmd-duplicate")

       (define result
         (commit-transaction-command-outcome!
          connection
          (transaction-command-commit-plan
           command 1 'accepted "accepted" (list apples))))

       (check-equal? (resolved-receipt result) original)
       (check-equal? (loaded-events connection "txn-duplicate")
                     (list (started "txn-duplicate")))
       (check-equal? (loaded-receipt connection "cmd-duplicate") original))))

  (test-case "delayed same-command retry is resolved before stream inspection"
    (call-with-store
     (lambda (connection)
       (append! connection "txn-delayed" 0
                (list (started "txn-delayed") apples bananas tendered))
       (define command
         (scan-barcode-command
          "cmd-delayed" "txn-delayed" 1 "049000001234"))
       (define original
         (transaction-command-receipt command 'accepted "accepted" 2))
       (insert-transaction-command-receipt! connection original)
       (mark-receipt-as-pre-v9! connection "cmd-delayed")

       (define result
         (commit-transaction-command-outcome!
          connection
          (transaction-command-commit-plan
           command 1 'accepted "accepted" (list apples))
          #:stream-version
          (lambda (_connection _transaction-id)
            (error 'test "duplicate retry inspected current stream"))))

       (check-equal? (resolved-receipt result) original)
       (check-equal? (loaded-version connection "txn-delayed") 4))))

  (test-case "same command ID with different typed command is rejected"
    (call-with-store
     (lambda (connection)
       (append! connection "txn-reuse" 0 (list (started "txn-reuse")))
       (define original-command
         (scan-barcode-command
          "cmd-reuse" "txn-reuse" 1 "049000001234"))
       (define original-receipt
         (transaction-command-receipt
          original-command 'accepted "accepted" 2))
       (insert-transaction-command-receipt! connection original-receipt)
       (mark-receipt-as-pre-v9! connection "cmd-reuse")
       (define reused-command
         (scan-barcode-command
          "cmd-reuse" "txn-reuse" 1 "000000000002"))

       (define result
         (commit-transaction-command-outcome!
          connection
          (transaction-command-commit-plan
           reused-command 1 'accepted "accepted" (list bananas))))

       (check-pred transaction-command-commit-id-reused? result)
       (check-equal?
        (transaction-command-commit-id-reused-command-id result)
        "cmd-reuse")
       (check-equal? (loaded-receipt connection "cmd-reuse")
                     original-receipt)
       (check-equal? (loaded-events connection "txn-reuse")
                     (list (started "txn-reuse"))))))

  (test-case "corrupt existing receipt fails closed before event append"
    (call-with-store
     (lambda (connection)
       (append! connection "txn-corrupt" 0
                (list (started "txn-corrupt")))
       (define command
         (scan-barcode-command
          "cmd-corrupt" "txn-corrupt" 1 "049000001234"))
       (insert-transaction-command-receipt!
        connection
        (transaction-command-receipt command 'accepted "accepted" 2))
       (db:query-exec connection "PRAGMA ignore_check_constraints = ON")
       (db:query-exec
        connection
        #<<SQL
UPDATE transaction_command_receipts
SET outcome_code = ''
WHERE command_id = 'cmd-corrupt'
SQL
        )

       (define result
         (commit-transaction-command-outcome!
          connection
          (transaction-command-commit-plan
           command 1 'accepted "accepted" (list apples))))

       (check-pred transaction-command-commit-failed? result)
       (check-equal? (transaction-command-commit-failed-code result)
                     'receipt-load-failure)
       (check-equal? (transaction-command-commit-failed-detail result)
                     'invalid-outcome-code)
       (check-equal? (loaded-events connection "txn-corrupt")
                     (list (started "txn-corrupt")))
       (check-pred
        receipt-load-failed?
        (load-transaction-command-receipt connection "cmd-corrupt")))))

  (test-case "receipt conflict after event append rolls back both writes"
    (call-with-store
     (lambda (connection)
       (append! connection "txn-receipt-failure" 0
                (list (started "txn-receipt-failure")))
       (define command
         (scan-barcode-command
          "cmd-receipt-failure"
          "txn-receipt-failure"
          1
          "049000001234"))
       (define (conflicting-insert connection* receipt)
         (check-pred
          receipt-insert-succeeded?
          (insert-transaction-command-receipt! connection* receipt))
         (insert-transaction-command-receipt! connection* receipt))

       (define result
         (commit-transaction-command-outcome!
          connection
          (transaction-command-commit-plan
           command 1 'accepted "accepted" (list apples))
          #:insert-receipt! conflicting-insert))

       (check-pred transaction-command-commit-failed? result)
       (check-equal? (transaction-command-commit-failed-code result)
                     'receipt-insert-conflict)
       (check-equal? (loaded-events connection "txn-receipt-failure")
                     (list (started "txn-receipt-failure")))
       (check-pred
        receipt-load-not-found?
        (load-transaction-command-receipt
         connection "cmd-receipt-failure")))))

  (test-case "event append rejection never commits an accepted receipt"
    (call-with-store
     (lambda (connection)
       (define command
         (start-transaction-command "cmd-bad-event" "txn-A" 0))
       (define result
         (commit-transaction-command-outcome!
          connection
          (transaction-command-commit-plan
           command
           0
           'accepted
           "accepted"
           (list (started "txn-B")))))

       (check-pred transaction-command-commit-failed? result)
       (check-equal? (transaction-command-commit-failed-code result)
                     'event-append-rejected)
       (check-equal? (transaction-command-commit-failed-detail result)
                     'stream-identity-mismatch)
       (check-equal?
        (db:query-value connection "SELECT COUNT(*) FROM transaction_events")
        0)
       (check-pred
        receipt-load-not-found?
        (load-transaction-command-receipt connection "cmd-bad-event")))))

  (test-case "SQLite failure during multi-event append rolls back receipt too"
    (call-with-store
     (lambda (connection)
       (append! connection "txn-event-failure" 0
                (list (started "txn-event-failure")))
       (db:query-exec
        connection
        #<<SQL
CREATE TRIGGER reject_test_cash_event_for_command
BEFORE INSERT ON transaction_events
WHEN NEW.event_type = 'cash_tendered'
BEGIN
  SELECT RAISE(ABORT, 'deterministic unit-of-work event failure');
END
SQL
        )
       (define command
         (scan-barcode-command
          "cmd-event-failure"
          "txn-event-failure"
          1
          "049000001234"))

       (check-exn
        db:exn:fail:sql?
        (lambda ()
          (commit-transaction-command-outcome!
           connection
           (transaction-command-commit-plan
            command
            1
            'accepted
            "accepted"
            (list apples tendered completed)))))
       (check-equal? (loaded-events connection "txn-event-failure")
                     (list (started "txn-event-failure")))
       (check-pred
        receipt-load-not-found?
        (load-transaction-command-receipt connection "cmd-event-failure")))))

  (test-case "accepted multi-event plan commits all events and one receipt"
    (call-with-store
     (lambda (connection)
       (define command
         (start-transaction-command "cmd-cash-sale" "txn-cash-sale" 0))
       (define events
         (list (started "txn-cash-sale") apples tendered completed))
       (define receipt
         (resolved-receipt
          (commit-transaction-command-outcome!
           connection
           (transaction-command-commit-plan
            command 0 'accepted "accepted" events))))

       (check-equal? (loaded-events connection "txn-cash-sale") events)
       (check-equal?
        (transaction-command-receipt-outcome-stream-version receipt)
        4)
       (check-equal?
        (db:query-value
         connection
         "SELECT COUNT(*) FROM transaction_command_receipts")
        1))))

  (test-case "events and receipt survive a file-backed restart together"
    (define database-path
      (make-temporary-file "grocery-pos-command-uow-~a.sqlite"))
    (define command
      (start-transaction-command "cmd-restart" "txn-restart" 0))
    (define events
      (list (started "txn-restart") apples tendered completed))
    (dynamic-wind
      void
      (lambda ()
        (define writer
          (db:sqlite3-connect #:database database-path #:mode 'create))
        (dynamic-wind
          void
          (lambda ()
            (migrate-pos-database! writer)
            (seed-file-backed-actor! writer)
            (check-pred
             transaction-command-commit-resolved?
             (commit-transaction-command-outcome!
              writer
              (transaction-command-commit-plan
               command 0 'accepted "accepted" events))))
          (lambda () (db:disconnect writer)))

        (define reader
          (db:sqlite3-connect #:database database-path #:mode 'read/write))
        (dynamic-wind
          void
          (lambda ()
            (migrate-pos-database! reader)
            (check-equal? (loaded-events reader "txn-restart") events)
            (check-equal?
             (loaded-receipt reader "cmd-restart")
             (transaction-command-receipt
              command 'accepted "accepted" 4)))
          (lambda () (db:disconnect reader))))
      (lambda ()
        (when (file-exists? database-path)
          (delete-file database-path)))))

  (test-case "stale actor waiting for writer cannot commit after credential revision changes"
    (define directory
      (make-temporary-file "grocery-pos-credential-race-~a" 'directory))
    (dynamic-wind
      void
      (lambda ()
        (define path (build-path directory "pos.db"))
        (define holder (open-pos-sqlite-connection path 'create))
        (define contender (open-pos-sqlite-connection path 'read/write))
        (dynamic-wind
          void
          (lambda ()
            (migrate-pos-database! holder)
            (seed-file-backed-actor! holder)
            (define command
              (start-transaction-command
               "cmd-credential-race" "txn-credential-race" 0))
            (define (plan revision)
              (transaction-command-commit-plan-with-actor
               (transaction-command-commit-plan/without-actor
                command 0 'accepted "accepted"
                (list (started "txn-credential-race")))
               "unit-of-work-test-operator" revision))
            (define started-channel (make-channel))
            (define result-channel (make-channel))
            (db:call-with-transaction
             holder
             (lambda ()
               (thread
                (lambda ()
                  (channel-put started-channel #t)
                  (channel-put
                   result-channel
                   (with-handlers ([exn:fail? values])
                     (commit-transaction-command-outcome!
                      contender (plan 1))))))
               (channel-get started-channel)
               ;; This models the root rotation committing while an already
               ;; authenticated rev-1 command is waiting for the writer.
               (db:query-exec
                holder
                "UPDATE operator_pin_credentials SET credential_revision = 2 WHERE operator_id = 'unit-of-work-test-operator'"))
             #:option 'immediate)
            (check-pred transaction-command-commit-authorization-denied?
                        (channel-get result-channel))
            (check-equal?
             (db:query-value holder
                             "SELECT COUNT(*) FROM transaction_command_receipts")
             0)
            (check-equal?
             (db:query-value holder "SELECT COUNT(*) FROM transaction_events")
             0)
            (check-equal?
             (db:query-value holder
                             "SELECT COUNT(*) FROM transaction_command_actor_attributions")
             0)
            (check-pred transaction-command-commit-resolved?
                        (commit-transaction-command-outcome!
                         contender (plan 2)))
            ;; A later credential rotation does not rewrite history: a
            ;; currently authenticated same actor still recovers the exact
            ;; durable command before fresh writer authorization is evaluated.
            (db:query-exec
             holder
             "UPDATE operator_pin_credentials SET credential_revision = 3 WHERE operator_id = 'unit-of-work-test-operator'")
            (check-pred transaction-command-commit-resolved?
                        (commit-transaction-command-outcome!
                         contender (plan 3)))
            (check-equal?
             (db:query-value holder "SELECT COUNT(*) FROM transaction_events") 1)
            (check-equal?
             (db:query-value holder
                             "SELECT COUNT(*) FROM transaction_command_receipts")
             1))
          (lambda ()
            (db:disconnect contender)
            (db:disconnect holder))))
      (lambda () (delete-directory/files directory))))

  (test-case "second connection cannot see command writes before outer commit"
    (define database-path
      (make-temporary-file "grocery-pos-command-visibility-~a.sqlite"))
    (dynamic-wind
      void
      (lambda ()
        (define writer
          (db:sqlite3-connect #:database database-path #:mode 'create))
        (define reader
          (db:sqlite3-connect #:database database-path #:mode 'read/write))
        (dynamic-wind
          void
          (lambda ()
            (migrate-pos-database! writer)
            (seed-file-backed-actor! writer)
            (define command
              (start-transaction-command
               "cmd-visibility" "txn-visibility" 0))
            (define (observing-insert connection receipt)
              (define result
                (insert-transaction-command-receipt! connection receipt))
              (check-equal?
               (db:query-value reader "SELECT COUNT(*) FROM transaction_events")
               0)
              (check-equal?
               (db:query-value
                reader
                "SELECT COUNT(*) FROM transaction_command_receipts")
               0)
              result)

            (check-pred
             transaction-command-commit-resolved?
             (commit-transaction-command-outcome!
              writer
              (transaction-command-commit-plan
               command
               0
               'accepted
               "accepted"
               (list (started "txn-visibility")))
              #:insert-receipt! observing-insert))
            (check-equal?
             (db:query-value reader "SELECT COUNT(*) FROM transaction_events")
             1)
            (check-equal?
             (db:query-value
              reader
              "SELECT COUNT(*) FROM transaction_command_receipts")
             1))
          (lambda ()
            (db:disconnect reader)
            (db:disconnect writer))))
      (lambda ()
        (when (file-exists? database-path)
          (delete-file database-path))))))
