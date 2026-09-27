#lang racket

(require (prefix-in db: db)
         web-server/http
         "../../pos/application/authentication-service.rkt"
         "../../pos/domain/operator-identity.rkt")

(provide test-operator-id
         test-operator-pin
         make-test-authentication-service
         issue-test-access-token
         test-authorization-header)

(define test-operator-id "__http_test_operator__")
(define test-operator-pin "80421637")
(define test-password-hash
  "$argon2id$v=19$m=19456,t=2,p=1$c2FsdHNhbHRzYWx0c2FsdA$aGFzaGhhc2hoYXNoaGFzaGhhc2hoYXNoaGFzaGhhc2g")
(define test-dummy-password-hash
  "$argon2id$v=19$m=19456,t=2,p=1$ZHVtbXlzYWx0ZHVtbXlzYWx0$ZHVtbXloYXNoZHVtbXloYXNoZHVtbXloYXNoZHVtbXloYXNo")

(define (make-test-authentication-service connection #:role [role 'manager])
  (unless (db:connection? connection)
    (raise-argument-error
     'make-test-authentication-service "connection?" connection))
  (db:query-exec
   connection
   #<<SQL
INSERT OR IGNORE INTO operators (operator_id, display_name, active)
VALUES (?, 'HTTP Test Operator', 1)
SQL
   test-operator-id)
  (db:query-exec
   connection
   "INSERT OR IGNORE INTO operator_roles (operator_id, role) VALUES (?, ?)"
   test-operator-id
   (operator-role->string role))
  (db:query-exec
   connection
   #<<SQL
INSERT OR IGNORE INTO operator_pin_credentials
  (operator_id, password_hash, credential_revision)
VALUES (?, ?, 1)
SQL
   test-operator-id test-password-hash)
  (make-authentication-service
   connection
   #:verify-pin
   (lambda (pin password-hash)
     (and (string=? pin test-operator-pin)
          (string=? password-hash test-password-hash)))
   #:dummy-password-hash test-dummy-password-hash))

(define (issue-test-access-token service)
  (define result
    (authentication-service-login service test-operator-id test-operator-pin))
  (unless (authentication-login-succeeded? result)
    (error 'issue-test-access-token "test login unexpectedly failed"))
  (authentication-login-succeeded-access-token result))

(define (test-authorization-header token)
  (header
   #"Authorization"
   (string->bytes/utf-8 (string-append "Bearer " token))))
