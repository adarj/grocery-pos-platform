#lang racket

(require (prefix-in db: db)
         json
         racket/file
         rackunit
         "../pos/persistence/pos-database-migrations.rkt"
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
       (check-equal? (hash-ref status-json 'credential_enrolled_count) 0))))

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
