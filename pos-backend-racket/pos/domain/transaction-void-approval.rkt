#lang racket

(provide (struct-out transaction-void-approval-grant)
         (struct-out transaction-command-approver-attribution))

(define (non-empty-string? value)
  (and (string? value) (positive? (string-length value))))

(define (exact-nonnegative-integer? value)
  (and (exact-integer? value) (>= value 0)))

(struct transaction-void-approval-grant
  (approval-id
   token-digest
   issuer-instance-id
   requester-operator-id
   approver-operator-id
   approver-credential-revision
   command-id
   transaction-id
   command-schema-version
   expected-version
   granted-at-monotonic-ms
   expires-at-monotonic-ms
   expires-at-epoch-ms)
  #:transparent
  #:guard
  (lambda (approval-id
           token-digest
           issuer-instance-id
           requester-operator-id
           approver-operator-id
           approver-credential-revision
           command-id
           transaction-id
           command-schema-version
           expected-version
           granted-at-monotonic-ms
           expires-at-monotonic-ms
           expires-at-epoch-ms
           type-name)
    (for ([value (in-list
                  (list approval-id issuer-instance-id requester-operator-id
                        approver-operator-id command-id transaction-id))]
          [name (in-list
                 '(approval-id issuer-instance-id requester-operator-id
                   approver-operator-id command-id transaction-id))])
      (unless (non-empty-string? value)
        (raise-arguments-error
         type-name "expected non-empty identity" (symbol->string name) value)))
    (unless (and (bytes? token-digest) (= (bytes-length token-digest) 32))
      (raise-argument-error type-name "32-byte digest" token-digest))
    (when (string=? requester-operator-id approver-operator-id)
      (raise-arguments-error
       type-name "requester and approver must differ" "operator ID" requester-operator-id))
    (unless (and (exact-integer? approver-credential-revision)
                 (positive? approver-credential-revision))
      (raise-argument-error
       type-name "exact positive credential revision" approver-credential-revision))
    (unless (and (exact-integer? command-schema-version)
                 (= command-schema-version 1))
      (raise-argument-error
       type-name "Transaction Command Schema v1" command-schema-version))
    (for ([value (in-list
                  (list expected-version granted-at-monotonic-ms
                        expires-at-epoch-ms))]
          [name (in-list
                 '(expected-version granted-at-monotonic-ms
                   expires-at-epoch-ms))])
      (unless (exact-nonnegative-integer? value)
        (raise-arguments-error
         type-name "expected exact nonnegative integer" (symbol->string name) value)))
    (unless (and (exact-integer? expires-at-monotonic-ms)
                 (> expires-at-monotonic-ms granted-at-monotonic-ms))
      (raise-arguments-error
       type-name
       "monotonic expiry must follow grant time"
       "expires-at-monotonic-ms"
       expires-at-monotonic-ms))
    (values
     (string->immutable-string approval-id)
     (bytes->immutable-bytes token-digest)
     (string->immutable-string issuer-instance-id)
     (string->immutable-string requester-operator-id)
     (string->immutable-string approver-operator-id)
     approver-credential-revision
     (string->immutable-string command-id)
     (string->immutable-string transaction-id)
     command-schema-version
     expected-version
     granted-at-monotonic-ms
     expires-at-monotonic-ms
     expires-at-epoch-ms)))

(struct transaction-command-approver-attribution
  (command-id
   approval-id
   approver-operator-id
   approver-credential-revision
   approved-at-epoch-ms)
  #:transparent
  #:guard
  (lambda (command-id approval-id approver-operator-id
                      approver-credential-revision approved-at-epoch-ms
                      type-name)
    (for ([value (in-list (list command-id approval-id approver-operator-id))]
          [name (in-list '(command-id approval-id approver-operator-id))])
      (unless (non-empty-string? value)
        (raise-arguments-error
         type-name "expected non-empty identity" (symbol->string name) value)))
    (unless (and (exact-integer? approver-credential-revision)
                 (positive? approver-credential-revision))
      (raise-argument-error
       type-name "exact positive credential revision" approver-credential-revision))
    (unless (exact-nonnegative-integer? approved-at-epoch-ms)
      (raise-argument-error
       type-name "exact nonnegative epoch milliseconds" approved-at-epoch-ms))
    (values
     (string->immutable-string command-id)
     (string->immutable-string approval-id)
     (string->immutable-string approver-operator-id)
     approver-credential-revision
     approved-at-epoch-ms)))
