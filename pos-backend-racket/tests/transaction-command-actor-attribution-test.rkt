#lang racket

(require (prefix-in db: db)
         rackunit
         "../pos/application/transaction-command-receipt.rkt"
         "../pos/application/transaction-command.rkt"
         "../pos/domain/transaction-command-actor-attribution.rkt"
         "../pos/domain/transaction-event.rkt"
         "../pos/persistence/pos-database-migrations.rkt"
         "../pos/persistence/transaction-command-actor-attribution-store.rkt"
         "../pos/persistence/transaction-command-receipt-store.rkt"
         "../pos/persistence/transaction-command-unit-of-work.rkt")

(define (call-with-database proc)
  (define connection (db:sqlite3-connect #:database 'memory))
  (dynamic-wind
    (lambda ()
      (db:query-exec connection "PRAGMA foreign_keys = ON")
      (migrate-pos-database! connection)
      (for ([id (in-list '("Alice" "Bob"))])
        (db:query-exec connection "INSERT INTO operators VALUES (?, ?, 1)" id id)
        (db:query-exec connection "INSERT INTO operator_roles VALUES (?, 'cashier')" id)
        (db:query-exec connection
                       "INSERT INTO operator_pin_credentials VALUES (?, '$argon2id$fixture', 1)"
                       id)))
    (lambda () (proc connection))
    (lambda () (db:disconnect connection))))

(define (accepted-plan command)
  (transaction-command-commit-plan-with-actor
   (transaction-command-commit-plan
    command 0 'accepted "accepted"
    (list (transaction-started
           (transaction-command-transaction-id command))))
   "Alice" 1))

(module+ test
  (test-case "actor attribution store round trips opaque case-sensitive IDs"
    (call-with-database
     (lambda (connection)
       (define command (start-transaction-command "cmd-actor" "txn-actor" 0))
       (insert-transaction-command-receipt!
        connection
        (transaction-command-receipt command 'accepted "accepted" 1))
       (define attribution
         (transaction-command-actor-attribution "cmd-actor" "Alice-A"))
       (insert-transaction-command-actor-attribution! connection attribution)
       (check-equal?
        (load-transaction-command-actor-attribution connection "cmd-actor")
        attribution)
       (check-false
        (load-transaction-command-actor-attribution connection "missing")))))

  (test-case "fresh command receipt and actor attribution commit atomically"
    (call-with-database
     (lambda (connection)
       (define command (start-transaction-command "cmd-fresh" "txn-fresh" 0))
       (check-pred
        transaction-command-commit-resolved?
        (commit-transaction-command-outcome!
         connection (accepted-plan command)))
       (check-equal?
        (load-transaction-command-actor-attribution connection "cmd-fresh")
        (transaction-command-actor-attribution "cmd-fresh" "Alice")))))

  (test-case "every fresh durable receipt outcome receives one actor"
    (call-with-database
     (lambda (connection)
       (for ([entry
              (in-list
               '(("cmd-domain" "txn-domain" domain-rejected "invalid_state")
                 ("cmd-missing" "txn-missing" not-found "transaction_not_found")
                 ("cmd-version" "txn-version" version-conflict "stale_expected_version")))])
         (define command
           (start-transaction-command (first entry) (second entry) 0))
         (define plan
           (transaction-command-commit-plan-with-actor
            (transaction-command-commit-plan
             command 0 (third entry) (fourth entry) '())
            "Alice" 1))
         (check-pred
          transaction-command-commit-resolved?
          (commit-transaction-command-outcome! connection plan))
         (check-equal?
          (load-transaction-command-actor-attribution
           connection (first entry))
          (transaction-command-actor-attribution (first entry) "Alice")))
       (check-equal?
        (db:query-value
         connection
         "SELECT COUNT(*) FROM transaction_command_actor_attributions")
        3))))

  (test-case "attribution failure rolls back event and receipt"
    (call-with-database
     (lambda (connection)
       (define command (start-transaction-command "cmd-fail" "txn-fail" 0))
       (check-exn
        exn:fail?
        (lambda ()
          (commit-transaction-command-outcome!
           connection
           (accepted-plan command)
           #:insert-attribution!
           (lambda (_connection _attribution)
             (error 'test "simulated attribution failure")))))
       (check-equal? (db:query-value connection "SELECT COUNT(*) FROM transaction_events") 0)
       (check-equal? (db:query-value connection "SELECT COUNT(*) FROM transaction_command_receipts") 0)
       (check-equal? (db:query-value connection "SELECT COUNT(*) FROM transaction_command_actor_attributions") 0))))

  (test-case "same actor recovers and different actor is denied before payload comparison"
    (call-with-database
     (lambda (connection)
       (define command (start-transaction-command "cmd-retry" "txn-retry" 0))
       (check-pred transaction-command-commit-resolved?
                   (commit-transaction-command-outcome!
                    connection (accepted-plan command)))
       (check-pred transaction-command-commit-resolved?
                   (commit-transaction-command-outcome!
                    connection (accepted-plan command)))
       (define bob-plan
         (transaction-command-commit-plan-with-actor
          (transaction-command-commit-plan
           (start-transaction-command "cmd-retry" "txn-different" 0)
           0 'already-exists "transaction_already_exists" '())
          "Bob" 1))
       (check-pred transaction-command-commit-authorization-denied?
                   (commit-transaction-command-outcome! connection bob-plan))
       (check-equal?
        (transaction-command-actor-attribution-operator-id
         (load-transaction-command-actor-attribution connection "cmd-retry"))
        "Alice"))))

  (test-case "modern receipt with missing actor fails closed for every operator"
    (call-with-database
     (lambda (connection)
       (define command (start-transaction-command "cmd-modern" "txn-modern" 0))
       (check-pred
        transaction-command-commit-resolved?
        (commit-transaction-command-outcome!
         connection (accepted-plan command)))
       (db:query-exec
        connection
        "DELETE FROM transaction_command_actor_attributions WHERE command_id = 'cmd-modern'")
       (check-pred
        transaction-command-commit-authorization-denied?
        (commit-transaction-command-outcome!
         connection (accepted-plan command)))
       (check-pred
        transaction-command-commit-authorization-denied?
        (commit-transaction-command-outcome!
         connection
         (transaction-command-commit-plan-with-actor
          (transaction-command-commit-plan
           command 0 'accepted "accepted"
           (list (transaction-started "txn-modern")))
          "Bob" 1)))
       (check-false
        (load-transaction-command-actor-attribution connection "cmd-modern"))
       (check-equal?
        (db:query-value
         connection
         "SELECT COUNT(*) FROM transaction_events WHERE transaction_id = 'txn-modern'")
        1)
       (check-exn
        exn:fail?
        (lambda ()
          (validate-pos-database-schema!
           connection #:require-current? #t)))))))
