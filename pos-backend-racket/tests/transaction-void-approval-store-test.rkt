#lang racket

(require db
         rackunit
         "../pos/application/transaction-command.rkt"
         "../pos/domain/transaction-void-approval.rkt"
         "../pos/persistence/pos-database-migrations.rkt"
         "../pos/persistence/transaction-void-approval-store.rkt"
         "../pos/security/transaction-void-approval.rkt")

(define credential-hash
  "$argon2id$v=19$m=19456,t=2,p=1$c2FsdHNhbHQ$ZGlnaWVzdGRpZ2VzdA")

(define (call-with-database procedure)
  (define connection (sqlite3-connect #:database 'memory))
  (dynamic-wind
    void
    (lambda ()
      (query-exec connection "PRAGMA foreign_keys = ON")
      (migrate-pos-database! connection)
      (for ([row (in-list
                  '(("Alice" "Alice" "cashier")
                    ("Sam" "Sam" "supervisor")
                    ("Morgan" "Morgan" "manager")))])
        (query-exec
         connection
         "INSERT INTO operators VALUES (?, ?, 1)"
         (first row) (second row))
        (query-exec
         connection
         "INSERT INTO operator_roles VALUES (?, ?)"
         (first row) (third row))
        (query-exec
         connection
         "INSERT INTO operator_pin_credentials VALUES (?, ?, 1)"
         (first row) credential-hash))
      (procedure connection))
    (lambda () (disconnect connection))))

(define capability
  (transaction-void-approval-token->capability
   (string-append "gpos_a1_" (make-string 64 #\a))))

(define (grant #:approval-id [approval-id "approval-1"]
               #:issuer [issuer "instance-1"]
               #:requester [requester "Alice"]
               #:approver [approver "Sam"]
               #:revision [revision 1]
               #:command-id [command-id "cmd-void"]
               #:transaction-id [transaction-id "txn-1"]
               #:expected-version [expected-version 3]
               #:granted [granted 1000]
               #:expires [expires 91000]
               #:epoch-expires [epoch-expires 590000])
  (transaction-void-approval-grant
   approval-id
   (transaction-void-approval-capability-token-digest capability)
   issuer
   requester
   approver
   revision
   command-id
   transaction-id
   1
   expected-version
   granted
   expires
   epoch-expires))

(define command
  (void-transaction-command "cmd-void" "txn-1" 3))

(define (replace-grant! connection value [now 1000])
  (call-with-transaction
   connection
   (lambda ()
     (replace-transaction-void-approval-grant!/in-transaction!
      connection value "instance-1" now))
   #:option 'immediate))

(define (consume! connection
                  #:capability [provided capability]
                  #:issuer [issuer "instance-1"]
                  #:requester [requester "Alice"]
                  #:provided-command [provided-command command]
                  #:now [now 2000])
  (call-with-transaction
   connection
   (lambda ()
     (consume-transaction-void-approval!/in-transaction!
      connection provided issuer requester provided-command now))
   #:option 'immediate))

(module+ test
  (test-case "exact approval is consumed into immutable approver evidence"
    (call-with-database
     (lambda (connection)
       (replace-grant! connection (grant))
       (define consumed (consume! connection))
       (check-pred transaction-void-approval-consumed? consumed)
       (define attribution
         (transaction-void-approval-consumed-attribution consumed))
       (check-equal?
        (transaction-command-approver-attribution-command-id attribution)
        "cmd-void")
       (check-equal?
        (transaction-command-approver-attribution-approval-id attribution)
        "approval-1")
       (check-equal?
        (transaction-command-approver-attribution-approver-operator-id attribution)
        "Sam")
       (check-equal?
        (transaction-command-approver-attribution-approved-at-epoch-ms attribution)
        500000)
       (check-equal?
        (query-value connection "SELECT COUNT(*) FROM transaction_void_approval_grants")
        0))))

  (test-case "replacement invalidates the old token and preserves one exact grant"
    (call-with-database
     (lambda (connection)
       (replace-grant! connection (grant))
       (define replacement-capability
         (transaction-void-approval-token->capability
          (string-append "gpos_a1_" (make-string 64 #\b))))
       (replace-grant!
        connection
        (struct-copy
         transaction-void-approval-grant
         (grant #:approval-id "approval-2")
         [token-digest
          (transaction-void-approval-capability-token-digest
           replacement-capability)]))
       (check-equal?
        (query-value connection "SELECT COUNT(*) FROM transaction_void_approval_grants")
        1)
       (check-pred transaction-void-approval-rejected?
                   (consume! connection))
       (check-pred
        transaction-void-approval-consumed?
        (consume! connection #:capability replacement-capability)))))

  (test-case "replacement cannot silently change an existing command's scope"
    (for ([changed (in-list
                    (list (grant #:approval-id "approval-2"
                                 #:transaction-id "txn-2")
                          (grant #:approval-id "approval-2"
                                 #:expected-version 4)
                          (grant #:approval-id "approval-2"
                                 #:requester "Morgan")))])
      (call-with-database
       (lambda (connection)
         (replace-grant! connection (grant))
         (check-false (replace-grant! connection changed))
         (check-equal?
          (query-value connection
                       "SELECT approval_id FROM transaction_void_approval_grants WHERE command_id = 'cmd-void'")
          "approval-1")
         (check-pred transaction-void-approval-consumed?
                     (consume! connection))))))

  (test-case "requester must remain active and authorized at grant consumption"
    (for ([mutate (in-list
                   (list
                    (lambda (connection)
                      (query-exec connection
                                  "UPDATE operators SET active = 0 WHERE operator_id = 'Alice'"))
                    (lambda (connection)
                      (query-exec connection
                                  "DELETE FROM operator_roles WHERE operator_id = 'Alice'"))))])
      (call-with-database
       (lambda (connection)
         (replace-grant! connection (grant))
         (mutate connection)
         (check-pred transaction-void-approval-rejected?
                     (consume! connection))
         (check-equal?
          (query-value connection
                       "SELECT COUNT(*) FROM transaction_void_approval_grants")
          1)))))

  (test-case "grant scope, monotonic expiry, process instance, and live privilege fail closed"
    (for ([mutate (in-list
                   (list
                    (lambda (_connection) (void))
                    (lambda (connection)
                      (query-exec connection
                                  "UPDATE operator_roles SET role = 'cashier' WHERE operator_id = 'Sam'"))
                    (lambda (connection)
                      (query-exec connection
                                  "UPDATE operators SET active = 0 WHERE operator_id = 'Sam'"))
                    (lambda (connection)
                      (query-exec connection
                                  "UPDATE operator_pin_credentials SET credential_revision = 2 WHERE operator_id = 'Sam'"))))]
          [scenario (in-list '(expired demoted disabled revision-changed))])
      (call-with-database
       (lambda (connection)
         (replace-grant! connection (grant))
         (mutate connection)
         (define result
           (case scenario
             [(expired) (consume! connection #:now 91000)]
             [else (consume! connection)]))
         (check-pred transaction-void-approval-rejected? result))))
    (call-with-database
     (lambda (connection)
       (replace-grant! connection (grant))
       (check-pred transaction-void-approval-rejected?
                   (consume! connection #:issuer "new-instance"))))
    (call-with-database
     (lambda (connection)
       (replace-grant! connection (grant))
       (check-pred transaction-void-approval-rejected?
                   (consume! connection #:requester "Morgan"))))
    (call-with-database
     (lambda (connection)
       (replace-grant! connection (grant))
       (check-pred
        transaction-void-approval-rejected?
        (consume!
         connection
         #:provided-command
         (void-transaction-command "cmd-void" "txn-1" 4))))))

  (test-case "approver and legacy provenance stores remain disjoint"
    (call-with-database
     (lambda (connection)
       (query-exec
        connection
        #<<SQL
INSERT INTO transaction_command_receipts
  (command_id, transaction_id, command_schema_version, command_type,
   expected_version, command_json, outcome_kind, outcome_code,
   outcome_stream_version)
VALUES
  ('cmd-modern', 'txn-1', 1, 'void_transaction', 3,
   '{"schema_version":1,"command_id":"cmd-modern","transaction_id":"txn-1","expected_version":3,"command_type":"void_transaction","payload":{}}',
   'accepted', 'accepted', 4)
SQL
        )
       (define attribution
         (transaction-command-approver-attribution
          "cmd-modern" "approval-modern" "Morgan" 1 500000))
       (insert-transaction-command-approver-attribution!
        connection attribution)
       (check-equal?
        (load-transaction-command-approver-attribution
         connection "cmd-modern")
        attribution)
       (check-false
        (transaction-command-receipt-legacy-unapproved-void?
         connection "cmd-modern"))))))
