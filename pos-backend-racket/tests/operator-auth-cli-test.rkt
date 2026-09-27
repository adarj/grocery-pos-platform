#lang racket

(require (prefix-in db: db)
         json
         racket/file
         racket/string
         rackunit
         "../pos/application/authentication-service.rkt"
         "../pos/persistence/pos-database-migrations.rkt"
         "../pos/persistence/sqlite-operators.rkt"
         "../pos/persistence/sqlite-connection.rkt"
         "../scripts/operator-auth.rkt")

(define (call-with-current-database procedure)
  (define directory
    (make-temporary-file "operator-auth-cli-~a" 'directory))
  (define database-path (build-path directory "pos.db"))
  (define connection (open-pos-sqlite-connection database-path 'create))
  (migrate-pos-database! connection)
  (db:disconnect connection)
  (dynamic-wind
    void
    (lambda () (procedure database-path))
    (lambda () (delete-directory/files directory))))

(define (invoke database-path arguments #:input [input ""] #:uid [uid 0])
  (define output (open-output-string))
  (define error-output (open-output-string))
  (define status
    (run-operator-auth-cli
     arguments
     #:database-path database-path
     #:effective-user-id (lambda () uid)
     #:input-port (open-input-string input)
     #:output-port output
     #:error-port error-output))
  (values status (get-output-string output) (get-output-string error-output)))

(module+ test
  (test-case "non-root use fails before touching the selected database"
    (define missing-path "/definitely/missing/operator-auth.db")
    (define-values (status output error-output)
      (invoke missing-path (vector "status") #:uid 1000))
    (check-equal? status 1)
    (check-equal? output "")
    (check-equal?
     (hash-ref (hash-ref (string->jsexpr error-output) 'error) 'code)
     "not_privileged"))

  (test-case "missing and empty databases fail without creation or migration"
    (define directory
      (make-temporary-file "operator-auth-missing-~a" 'directory))
    (define missing-path (build-path directory "missing.db"))
    (define empty-path (build-path directory "empty.db"))
    (display-to-file "" empty-path)
    (dynamic-wind
      void
      (lambda ()
        (for ([path (in-list (list missing-path empty-path))])
          (define-values (status output error-output)
            (invoke path (vector "status")))
          (check-equal? status 1)
          (check-equal? output "")
          (check-equal?
           (hash-ref (hash-ref (string->jsexpr error-output) 'error) 'code)
           "auth_admin_failed"))
        (check-false (file-exists? missing-path))
        (check-equal? (file-size empty-path) 0))
      (lambda () (delete-directory/files directory))))

  (test-case "root operator lifecycle has no default credential"
    (call-with-current-database
     (lambda (database-path)
       (define-values (create-status create-output create-error)
         (invoke database-path
                 (vector "operator" "create"
                         "manager-local" "Local Manager" "manager")))
       (check-equal? create-status 0)
       (check-equal? create-error "")
       (define created (hash-ref (string->jsexpr create-output) 'operator))
       (check-equal? (hash-ref created 'role) "manager")
       (check-equal? (hash-ref created 'credential_state)
                     "enrollment-required")

       (define-values (status-status status-output status-error)
         (invoke database-path (vector "status")))
       (check-equal? status-status 0)
       (check-equal? status-error "")
       (define status-json (string->jsexpr status-output))
       (check-equal? (hash-ref status-json 'operator_count) 1)
       (check-equal? (hash-ref status-json 'credential_enrolled_count) 0)
       (check-equal? (hash-ref status-json 'register_operator_ready_count) 0)
       (check-equal? (hash-ref status-json 'approval_operator_ready_count) 0))))

  (test-case "status counts only active enrolled configured register and approval operators"
    (call-with-current-database
     (lambda (database-path)
       (invoke database-path
               (vector "operator" "create" "Alice" "Alice" "cashier"))
       (invoke database-path
               (vector "operator" "create" "Morgan" "Morgan" "manager"))
       (invoke database-path
               (vector "operator" "enroll-pin" "Alice")
               #:input "80421637\n")
       (invoke database-path
               (vector "operator" "enroll-pin" "Morgan")
               #:input "48295173\n")
       (define connection
         (open-pos-sqlite-connection database-path 'read/write))
       (db:query-exec connection
                      "INSERT INTO cashiers VALUES ('Alice', 'Alice', 1)")
       (db:disconnect connection)
       (define-values (status output _error)
         (invoke database-path (vector "status")))
       (check-equal? status 0)
       (define value (string->jsexpr output))
       (check-equal? (hash-ref value 'active_enrolled_operator_count) 2)
       (check-equal? (hash-ref value 'register_operator_ready_count) 1)
       (check-equal? (hash-ref value 'approval_operator_ready_count) 1)
       (check-equal? (hash-ref value 'register_auth_ready) #t)
       (check-equal? (hash-ref value 'approval_auth_ready) #t)
       (invoke database-path (vector "operator" "disable" "Morgan"))
       (define-values (_status after-output _error2)
         (invoke database-path (vector "status")))
       (define after (string->jsexpr after-output))
       (check-equal? (hash-ref after 'approval_operator_ready_count) 0)
       (check-equal? (hash-ref after 'approval_auth_ready) #f))))

  (test-case "PIN enrollment reads stdin and never accepts or emits a PIN argv"
    (call-with-current-database
     (lambda (database-path)
       (invoke database-path
               (vector "operator" "create"
                       "manager-local" "Local Manager" "manager"))
       (define sentinel-pin "80421637")
       (define-values (bad-status bad-output bad-error)
         (invoke database-path
                 (vector "operator" "enroll-pin"
                         "manager-local" sentinel-pin)))
       (check-equal? bad-status 2)
       (check-equal? bad-output "")
       (check-false (string-contains? bad-error sentinel-pin))

       (define-values (status output error-output)
         (invoke database-path
                 (vector "operator" "enroll-pin" "manager-local")
                 #:input (string-append sentinel-pin "\n")))
       (check-equal? status 0)
       (check-equal? error-output "")
       (check-false (string-contains? output sentinel-pin))
       (check-false (string-contains? output "$argon2id$")))))

  (test-case "root reset requires an enrolled credential and rotates without PIN exposure"
    (call-with-current-database
     (lambda (database-path)
       (invoke database-path
               (vector "operator" "create" "Morgan" "Morgan" "manager"))
       (define-values (missing-status _missing-output missing-error)
         (invoke database-path (vector "operator" "reset-pin" "Morgan")
                 #:input "48295173\n"))
       (check-equal? missing-status 1)
       (check-equal?
        (hash-ref (hash-ref (string->jsexpr missing-error) 'error) 'code)
        "credential-enrollment-required")
       (invoke database-path (vector "operator" "enroll-pin" "Morgan")
               #:input "80421637\n")
       (define-values (argv-status argv-output argv-error)
         (invoke database-path
                 (vector "operator" "reset-pin" "Morgan" "48295173")))
       (check-equal? argv-status 2)
       (check-equal? argv-output "")
       (check-false (string-contains? argv-error "48295173"))
       (define-values (reset-status reset-output reset-error)
         (invoke database-path (vector "operator" "reset-pin" "Morgan")
                 #:input "48295173\n"))
       (check-equal? reset-status 0)
       (check-equal? reset-error "")
       (check-equal?
        (hash-ref (string->jsexpr reset-output) 'credential_revision) 2)
       (check-false (string-contains? reset-output "48295173"))
       (check-false (string-contains? reset-output "$argon2id$")))))

  (test-case "PIN lifecycle sentinels stay out of CLI, audit and noncredential SQLite state"
    (call-with-current-database
     (lambda (database-path)
       (define old-pin "80421637")
       (define changed-pin "48295173")
       (define reset-pin "58310472")
       (define wrong-pin "90274618")
       (define visible "")
       (define (remember! output error-output)
         (set! visible (string-append visible output error-output)))
       (define-values (create-status create-output create-error)
         (invoke database-path
                 (vector "operator" "create" "Alice" "Alice" "cashier")))
       (check-equal? create-status 0)
       (remember! create-output create-error)
       (define-values (enroll-status enroll-output enroll-error)
         (invoke database-path (vector "operator" "enroll-pin" "Alice")
                 #:input (string-append old-pin "\n")))
       (check-equal? enroll-status 0)
       (remember! enroll-output enroll-error)
       (define connection
         (open-pos-sqlite-connection database-path 'read/write))
       (dynamic-wind
         void
         (lambda ()
           (define service (make-authentication-service connection))
           (define login (authentication-service-login service "Alice" old-pin))
           (check-pred authentication-login-succeeded? login)
           (define principal
             (authentication-login-succeeded-principal login))
           (define token
             (authentication-login-succeeded-access-token login))
           (define captured-output (open-output-string))
           (define captured-error (open-output-string))
           (parameterize ([current-output-port captured-output]
                          [current-error-port captured-error])
             (check-pred
              authentication-pin-change-failed?
              (authentication-service-change-pin
               service principal token wrong-pin changed-pin))
             (check-pred
              authentication-pin-change-succeeded?
              (authentication-service-change-pin
               service principal token old-pin changed-pin)))
           (set! visible
                 (string-append visible
                                (get-output-string captured-output)
                                (get-output-string captured-error)))
           (define-values (argv-status argv-output argv-error)
             (invoke database-path
                     (vector "operator" "reset-pin" "Alice" reset-pin)))
           (check-equal? argv-status 2)
           (remember! argv-output argv-error)
           (define-values (reset-status reset-output reset-error)
             (invoke database-path (vector "operator" "reset-pin" "Alice")
                     #:input (string-append reset-pin "\n")))
           (check-equal? reset-status 0)
           (remember! reset-output reset-error)
           (define phc
             (operator-pin-record-password-hash
              (load-operator-pin-record connection "Alice")))
           (check-true (string-prefix? phc "$argon2id$"))
           (define noncredential-state
             (format
              "~s"
              (for/list ([table
                          (in-list
                           (db:query-list
                            connection
                            "SELECT name FROM sqlite_master WHERE type = 'table' AND name <> 'operator_pin_credentials' ORDER BY name"))])
                (db:query-rows connection (format "SELECT * FROM ~a" table)))))
           (for ([secret (in-list (list old-pin changed-pin reset-pin
                                        wrong-pin phc))])
             (check-false (string-contains? visible secret))
             (check-false (string-contains? noncredential-state secret)))
           (check-pred authentication-login-failed?
                       (authentication-service-login service "Alice" old-pin))
           (check-pred authentication-login-failed?
                       (authentication-service-login service "Alice" changed-pin))
           (check-pred authentication-login-succeeded?
                       (authentication-service-login service "Alice" reset-pin)))
         (lambda () (db:disconnect connection))))))

  (test-case "unknown role and malformed verifier failures stay sanitized"
    (call-with-current-database
     (lambda (database-path)
       (define-values (status output error-output)
         (invoke database-path
                 (vector "operator" "create"
                         "bad" "Bad" "administrator")))
       (check-equal? status 1)
       (check-equal? output "")
       (check-false (string-contains? error-output "context..."))))))
