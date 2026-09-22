#lang racket

(require (prefix-in db: db)
         rackunit
         "../pos/application/authentication-service.rkt"
         "../pos/application/transaction-command-receipt.rkt"
         "../pos/application/transaction-command.rkt"
         "../pos/application/transaction-service.rkt"
         "../pos/domain/fake-catalog.rkt"
         "../pos/domain/money.rkt"
         "../pos/domain/register-operations.rkt"
         "../pos/domain/transaction-command-actor-attribution.rkt"
         "../pos/domain/transaction-event.rkt"
         "../pos/persistence/pos-database-migrations.rkt"
         "../pos/persistence/sqlite-register-operations.rkt"
         "../pos/persistence/sqlite-transaction-event-store.rkt"
         "../pos/persistence/transaction-command-actor-attribution-store.rkt")

(define alice (authenticated-operator "Alice" "Alice" 'cashier))
(define alice-as-manager (authenticated-operator "Alice" "Alice" 'manager))
(define bob (authenticated-operator "Bob" "Bob" 'cashier))
(define sam (authenticated-operator "Sam" "Sam" 'supervisor))
(define morgan (authenticated-operator "Morgan" "Morgan" 'manager))

(define (call-with-service proc)
  (define connection (db:sqlite3-connect #:database 'memory))
  (dynamic-wind
    (lambda ()
      (db:query-exec connection "PRAGMA foreign_keys = ON")
      (migrate-pos-database! connection)
      (db:query-exec
       connection
       "INSERT INTO register_configuration VALUES (1, 'register-1', 'Register 1')")
      (db:query-exec
       connection
       "INSERT INTO cashiers VALUES ('Alice', 'Alice', 1), ('Bob', 'Bob', 1), ('Sam', 'Sam', 1), ('Morgan', 'Morgan', 1)")
      (check-pred
       register-shift-opened?
       (open-register-shift!
        connection "Alice" (money 1000) (lambda () 1000)
        (lambda () "shift-alice"))))
    (lambda ()
      (proc connection
            (make-transaction-service
             connection
             #:catalog-lookup fake-catalog-lookup
             #:current-epoch-ms (lambda () 2000))))
    (lambda () (db:disconnect connection))))

(define (resolved? result)
  (transaction-service-command-resolved? result))

(module+ test
  (test-case "fresh commands require the active shift owner for every role"
    (call-with-service
     (lambda (connection service)
       (define start
         (start-transaction-command "cmd-alice-start" "txn-alice" 0))
       (check-true (resolved? (transaction-service-execute-command service alice start)))
       (for ([principal (in-list (list bob sam morgan))]
             [command-id (in-list '("cmd-bob" "cmd-sam" "cmd-morgan"))])
         (check-pred
          transaction-service-authorization-denied?
          (transaction-service-execute-command
           service principal
           (scan-barcode-command command-id "txn-alice" 1 "049000001234"))))
       (check-equal?
        (db:query-value
         connection
         "SELECT COUNT(*) FROM transaction_command_receipts WHERE command_id IN ('cmd-bob', 'cmd-sam', 'cmd-morgan')")
        0))))

  (test-case "reads use durable ownership while supervisor and manager have read-any"
    (call-with-service
     (lambda (_connection service)
       (check-true
        (resolved?
         (transaction-service-execute-command
          service alice
          (start-transaction-command "cmd-read-start" "txn-read" 0))))
       (check-pred transaction-service-success?
                   (transaction-service-load-transaction service alice "txn-read"))
       (check-pred transaction-service-not-found?
                   (transaction-service-load-transaction service bob "txn-read"))
       (check-pred transaction-service-success?
                   (transaction-service-load-transaction service sam "txn-read"))
       (check-pred transaction-service-success?
                   (transaction-service-load-transaction service morgan "txn-read")))))

  (test-case "a contextless historical transaction has no provable cashier owner"
    (call-with-service
     (lambda (connection service)
       (check-pred
        journal-append-succeeded?
        (append-transaction-events!
         connection
         "txn-historical"
         0
         (list (transaction-started "txn-historical"))))
       (check-pred
        transaction-service-not-found?
        (transaction-service-load-transaction service alice "txn-historical"))
       (check-pred
        transaction-service-success?
        (transaction-service-load-transaction service sam "txn-historical"))
       (check-pred
        transaction-service-success?
        (transaction-service-load-transaction service morgan "txn-historical")))))

  (test-case "whole-sale void remains an own-transaction operation until CP4"
    (call-with-service
     (lambda (connection service)
       (check-true
        (resolved?
         (transaction-service-execute-command
          service
          alice
          (start-transaction-command "cmd-own-void-start" "txn-own-void" 0))))
       (check-true
        (resolved?
         (transaction-service-execute-command
          service
          alice
          (void-transaction-command "cmd-own-void" "txn-own-void" 1))))
       (check-equal?
        (db:query-value
         connection
         "SELECT outcome_code FROM transaction_command_receipts WHERE command_id = 'cmd-own-void'")
        "accepted"))))

  (test-case "attributed retry is same-operator across role change and opaque cross-operator"
    (call-with-service
     (lambda (connection service)
       (define command
         (start-transaction-command "cmd-recover" "txn-recover" 0))
       (check-true (resolved? (transaction-service-execute-command service alice command)))
       (check-true
        (resolved?
         (transaction-service-execute-command service alice-as-manager command)))
       (check-pred
        transaction-service-authorization-denied?
        (transaction-service-execute-command service bob command))
       (check-pred
        transaction-service-authorization-denied?
        (transaction-service-execute-command
         service bob
         (start-transaction-command "cmd-recover" "different-transaction" 0)))
       (check-equal?
        (transaction-command-actor-attribution-operator-id
         (load-transaction-command-actor-attribution connection "cmd-recover"))
        "Alice"))))

  (test-case "legacy unattributed exact receipt remains recoverable without attribution"
    (call-with-service
     (lambda (connection service)
       (db:query-exec
        connection
        "DROP TABLE transaction_command_actor_attributions")
       (db:query-exec
        connection
        "DROP TABLE transaction_command_legacy_unattributed_receipts")
       (db:query-exec
        connection
        "DELETE FROM pos_schema_migrations WHERE version = 9")
       (db:query-exec
        connection
        #<<SQL
INSERT INTO operators (operator_id, display_name, active)
SELECT cashier_id, display_name, active
FROM cashiers
WHERE cashier_id NOT IN (SELECT operator_id FROM operators)
SQL
        )
       (db:query-exec
        connection
        #<<SQL
INSERT INTO operator_roles (operator_id, role)
SELECT cashier_id, 'cashier'
FROM cashiers
WHERE cashier_id NOT IN (SELECT operator_id FROM operator_roles)
SQL
        )
       (define command
         (start-transaction-command "cmd-legacy-service" "txn-legacy-service" 0))
       (db:query-exec
        connection
        #<<SQL
INSERT INTO transaction_command_receipts
  (command_id, transaction_id, command_schema_version, command_type,
   expected_version, command_json, outcome_kind, outcome_code,
   outcome_stream_version)
VALUES
  ('cmd-legacy-service', 'txn-legacy-service', 1, 'start_transaction', 0,
   '{"schema_version":1,"command_id":"cmd-legacy-service","transaction_id":"txn-legacy-service","expected_version":0,"command_type":"start_transaction","payload":{}}',
   'accepted', 'accepted', 1)
SQL
        )
       (migrate-pos-database! connection)
       (check-true
        (resolved?
         (transaction-service-execute-command service bob command)))
       (check-false
        (load-transaction-command-actor-attribution
         connection "cmd-legacy-service"))
       (check-equal?
        (db:query-value
         connection
         "SELECT COUNT(*) FROM transaction_command_legacy_unattributed_receipts WHERE command_id = 'cmd-legacy-service'")
        1))))

  (test-case "missing actor on a modern receipt never falls back to legacy recovery"
    (call-with-service
     (lambda (connection service)
       (define command
         (start-transaction-command "cmd-modern-missing" "txn-modern-missing" 0))
       (check-true
        (resolved?
         (transaction-service-execute-command service alice command)))
       (db:query-exec
        connection
        "DELETE FROM transaction_command_actor_attributions WHERE command_id = 'cmd-modern-missing'")
       (check-pred
        transaction-service-authorization-denied?
        (transaction-service-execute-command service alice command))
       (check-pred
        transaction-service-authorization-denied?
        (transaction-service-execute-command service bob command))
       (check-pred
        transaction-service-authorization-denied?
        (transaction-service-execute-command
         service bob
         (start-transaction-command
          "cmd-modern-missing" "txn-secret-different" 0)))
       (check-equal?
        (db:query-value
         connection
         "SELECT COUNT(*) FROM transaction_command_legacy_unattributed_receipts WHERE command_id = 'cmd-modern-missing'")
        0)))))
