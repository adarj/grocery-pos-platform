#lang racket

(require (prefix-in db: db)
         ffi/unsafe
         json
         "../pos/application/operator-service.rkt"
         "../pos/domain/operator-identity.rkt"
         "../pos/persistence/pos-database-migrations.rkt"
         "../pos/persistence/sqlite-connection.rkt"
         "../pos/persistence/sqlite-operators.rkt")

(provide run-operator-auth-cli)

(define canonical-database-path "/var/lib/grocery-pos/pos.db")

(define usage
  (string-append
   "Usage:\n"
   "  grocery-pos-auth status\n"
   "  grocery-pos-auth operator list\n"
   "  grocery-pos-auth operator create OPERATOR_ID DISPLAY_NAME ROLE\n"
   "  grocery-pos-auth operator set-role OPERATOR_ID ROLE\n"
   "  grocery-pos-auth operator enable OPERATOR_ID\n"
   "  grocery-pos-auth operator disable OPERATOR_ID\n"
   "  grocery-pos-auth operator enroll-pin OPERATOR_ID\n"
   "  grocery-pos-auth operator reset-pin OPERATOR_ID\n"))

(define system-geteuid
  (get-ffi-obj "geteuid" (ffi-lib #f) (_fun -> _uint)))

(define (write-json-line value port)
  (write-json value port)
  (newline port))

(define (write-failure code message error-port)
  (write-json-line
   (hasheq 'ok #f
           'error (hasheq 'code code 'message message))
   error-port)
  1)

(define (operator->jsexpr operator)
  (hasheq
   'operator_id (operator-identity-operator-id operator)
   'display_name (operator-identity-display-name operator)
   'active (operator-identity-active? operator)
   'role (operator-role->string (operator-identity-role operator))
   'credential_state
   (symbol->string (operator-identity-credential-state operator))
   'credential_revision
   (or (operator-identity-credential-revision operator) (json-null))))

(define (with-current-service database-path procedure)
  ;; read/write is intentionally non-creating. Schema validation is separate
  ;; from migration so this administrative tool cannot bootstrap or upgrade an
  ;; unexpected database.
  (define connection
    (open-pos-sqlite-connection database-path 'read/write))
  (dynamic-wind
    void
    (lambda ()
      (validate-pos-database-schema! connection #:require-current? #t)
      (procedure (make-operator-service connection)))
    (lambda () (db:disconnect connection))))

(define (role-argument value)
  (parse-operator-role value))

(define (result-code result)
  (cond
    [(operator-create-rejected? result)
     (operator-create-rejected-code result)]
    [(operator-update-rejected? result)
     (operator-update-rejected-code result)]
    [(operator-pin-enrollment-rejected? result)
     (operator-pin-enrollment-rejected-code result)]
    [(operator-pin-reset-rejected? result)
     (operator-pin-reset-rejected-code result)]
    [else 'operation-rejected]))

(define (write-operator-result operation result output-port error-port)
  (cond
    [(operator-create-succeeded? result)
     (write-json-line
      (hasheq 'ok #t
              'operation operation
              'operator (operator->jsexpr
                         (operator-create-succeeded-operator result)))
      output-port)
     0]
    [(operator-update-succeeded? result)
     (write-json-line
      (hasheq 'ok #t
              'operation operation
              'operator (operator->jsexpr
                         (operator-update-succeeded-operator result)))
      output-port)
     0]
    [(operator-pin-enrollment-succeeded? result)
     (write-json-line
      (hasheq
       'ok #t
       'operation operation
       'operator_id
       (operator-pin-enrollment-succeeded-operator-id result)
       'credential_revision
       (operator-pin-enrollment-succeeded-credential-revision result))
      output-port)
     0]
    [(operator-pin-reset-succeeded? result)
     (write-json-line
      (hasheq 'ok #t 'operation operation
              'operator_id (operator-pin-reset-succeeded-operator-id result)
              'credential_revision
              (operator-pin-reset-succeeded-credential-revision result))
      output-port)
     0]
    [else
     (write-failure
      (symbol->string (result-code result))
      "Operator administration request was rejected."
      error-port)]))

(define (dispatch service arguments input-port output-port error-port)
  (match arguments
    [(list "status")
     (define counts (operator-service-auth-status service))
     (write-json-line
      (hash-set
       (hash-set
        (hash-set counts 'ok #t)
        'operation "status")
       'schema_version current-pos-database-schema-version)
      output-port)
     0]
    [(list "operator" "list")
     (write-json-line
      (hasheq 'ok #t
              'operation "operator_list"
              'operators
              (map operator->jsexpr (operator-service-list service)))
      output-port)
     0]
    [(list "operator" "create" operator-id display-name role-text)
     (define role (role-argument role-text))
     (if role
         (write-operator-result
          "operator_create"
          (operator-service-create service operator-id display-name role)
          output-port
          error-port)
         (write-failure
          "invalid_role" "Role must be cashier, supervisor, or manager."
          error-port))]
    [(list "operator" "set-role" operator-id role-text)
     (define role (role-argument role-text))
     (if role
         (write-operator-result
          "operator_set_role"
          (operator-service-set-role service operator-id role)
          output-port
          error-port)
         (write-failure
          "invalid_role" "Role must be cashier, supervisor, or manager."
          error-port))]
    [(list "operator" "enable" operator-id)
     (write-operator-result
      "operator_enable"
      (operator-service-set-active service operator-id #t)
      output-port
      error-port)]
    [(list "operator" "disable" operator-id)
     (write-operator-result
      "operator_disable"
      (operator-service-set-active service operator-id #f)
      output-port
      error-port)]
    [(list "operator" "enroll-pin" operator-id)
     (define pin (read-line input-port 'any))
     (if (eof-object? pin)
         (write-failure
          "pin_input_unavailable" "Secure PIN input was unavailable."
          error-port)
         (write-operator-result
          "operator_enroll_pin"
          (operator-service-enroll-pin service operator-id pin)
          output-port
          error-port))]
    [(list "operator" "reset-pin" operator-id)
     (define pin (read-line input-port 'any))
     (if (eof-object? pin)
         (write-failure
          "pin_input_unavailable" "Secure PIN input was unavailable."
          error-port)
         (write-operator-result
          "operator_reset_pin"
          (operator-service-reset-pin service operator-id pin)
          output-port
          error-port))]
    [_
     (display usage error-port)
     2]))

(define (run-operator-auth-cli
         arguments
         #:database-path [database-path canonical-database-path]
         #:effective-user-id [effective-user-id system-geteuid]
         #:input-port [input-port (current-input-port)]
         #:output-port [output-port (current-output-port)]
         #:error-port [error-port (current-error-port)])
  (unless (vector? arguments)
    (raise-argument-error 'run-operator-auth-cli "vector?" arguments))
  (cond
    [(not (zero? (effective-user-id)))
     (write-failure
      "not_privileged" "Operator administration requires root." error-port)]
    [else
     (with-handlers
         ([exn:fail?
           (lambda (_exception)
             ;; Never expose database, crypto, verifier, or PIN details.
             (write-failure
              "auth_admin_failed"
              "Operator administration could not be completed."
              error-port))])
       (with-current-service
        database-path
        (lambda (service)
          (dispatch
           service
           (vector->list arguments)
           input-port
           output-port
           error-port))))]))

(module+ main
  (exit (run-operator-auth-cli (current-command-line-arguments))))
