#lang racket

(require (prefix-in db: db)
         json
         rackunit
         racket/file
         "../pos/application/authentication-service.rkt"
         "../pos/domain/security-audit-event.rkt"
         "../pos/persistence/pos-database-migrations.rkt"
         "../pos/persistence/security-audit-store.rkt"
         "../pos/persistence/sqlite-connection.rkt"
         "../scripts/security-audit.rkt")

(define (with-audit-db proc)
  (define directory (make-temporary-file "audit-cli-~a" 'directory))
  (define path (build-path directory "pos.db"))
  (dynamic-wind
    void
    (lambda ()
      (define conn (open-pos-sqlite-connection path 'create))
      (db:query-exec conn "PRAGMA foreign_keys = ON")
      (migrate-pos-database! conn)
      (append-security-audit-event!
       conn (runtime-started-event)
       #:source-kind 'pos_core
       #:source-instance-id "audit_runtime_fixture"
       #:occurred-at-epoch-ms 1000)
      (db:disconnect conn)
      (proc path))
    (lambda () (delete-directory/files directory))))

(module+ test
  (test-case "root list excludes attempted PIN, stored PHC, and claimed unknown identity"
    (with-audit-db
     (lambda (path)
       (define phc
         "$argon2id$v=19$m=19456,t=2,p=1$c2FsdHNhbHRzYWx0c2FsdA$aGFzaGhhc2hoYXNoaGFzaGhhc2hoYXNoaGFzaGhhc2g")
       (define writer
         (open-pos-sqlite-connection path 'read/write))
       (dynamic-wind
         void
         (lambda ()
           (db:query-exec writer
                          "INSERT INTO operators VALUES ('known-audit-test', 'Known', 1)")
           (db:query-exec writer
                          "INSERT INTO operator_roles VALUES ('known-audit-test', 'cashier')")
           (db:query-exec writer
                          "INSERT INTO operator_pin_credentials VALUES ('known-audit-test', ?, 1)"
                          phc)
           (define auth
             (make-authentication-service
              writer
              #:verify-pin (lambda (_pin _hash) #f)
              #:dummy-password-hash phc))
           (check-pred
            authentication-login-failed?
            (authentication-service-login
             auth "SECRET-CLAIMED-OPERATOR" "73142896")))
         (lambda () (db:disconnect writer)))
       (define output (open-output-string))
       (check-equal?
        (run-security-audit-cli
         #("list") #:database-path path
         #:effective-user-id (lambda () 0)
         #:output-port output)
        0)
       (define listed (get-output-string output))
       (for ([secret (in-list
                      (list "SECRET-CLAIMED-OPERATOR" "73142896" phc
                            "gpos_s1_" "gpos_a1_"))])
         (check-false (string-contains? listed secret))))))

  (test-case "root verify and list audit themselves before returning records"
    (with-audit-db
     (lambda (path)
       (define output (open-output-string))
       (check-equal?
        (run-security-audit-cli
         #("verify") #:database-path path
         #:effective-user-id (lambda () 0)
         #:output-port output)
        0)
       (define verification (string->jsexpr (get-output-string output)))
       (check-equal? (hash-ref verification 'status) "valid")
       (check-equal? (hash-ref verification 'verified_through_sequence) 1)
       (check-equal? (hash-ref verification 'access_event_sequence) 2)
       (define list-output (open-output-string))
       (check-equal?
        (run-security-audit-cli
         #("list" "0" "10") #:database-path path
         #:effective-user-id (lambda () 0)
         #:output-port list-output)
        0)
       (check-true
        (string-contains? (get-output-string list-output) "audit.accessed"))
       (check-equal?
        (map (lambda (line) (hash-ref (string->jsexpr line) 'sequence))
             (string-split (string-trim (get-output-string list-output)) "\n"))
        '(1 2 3))
       (define narrow-output (open-output-string))
       (check-equal?
        (run-security-audit-cli
         #("list" "2" "1") #:database-path path
         #:effective-user-id (lambda () 0)
         #:output-port narrow-output)
        0)
       (check-equal?
        (hash-ref (string->jsexpr (get-output-string narrow-output)) 'sequence)
        3)
       (define conn (db:sqlite3-connect #:database path #:mode 'read-only))
       (check-equal?
        (db:query-value conn "SELECT COUNT(*) FROM security_audit_events")
        4)
       (db:disconnect conn))))

  (test-case "nonroot and failed access append return no ledger content"
    (with-audit-db
     (lambda (path)
       (define denied-output (open-output-string))
       (check-equal?
        (run-security-audit-cli
         #("list") #:database-path path
         #:effective-user-id (lambda () 1000)
         #:output-port denied-output)
        1)
       (check-equal? (get-output-string denied-output) "")
       (define failed-output (open-output-string))
       (check-equal?
        (run-security-audit-cli
         #("list") #:database-path path
         #:effective-user-id (lambda () 0)
         #:output-port failed-output
         #:append-audit!
         (lambda (_connection _event)
           (error 'test "audit append failed")))
        1)
       (check-equal? (get-output-string failed-output) "")))))

  (test-case "corrupt ledger and invalid pagination never disclose rows"
    (with-audit-db
     (lambda (path)
       (define rejected-output (open-output-string))
       (check-equal?
        (run-security-audit-cli
         #("list" "0" "1001") #:database-path path
         #:effective-user-id (lambda () 0)
         #:output-port rejected-output)
        1)
       (check-equal? (get-output-string rejected-output) "")
       (define writer (db:sqlite3-connect #:database path #:mode 'read/write))
       (db:query-exec writer "DROP TRIGGER security_audit_events_no_update")
       (db:query-exec writer
                      "UPDATE security_audit_events SET event_json = 'SECRET_CORRUPT_AUDIT_SENTINEL' WHERE sequence = 1")
       (db:disconnect writer)
       (define output (open-output-string))
       (define errors (open-output-string))
       (check-equal?
        (run-security-audit-cli
         #("verify") #:database-path path
         #:effective-user-id (lambda () 0)
         #:output-port output #:error-port errors)
        1)
       (check-equal? (get-output-string output) "")
       (check-false
        (string-contains? (get-output-string errors)
                          "SECRET_CORRUPT_AUDIT_SENTINEL")))))
