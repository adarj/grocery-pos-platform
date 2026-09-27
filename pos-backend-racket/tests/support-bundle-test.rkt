#lang racket

(require (prefix-in db: db)
         file/gunzip
         file/untar
         json
         racket/file
         racket/list
         racket/string
         rackunit
         "../pos/domain/security-audit-event.rkt"
         "../pos/domain/transaction-event.rkt"
         "../pos/persistence/security-audit-store.rkt"
         "../pos/persistence/sqlite-transaction-event-store.rkt"
         "../pos/runtime.rkt"
         "../pos/support/support-bundle.rkt")

(define privacy-sentinel "SUPPORT_BUNDLE_MUST_NOT_CONTAIN_THIS_SENTINEL")
(define operator-id-sentinel "OPERATOR_ID_MUST_NOT_BE_EXPORTED")
(define operator-name-sentinel "OPERATOR_NAME_MUST_NOT_BE_EXPORTED")
(define command-actor-sentinel "COMMAND_ACTOR_MUST_NOT_BE_EXPORTED")
(define approval-id-sentinel "APPROVAL_ID_MUST_NOT_BE_EXPORTED")
(define approver-id-sentinel "APPROVER_ID_MUST_NOT_BE_EXPORTED")
(define audit-operator-sentinel "AUDIT_OPERATOR_ID_MUST_NOT_BE_EXPORTED")
(define approval-token-sentinel
  "gpos_a1_APPROVAL_TOKEN_MUST_NOT_BE_EXPORTED")
(define approval-digest-sentinel "APPROVAL_DIGEST_1234567890123456")
(define pin-sentinel "80421637")
(define credential-sentinel
  "$argon2id$v=19$m=19456,t=2,p=1$CREDENTIAL_HASH_MUST_NOT_BE_EXPORTED$hash")
(define bearer-token-sentinel
  "gpos_s1_BEARER_TOKEN_MUST_NOT_BE_EXPORTED_0123456789abcdef")
(define privacy-sentinels
  (list privacy-sentinel
        operator-id-sentinel
        operator-name-sentinel
        command-actor-sentinel
        approval-id-sentinel
        approver-id-sentinel
        audit-operator-sentinel
        approval-token-sentinel
        approval-digest-sentinel
        pin-sentinel
        credential-sentinel
        bearer-token-sentinel))

(define (call-with-temporary-directory procedure)
  (define directory
    (make-temporary-file "grocery-pos-support-test-~a" 'directory))
  (dynamic-wind
    void
    (lambda () (procedure directory))
    (lambda () (delete-directory/files directory))))

(define (create-current-database-with-sentinel! database-path)
  (initialize-sqlite-database! database-path)
  (define connection
    (db:sqlite3-connect #:database database-path #:mode 'read/write))
  (dynamic-wind
    void
    (lambda ()
      (check-pred
       journal-append-succeeded?
       (append-transaction-events!
        connection
        privacy-sentinel
        0
        (list (transaction-started privacy-sentinel))))
      (db:query-exec
       connection
       "INSERT INTO operators (operator_id, display_name, active) VALUES (?, ?, 1)"
       operator-id-sentinel operator-name-sentinel)
      (db:query-exec
       connection
       "INSERT INTO operator_roles (operator_id, role) VALUES (?, 'manager')"
       operator-id-sentinel)
      (db:query-exec
       connection
       #<<SQL
INSERT INTO operator_pin_credentials
  (operator_id, password_hash, credential_revision)
VALUES (?, ?, 1)
SQL
       operator-id-sentinel credential-sentinel)
      (db:query-exec
       connection
       #<<SQL
INSERT INTO transaction_command_receipts
  (command_id, transaction_id, command_schema_version, command_type,
   expected_version, command_json, outcome_kind, outcome_code,
   outcome_stream_version)
VALUES
  ('support-actor-command', ?, 1, 'start_transaction', 0,
   ?, 'accepted', 'accepted', 1)
SQL
       privacy-sentinel
       (format
        "{\"schema_version\":1,\"command_id\":\"support-actor-command\",\"transaction_id\":\"~a\",\"expected_version\":0,\"command_type\":\"start_transaction\",\"payload\":{}}"
        privacy-sentinel))
      (db:query-exec
       connection
       "INSERT INTO transaction_command_actor_attributions (command_id, operator_id) VALUES ('support-actor-command', ?)"
       command-actor-sentinel)
      (db:query-exec
       connection
       #<<SQL
INSERT INTO transaction_void_approval_grants
  (approval_id, token_digest, issuer_instance_id, requester_operator_id,
   requester_credential_revision, approver_operator_id,
   approver_credential_revision, command_id,
   transaction_id, command_schema_version, expected_version,
   granted_at_monotonic_ms, expires_at_monotonic_ms, expires_at_epoch_ms)
VALUES (?, ?, 'support-instance', 'support-requester', 1, ?, 1,
        'support-pending-void', ?, 1, 1, 1000, 91000, 91000)
SQL
       approval-id-sentinel
       (string->bytes/utf-8 approval-digest-sentinel)
       approver-id-sentinel privacy-sentinel)
      (db:query-exec
       connection
       #<<SQL
INSERT INTO transaction_command_receipts
  (command_id, transaction_id, command_schema_version, command_type,
   expected_version, command_json, outcome_kind, outcome_code,
   outcome_stream_version)
VALUES ('support-void-command', ?, 1, 'void_transaction', 1,
        ?, 'domain_rejected', 'invalid_transaction_state', 1)
SQL
       privacy-sentinel
       (format
        "{\"schema_version\":1,\"command_id\":\"support-void-command\",\"transaction_id\":\"~a\",\"expected_version\":1,\"command_type\":\"void_transaction\",\"payload\":{}}"
        privacy-sentinel))
      (db:query-exec
       connection
       "INSERT INTO transaction_command_actor_attributions VALUES ('support-void-command', ?)"
       command-actor-sentinel)
      (db:query-exec
       connection
       "INSERT INTO transaction_command_approver_attributions VALUES ('support-void-command', ?, ?, 1, 1000)"
       approval-id-sentinel approver-id-sentinel)
      (append-security-audit-event!
       connection
       (operator-created-event audit-operator-sentinel 'cashier)
       #:source-kind 'root_cli
       #:source-instance-id "audit_root_cli_support_privacy"
       #:occurred-at-epoch-ms 1000))
    (lambda () (db:disconnect connection))))

(define (fake-platform-provider)
  (hasheq 'os_id "fedora"
          'os_version_id "43"
          'os_variant_id "kinoite"
          'kernel_release "6.17-test"
          'cpu_architecture "aarch64"
          'hostname privacy-sentinel
          'machine_id privacy-sentinel))

(define (fake-package-provider)
  (hasheq 'name "grocery-pos-core"
          'version "0.0.0"
          'release "0.1.dev"
          'architecture "noarch"
          'rpm_database_dump privacy-sentinel))

(define (fake-service-provider)
  (hasheq 'LoadState "loaded"
          'ActiveState "active"
          'SubState "running"
          'UnitFileState "disabled"
          'Result "success"
          'ExecMainCode 1
          'ExecMainStatus 0
          'NRestarts 0
          'Environment bearer-token-sentinel
          'ApprovalToken approval-token-sentinel
          'ExecStart privacy-sentinel))

(define (fake-api-provider)
  (hasheq
   'health (hasheq 'http_status 200
                   'ok #t
                   'service "grocery-pos-core"
                   'hostname privacy-sentinel)
   'ready (hasheq 'http_status 200
                  'ok #t
                  'service "grocery-pos-core"
                  'status "ready"
                  'database_schema_version 10
                  'exception privacy-sentinel)))

(define (fake-storage-provider _state-path)
  (hasheq 'total_bytes 1000000
          'used_bytes 400000
          'available_bytes 600000
          'usage_percent 40
          'device privacy-sentinel
          'mounts privacy-sentinel))

(define (extract-bundle! archive destination)
  (make-directory destination)
  (define tar-path (build-path destination "bundle.tar"))
  (call-with-input-file
   archive
   #:mode 'binary
   (lambda (input)
     (call-with-output-file
      tar-path
      #:mode 'binary
      #:exists 'error
      (lambda (output) (gunzip-through-ports input output)))))
  (untar tar-path #:dest destination)
  (delete-file tar-path))

(module+ test
  (test-case "support bundle is an exact allowlist and excludes POS sentinel data"
    (call-with-temporary-directory
     (lambda (directory)
       (define database-path (build-path directory "pos.db"))
       (define output-path (build-path directory "support.tar.gz"))
       (define extraction-path (build-path directory "extracted"))
       (create-current-database-with-sentinel! database-path)

       (define created
         (collect-pos-support-bundle!
          database-path
          output-path
          #:platform-provider fake-platform-provider
          #:package-provider fake-package-provider
          #:service-provider fake-service-provider
          #:api-provider fake-api-provider
          #:storage-provider fake-storage-provider))

       (check-equal? (support-bundle-created-path created) output-path)
       (check-equal? (file-or-directory-permissions output-path 'bits) #o600)
       (extract-bundle! output-path extraction-path)
       (define members
         (sort
          (for/list ([path (in-list (directory-list extraction-path))])
            (path->string path))
          string<?))
       (check-equal?
        members
        '("api.json" "database.json" "manifest.json" "package.json"
          "platform.json" "service.json" "storage.json"))
       (for ([member (in-list members)])
         (define member-path (build-path extraction-path member))
         (check-eq? (file-or-directory-type member-path #t) 'file)
         (for ([sentinel (in-list privacy-sentinels)])
           (check-false
            (regexp-match? (regexp (regexp-quote sentinel))
                           (file->string member-path)))))

       (define manifest
         (call-with-input-file
          (build-path extraction-path "manifest.json") read-json))
       (check-equal? (hash-ref manifest 'support_bundle_schema_version) 1)
       (check-not-false
        (member "authoritative POS database and SQLite sidecars"
                (hash-ref manifest 'excluded_sensitive_categories)))

       (define database
         (call-with-input-file
          (build-path extraction-path "database.json") read-json))
       (check-equal? (hash-ref database 'migration_status) "current")
       (check-equal? (hash-ref database 'current_supported_migration_version) 12)
       (check-false (hash-has-key? database 'path))
       (check-false (hash-has-key? database 'diagnostic))

       (for ([member (in-list members)])
         (check-false
          (regexp-match?
           #px"(?i:[.](?:db|sqlite)$|-(?:wal|shm|journal)$)"
           member)))

       (check-exn exn:fail?
                  (lambda ()
                    (collect-pos-support-bundle!
                     database-path output-path
                     #:platform-provider fake-platform-provider
                     #:package-provider fake-package-provider
                     #:service-provider fake-service-provider
                     #:api-provider fake-api-provider
                     #:storage-provider fake-storage-provider)))
       (check-true (file-exists? output-path)))))

  (test-case "support collection survives unavailable diagnostic sections"
    (call-with-temporary-directory
     (lambda (directory)
       (define output-path (build-path directory "partial-support.tar.gz"))
       (define extraction-path (build-path directory "extracted"))
       (collect-pos-support-bundle!
        (build-path directory "missing.db")
        output-path
        #:platform-provider (lambda () (error 'test privacy-sentinel))
        #:package-provider (lambda () (error 'test privacy-sentinel))
        #:service-provider (lambda () (error 'test privacy-sentinel))
        #:api-provider (lambda () (error 'test privacy-sentinel))
        #:storage-provider (lambda (_path) (error 'test privacy-sentinel)))
       (extract-bundle! output-path extraction-path)
       (for ([member (in-list (directory-list extraction-path #:build? #t))])
         (for ([sentinel (in-list privacy-sentinels)])
           (check-false
            (regexp-match? (regexp (regexp-quote sentinel))
                           (file->string member)))))
       (define database
         (call-with-input-file
          (build-path extraction-path "database.json") read-json))
       (check-equal? (hash-ref database 'file_present) #f)
       (check-equal? (hash-ref database 'migration_status) "missing-file")))))
