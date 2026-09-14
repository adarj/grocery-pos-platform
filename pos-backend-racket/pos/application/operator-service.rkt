#lang racket

(require (prefix-in db: db)
         "../domain/operator-identity.rkt"
         "../persistence/sqlite-operators.rkt"
         "../security/operator-pin.rkt")

(provide make-operator-service
         operator-service?
         operator-service-load
         operator-service-list
         operator-service-create
         operator-service-set-role
         operator-service-set-active
         (struct-out operator-pin-enrollment-succeeded)
         (struct-out operator-pin-enrollment-rejected)
         (struct-out operator-pin-verification)
         operator-service-enroll-pin
         operator-service-verify-pin)

(struct operator-service (connection hash-pin verify-pin-provider) #:transparent)
(struct operator-pin-enrollment-succeeded (operator-id credential-revision)
  #:transparent)
(struct operator-pin-enrollment-rejected (code) #:transparent)
(struct operator-pin-verification (verified? code credential-revision)
  #:transparent)

(define (check-provider who provider arity name)
  (unless (and (procedure? provider)
               (procedure-arity-includes? provider arity))
    (raise-arguments-error who "invalid credential provider" name provider)))

(define (make-operator-service
         connection
         #:hash-pin [hash-pin hash-operator-pin]
         #:verify-pin [verify-pin verify-operator-pin])
  (define who 'make-operator-service)
  (unless (db:connection? connection)
    (raise-argument-error who "connection?" connection))
  (check-provider who hash-pin 1 "hash-pin")
  (check-provider who verify-pin 2 "verify-pin")
  (operator-service connection hash-pin verify-pin))

(define (check-service who service)
  (unless (operator-service? service)
    (raise-argument-error who "operator-service?" service)))

(define (operator-service-load service operator-id)
  (check-service 'operator-service-load service)
  (load-operator (operator-service-connection service) operator-id))

(define (operator-service-list service)
  (check-service 'operator-service-list service)
  (list-operators (operator-service-connection service)))

(define (operator-service-create service operator-id display-name role)
  (check-service 'operator-service-create service)
  (create-operator!
   (operator-service-connection service) operator-id display-name role))

(define (operator-service-set-role service operator-id role)
  (check-service 'operator-service-set-role service)
  (set-operator-role!
   (operator-service-connection service) operator-id role))

(define (operator-service-set-active service operator-id active?)
  (check-service 'operator-service-set-active service)
  (set-operator-active!
   (operator-service-connection service) operator-id active?))

(define (operator-service-enroll-pin service operator-id pin)
  (check-service 'operator-service-enroll-pin service)
  (define connection (operator-service-connection service))
  (cond
    [(not (operator-pin-valid? pin))
     (operator-pin-enrollment-rejected 'pin-policy-rejected)]
    [(not (load-operator connection operator-id))
     (operator-pin-enrollment-rejected 'operator-not-found)]
    [(load-operator-pin-record connection operator-id)
     (operator-pin-enrollment-rejected 'credential-already-enrolled)]
    [else
     ;; This intentionally happens before store-initial-operator-pin! enters
     ;; BEGIN IMMEDIATE. The transaction re-reads state and arbitrates races.
     (define password-hash
       ((operator-service-hash-pin service) pin))
     (define stored
       (store-initial-operator-pin! connection operator-id password-hash))
     (cond
       [(operator-pin-store-succeeded? stored)
        (operator-pin-enrollment-succeeded
         operator-id
         (operator-pin-store-succeeded-credential-revision stored))]
       [else
        (operator-pin-enrollment-rejected
         (operator-pin-store-rejected-code stored))])]))

(define (operator-service-verify-pin service operator-id pin)
  (check-service 'operator-service-verify-pin service)
  (define connection (operator-service-connection service))
  (define operator (load-operator connection operator-id))
  (cond
    [(not operator)
     (operator-pin-verification #f 'operator-not-found #f)]
    [(not (operator-identity-active? operator))
     (operator-pin-verification #f 'operator-inactive #f)]
    [else
     (define credential (load-operator-pin-record connection operator-id))
     (cond
       [(not credential)
        (operator-pin-verification #f 'credential-enrollment-required #f)]
       [else
        (define verified?
          ((operator-service-verify-pin-provider service)
           pin
           (operator-pin-record-password-hash credential)))
        (operator-pin-verification
         (and verified? #t)
         (if verified? 'verified 'invalid-credential)
         (operator-pin-record-credential-revision credential))])]))
