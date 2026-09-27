#lang racket

(require (prefix-in db: db)
         file/gunzip file/untar
         json racket/file racket/string
         "../../pos-backend-racket/pos/application/authentication-service.rkt"
         "../../pos-backend-racket/pos/application/operator-service.rkt"
         "../../pos-backend-racket/pos/application/register-operations-service.rkt"
         "../../pos-backend-racket/pos/application/transaction-command.rkt"
         "../../pos-backend-racket/pos/application/transaction-command-receipt.rkt"
         "../../pos-backend-racket/pos/application/transaction-service.rkt"
         "../../pos-backend-racket/pos/application/transaction-void-approval-service.rkt"
         "../../pos-backend-racket/pos/domain/fake-catalog.rkt"
         "../../pos-backend-racket/pos/domain/money.rkt"
         "../../pos-backend-racket/pos/domain/register-operations.rkt"
         "../../pos-backend-racket/pos/domain/security-audit-event.rkt"
         "../../pos-backend-racket/pos/persistence/operational-configuration-snapshot-codec.rkt"
         "../../pos-backend-racket/pos/persistence/security-audit-store.rkt"
         "../../pos-backend-racket/pos/persistence/sqlite-connection.rkt"
         "../../pos-backend-racket/pos/persistence/sqlite-maintenance.rkt"
         "../../pos-backend-racket/pos/persistence/sqlite-operators.rkt"
         "../../pos-backend-racket/pos/persistence/sqlite-register-operations.rkt"
         "../../pos-backend-racket/pos/persistence/sqlite-restore.rkt"
         "../../pos-backend-racket/pos/runtime-config.rkt"
         "../../pos-backend-racket/pos/runtime.rkt"
         "../../pos-backend-racket/pos/security/transaction-void-approval.rkt"
         "../../pos-backend-racket/pos/support/support-bundle.rkt")

(define (millis) (current-inexact-milliseconds))
(define (elapsed start) (inexact->exact (round (- (millis) start))))
(define (require! condition message)
  (unless condition (error 'm7-security-stress message)))
(define (sidecar-size path suffix)
  (define sidecar (bytes->path (bytes-append (path->bytes path) suffix)))
  (if (file-exists? sidecar) (file-size sidecar) 0))

(define (parse-count args)
  (define value (if (null? args) 10000
                    (and (= (length args) 1) (string->number (car args)))))
  (unless (and (exact-integer? value) (<= 1 value 100000))
    (raise-user-error 'm7-security-stress "expected event count from 1 to 100000"))
  value)

(define configuration-text
  "{\"schema_version\":1,\"register\":{\"register_id\":\"m7-stress\",\"display_name\":\"M7 Stress\"},\"cashiers\":[{\"cashier_id\":\"m7-alice\",\"display_name\":\"Alice\",\"active\":true}]}")

(define (run count)
  (define root (build-path (current-directory) ".local" "acceptance" "m7"))
  (make-directory* root)
  (define directory (make-temporary-file (path->string (build-path root "stress-~a")) 'directory))
  (define path (build-path directory "pos.db"))
  (define backup (build-path directory "backup.db"))
  (define restored (build-path directory "restored.db"))
  (initialize-sqlite-database! path)
  (define connection (open-pos-sqlite-connection path 'read/write))
  (dynamic-wind
   void
   (lambda ()
     ;; A synthetic but valid event wave uses the production typed constructor
     ;; and append API. The smaller credential/denial wave below uses the real
     ;; authentication service; these two evidence kinds are not conflated.
     (define append-start (millis))
     (for ([batch-start (in-range 0 count 250)])
       (db:call-with-transaction
        connection
        (lambda ()
          (for ([index (in-range batch-start (min count (+ batch-start 250)))])
            (append-security-audit-event!/in-transaction!
             connection (login-failed-event #f)
             #:source-kind 'pos_core
             #:source-instance-id "audit_runtime_m7_synthetic_stress"
             #:occurred-at-epoch-ms (+ 1000000 index))))
        #:option 'immediate))
     (define append-ms (elapsed append-start))
     (define first-verification-start (millis))
     (define verified (verify-security-audit-ledger connection))
     (require! (security-audit-ledger-valid? verified) "large ledger verification failed")
     (require! (= (security-audit-ledger-valid-event-count verified) count)
               "large ledger count mismatch")
     (define verification-ms (elapsed first-verification-start))

     (define decoded (json-string->operational-configuration-snapshot configuration-text))
     (require! (operational-configuration-decode-success? decoded) "configuration decode failed")
     (activate-operational-configuration!
      connection (operational-configuration-decode-success-snapshot decoded))
     (define operators (make-operator-service connection))
     (require! (operator-pin-enrollment-succeeded?
                (operator-service-enroll-pin operators "m7-alice" "80421637"))
               "PIN enrollment failed")
     (for ([identity '(("m7-bob" cashier) ("m7-sam" supervisor))])
       (require! (operator-create-succeeded?
                  (operator-service-create operators (first identity)
                                           (first identity) (second identity)))
                 "fixture operator creation failed")
       (require! (operator-pin-enrollment-succeeded?
                  (operator-service-enroll-pin operators (first identity) "69380527"))
                 "fixture credential enrollment failed"))
     (define runtime-start (millis))
     (define runtime
       (start-pos-runtime (pos-runtime-config "127.0.0.1" 7340 path)
                          #:catalog-lookup fake-catalog-lookup))
     (define startup-ms (elapsed runtime-start))
     (require! (<= startup-ms 30000) "large-ledger startup exceeds readiness contract")
     (dynamic-wind
      void
      (lambda ()
        (define auth (pos-runtime-authentication-service runtime))
        (for ([index (in-range 4)])
          (require! (authentication-login-failed?
                     (authentication-service-login auth "unknown-m7-stress" "80421638"))
                    "unknown login unexpectedly succeeded"))
        (define login (authentication-service-login auth "m7-alice" "80421637"))
        (require! (authentication-login-succeeded? login) "real login failed after stress")
        (define token (authentication-login-succeeded-access-token login))
        (define authenticated (authentication-service-authenticate auth token))
        (require! (authentication-session-authenticated? authenticated) "session invalid")
        (define principal (authentication-login-succeeded-principal login))
        (define opened
          (register-operations-open-shift
           (pos-runtime-register-operations-service runtime)
           principal (money 10000)))
        (require! (register-shift-opened? opened) "shift open failed")
        (define service (pos-runtime-transaction-service runtime))
        (define (accepted! command #:actor [actor principal] #:approval [approval #f])
          (define result
            (transaction-service-execute-command service actor command
                                                 #:approval-capability approval))
          (require! (transaction-service-command-resolved? result) "command unresolved")
          (define receipt (transaction-service-command-resolved-receipt result))
          (require! (eq? (transaction-command-receipt-outcome-kind receipt) 'accepted)
                    "command not accepted")
          receipt)
        (define checkout-start (millis))
        (accepted! (start-transaction-command "m7-start" "m7-sale" 0))
        (accepted! (scan-barcode-command "m7-scan" "m7-sale" 1 "049000001234"))
        (accepted! (tender-cash-command "m7-tender" "m7-sale" 2 (money 500)))
        (define completion (complete-transaction-command "m7-complete" "m7-sale" 3))
        (define receipt (accepted! completion))
        (require! (equal? receipt (accepted! completion)) "exact retry changed outcome")
        (define checkout-ms (elapsed checkout-start))

        ;; Actual ownership denials, not merely calls to audit instrumentation.
        (define bob-login (authentication-service-login auth "m7-bob" "69380527"))
        (require! (authentication-login-succeeded? bob-login) "Bob login failed")
        (define bob (authentication-login-succeeded-principal bob-login))
        (for ([index (in-range 20)])
          (require! (transaction-service-not-found?
                     (transaction-service-load-transaction service bob "m7-sale"))
                    "foreign read disclosed transaction"))
        (define before-missing (db:query-value connection "SELECT COUNT(*) FROM security_audit_events"))
        (require! (transaction-service-not-found?
                   (transaction-service-load-transaction service bob "m7-nonexistent"))
                  "missing resource result changed")
        (require! (= before-missing (db:query-value connection "SELECT COUNT(*) FROM security_audit_events"))
                  "genuine not-found fabricated denial evidence")
        (define alice-login (authentication-service-login auth "m7-alice" "80421637"))
        (require! (authentication-login-succeeded? alice-login) "Alice relogin failed")
        (define alice-token (authentication-login-succeeded-access-token alice-login))

        (accepted! (start-transaction-command "m7-void-start" "m7-void-sale" 0))
        (accepted! (scan-barcode-command "m7-void-scan" "m7-void-sale" 1 "049000001234"))
        (define void-command (void-transaction-command "m7-void" "m7-void-sale" 2))
        (require! (transaction-service-approval-required?
                   (transaction-service-execute-command service principal void-command))
                  "fresh void bypassed approval")
        (define grant
          (transaction-void-approval-service-request
           (pos-runtime-transaction-void-approval-service runtime)
           principal void-command "m7-sam" "69380527"))
        (require! (transaction-void-approval-granted? grant) "large-ledger approval failed")
        (require! (authentication-session-authenticated?
                   (authentication-service-authenticate auth alice-token))
                  "approval replaced requester session")
        (define void-receipt
          (accepted! void-command
                     #:approval (transaction-void-approval-token->capability
                                 (transaction-void-approval-granted-approval-token grant))))
        (require! (equal? void-receipt (accepted! void-command))
                  "approved void exact recovery changed outcome")
        (require! (= 1 (db:query-value connection
                                      "SELECT COUNT(*) FROM security_audit_events WHERE event_type = 'transaction.void_resolved'"))
                  "void retry duplicated audit resolution")

        ;; Rotate during an active sale, then use the same saved-undurable ID
        ;; under the new principal. Recovery remains operator-, not revision-bound.
        (accepted! (start-transaction-command "m7-rotation-start" "m7-rotation-sale" 0))
        (define pending (scan-barcode-command "m7-rotation-scan" "m7-rotation-sale" 1 "049000001234"))
        (define changed (authentication-service-change-pin auth principal alice-token
                                                          "80421637" "48295173"))
        (require! (authentication-pin-change-succeeded? changed) "large-ledger PIN change failed")
        (require! (authentication-session-invalid?
                   (authentication-service-authenticate auth alice-token)) "old bearer survived rotation")
        (require! (authentication-login-failed?
                   (authentication-service-login auth "m7-alice" "80421637")) "old PIN survived rotation")
        (define new-login (authentication-service-login auth "m7-alice" "48295173"))
        (require! (authentication-login-succeeded? new-login) "new PIN failed")
        (define new-principal (authentication-login-succeeded-principal new-login))
        (require! (equal? receipt (accepted! completion #:actor new-principal))
                  "durable recovery failed after rotation")
        (accepted! pending #:actor new-principal)
        (accepted! (tender-cash-command "m7-rotation-tender" "m7-rotation-sale" 2 (money 500))
                   #:actor new-principal)
        (accepted! (complete-transaction-command "m7-rotation-complete" "m7-rotation-sale" 3)
                   #:actor new-principal)

        (define support-path (build-path directory "support.tar.gz"))
        (collect-pos-support-bundle! path support-path
                                    #:platform-provider (lambda () (hash))
                                    #:package-provider (lambda () (hash))
                                    #:service-provider (lambda () (hash))
                                    #:api-provider (lambda () (hash))
                                    #:storage-provider (lambda (_path) (hash)))
        (define tar-path (build-path directory "support.tar"))
        (call-with-input-file support-path #:mode 'binary
          (lambda (input)
            (call-with-output-file tar-path #:mode 'binary
              (lambda (output) (gunzip-through-ports input output)))))
        (define members (build-path directory "support-members"))
        (make-directory members)
        (untar tar-path #:dest members)
        (define sentinels
          (list "m7-alice" "m7-sam" "m7-sale" "m7-void" "80421637" "48295173"
                "69380527" "049000001234" alice-token
                (transaction-void-approval-granted-approval-token grant)
                (db:query-value connection "SELECT password_hash FROM operator_pin_credentials WHERE operator_id = 'm7-alice'")))
        (for ([member (in-directory members)] #:when (file-exists? member))
          (define contents (file->string member))
          (for ([sentinel sentinels])
            (require! (not (string-contains? contents sentinel)) "support privacy sentinel escaped")))
        (define audit-count (db:query-value connection "SELECT COUNT(*) FROM security_audit_events"))
        (define audit-rows
          (db:query-rows connection "SELECT * FROM security_audit_events ORDER BY sequence"))
        (define db-bytes (file-size path))
        (define wal-bytes (sidecar-size path #"-wal"))
        (define backup-start (millis))
        (define created (create-pos-sqlite-backup! path backup))
        (require! (sqlite-backup-validation-valid?
                   (sqlite-backup-created-validation created)) "backup invalid")
        (define backup-ms (elapsed backup-start))
        ;; An isolated offline target exercises the same validated restore
        ;; machinery without replacing the source under the live runtime.
        (define restore-start (millis))
        (restore-pos-sqlite-database-offline! backup restored)
        (define restored-verification
          (call-with-pos-sqlite-inspection-connection
           restored verify-security-audit-ledger))
        (require! (security-audit-ledger-valid? restored-verification)
                  "restored audit ledger invalid")
        (require! (= (security-audit-ledger-valid-event-count restored-verification)
                     audit-count) "restore changed audit history")
        (require! (equal? audit-rows
                         (call-with-pos-sqlite-inspection-connection
                          restored (lambda (restored-connection)
                                     (db:query-rows restored-connection "SELECT * FROM security_audit_events ORDER BY sequence"))))
                  "restore transformed audit row bytes")
        (define restore-ms (elapsed restore-start))
        (write-json
         (hasheq 'ok #t 'synthetic_events count 'real_unknown_login_attempts 4
                 'real_authorization_denials 20 'audit_event_count audit-count
                 'approved_void_recovered #t 'pin_rotation_recovered #t
                 'support_privacy_passed #t 'restored_audit_rows_exact #t
                 'append_ms append-ms 'verification_ms verification-ms
                 'startup_ms startup-ms 'checkout_ms checkout-ms
                 'main_db_bytes db-bytes 'wal_bytes wal-bytes
                 'backup_ms backup-ms 'backup_bytes (file-size backup)
                 'restore_and_verify_ms restore-ms
                 'artifacts_directory (path->string directory))
         (current-output-port))
        (newline))
      (lambda () (stop-pos-runtime! runtime))))
   (lambda () (when (db:connected? connection) (db:disconnect connection)))))

(module+ main (run (parse-count (vector->list (current-command-line-arguments)))))
