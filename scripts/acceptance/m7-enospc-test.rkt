#lang racket

(require (prefix-in db: db) json racket/file
         "../../pos-backend-racket/pos/application/authentication-service.rkt"
         "../../pos-backend-racket/pos/application/operator-service.rkt"
         "../../pos-backend-racket/pos/application/register-operations-service.rkt"
         "../../pos-backend-racket/pos/application/transaction-command.rkt"
         "../../pos-backend-racket/pos/application/transaction-service.rkt"
         "../../pos-backend-racket/pos/application/transaction-void-approval-service.rkt"
         "../../pos-backend-racket/pos/domain/fake-catalog.rkt"
         "../../pos-backend-racket/pos/domain/money.rkt"
         "../../pos-backend-racket/pos/domain/register-operations.rkt"
         "../../pos-backend-racket/pos/persistence/operational-configuration-snapshot-codec.rkt"
         "../../pos-backend-racket/pos/persistence/security-audit-store.rkt"
         "../../pos-backend-racket/pos/persistence/sqlite-connection.rkt"
         "../../pos-backend-racket/pos/persistence/sqlite-maintenance.rkt"
         "../../pos-backend-racket/pos/persistence/sqlite-register-operations.rkt"
         "../../pos-backend-racket/pos/runtime-config.rkt"
         "../../pos-backend-racket/pos/runtime.rkt"
         "../../pos-backend-racket/pos/security/transaction-void-approval.rkt")

(define args (vector->list (current-command-line-arguments)))
(unless (= (length args) 1)
  (raise-user-error 'm7-enospc-test "expected private tmpfs directory"))
(define directory (path->complete-path (first args)))
(define database-path (build-path directory "pos.db"))

(define (require! condition message)
  (unless condition (error 'm7-enospc-test message)))
(define (fill! path)
  (define port (open-output-file path #:exists 'error #:mode 'binary))
  (define block (make-bytes 4096 65))
  (let loop ()
    (with-handlers ([exn:fail?
                     (lambda (_exception)
                       (with-handlers ([exn:fail? void]) (close-output-port port)))])
      (write-bytes block port)
      (flush-output port)
      (loop))))

(initialize-sqlite-database! database-path)
(define connection (open-pos-sqlite-connection database-path 'read/write))
(define runtime #f)
(dynamic-wind
 void
 (lambda ()
   (define operators (make-operator-service connection))
   (operator-service-create operators "enospc-alice" "Alice" 'cashier)
   (require! (operator-pin-enrollment-succeeded?
              (operator-service-enroll-pin operators "enospc-alice" "80421637"))
             "initial enrollment failed")
   (define before-revision
     (db:query-value connection
                     "SELECT credential_revision FROM operator_pin_credentials WHERE operator_id = 'enospc-alice'"))
   (define before-hash
     (db:query-value connection
                     "SELECT password_hash FROM operator_pin_credentials WHERE operator_id = 'enospc-alice'"))
   (operator-service-create operators "enospc-sam" "Sam" 'supervisor)
   (require! (operator-pin-enrollment-succeeded?
              (operator-service-enroll-pin operators "enospc-sam" "69380527"))
             "approver enrollment failed")
   (define decoded
     (json-string->operational-configuration-snapshot
      "{\"schema_version\":1,\"register\":{\"register_id\":\"enospc\",\"display_name\":\"ENOSPC\"},\"cashiers\":[{\"cashier_id\":\"enospc-alice\",\"display_name\":\"Alice\",\"active\":true}]}"))
   (activate-operational-configuration!
    connection (operational-configuration-decode-success-snapshot decoded))
   (set! runtime (start-pos-runtime (pos-runtime-config "127.0.0.1" 7340 database-path)
                                   #:catalog-lookup fake-catalog-lookup))
   (define auth (pos-runtime-authentication-service runtime))
   (define login (authentication-service-login auth "enospc-alice" "80421637"))
   (require! (authentication-login-succeeded? login) "pre-fill login failed")
   (define actor (authentication-login-succeeded-principal login))
   (define shift (register-operations-open-shift
                  (pos-runtime-register-operations-service runtime) actor (money 1000)))
   (require! (register-shift-opened? shift) "pre-fill shift failed")
   (define transactions (pos-runtime-transaction-service runtime))
   (require! (transaction-service-command-resolved?
              (transaction-service-execute-command
               transactions actor (start-transaction-command "enospc-start" "enospc-sale" 0)))
             "pre-fill transaction failed")
   (define command (void-transaction-command "enospc-void" "enospc-sale" 1))
   (define grant
     (transaction-void-approval-service-request
      (pos-runtime-transaction-void-approval-service runtime)
      actor command "enospc-sam" "69380527"))
   (require! (transaction-void-approval-granted? grant) "pre-fill approval failed")
   (define before-audit (db:query-value connection "SELECT COUNT(*) FROM security_audit_events"))
   (define before-events (db:query-value connection "SELECT COUNT(*) FROM transaction_events"))
   (define before-grants (db:query-rows connection "SELECT * FROM transaction_void_approval_grants"))
   (define filler (build-path directory "full.fill"))
   (fill! filler)
   (define reset-succeeded?
     (with-handlers ([exn:fail? (lambda (_exception) #f)])
       (operator-pin-reset-succeeded?
        (operator-service-reset-pin operators "enospc-alice" "48295173"))))
   (require! (not reset-succeeded?) "root reset reported success under ENOSPC")
   (define void-resolved?
     (with-handlers ([exn:fail? (lambda (_exception) #f)])
       (transaction-service-command-resolved?
        (transaction-service-execute-command
         transactions actor command
         #:approval-capability
         (transaction-void-approval-token->capability
          (transaction-void-approval-granted-approval-token grant))))))
   (require! (not void-resolved?) "approved void reported durable resolution under ENOSPC")
   (require! (authentication-login-failed?
              (authentication-service-login auth "unknown-enospc" "80421638"))
             "bad login changed security result under audit ENOSPC")
   (delete-file filler)
   (require! (= (db:query-value connection
                               "SELECT credential_revision FROM operator_pin_credentials WHERE operator_id = 'enospc-alice'")
                before-revision)
             "partial credential revision survived")
   (require! (equal? (db:query-value connection
                                     "SELECT password_hash FROM operator_pin_credentials WHERE operator_id = 'enospc-alice'")
                    before-hash)
             "partial credential hash survived")
   (require! (= (db:query-value connection "SELECT COUNT(*) FROM security_audit_events")
                before-audit)
             "failed security operations left an audit row")
   (require! (= before-events (db:query-value connection "SELECT COUNT(*) FROM transaction_events"))
             "void event survived failed commit")
   (for ([table '(transaction_command_receipts transaction_command_actor_attributions
                 transaction_command_approver_attributions)])
     (require! (= 0 (db:query-value connection
                                  (format "SELECT COUNT(*) FROM ~a WHERE command_id = 'enospc-void'" table)))
               "partial void command evidence survived"))
   (require! (equal? before-grants (db:query-rows connection "SELECT * FROM transaction_void_approval_grants"))
             "failed operations consumed approval grant")
   (require! (equal? "enospc-sale"
                     (db:query-value connection "SELECT active_transaction_id FROM register_shifts WHERE closed_at_epoch_ms IS NULL"))
             "failed void released shift slot")
   (require! (security-audit-ledger-valid? (verify-security-audit-ledger connection))
             "audit chain invalid after ENOSPC")
   (stop-pos-runtime! runtime)
   (set! runtime #f)
   (db:disconnect connection)
   (require! (sqlite-backup-validation-valid?
              (validate-pos-sqlite-backup database-path))
             "database cannot reopen and validate")
   (write-json (hasheq 'ok #t 'filesystem_limit_bytes (* 2 1024 1024)
                       'credential_revision_unchanged #t
                       'audit_chain_valid #t
                       'approved_void_rolled_back #t 'approval_grant_preserved #t
                       'bad_login_denied #t))
   (newline))
 (lambda ()
   (when runtime (stop-pos-runtime! runtime))
   (when (db:connected? connection) (db:disconnect connection))))
