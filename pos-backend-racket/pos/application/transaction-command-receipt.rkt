#lang racket

(require "transaction-command.rkt")

(provide (struct-out transaction-command-receipt))

(define supported-outcome-kinds
  '(accepted
    domain-rejected
    not-found
    already-exists
    version-conflict))

(struct transaction-command-receipt
  (command outcome-kind outcome-code outcome-stream-version)
  #:transparent
  #:guard
  (lambda (command
           outcome-kind
           outcome-code
           outcome-stream-version
           type-name)
    (unless (transaction-command? command)
      (raise-argument-error type-name "transaction-command?" command))
    (unless (memq outcome-kind supported-outcome-kinds)
      (raise-argument-error
       type-name
       "supported transaction command receipt outcome kind"
       outcome-kind))
    (unless (and (string? outcome-code)
                 (positive? (string-length outcome-code)))
      (raise-argument-error type-name "non-empty string?" outcome-code))
    (unless (exact-nonnegative-integer? outcome-stream-version)
      (raise-argument-error
       type-name
       "exact-nonnegative-integer?"
       outcome-stream-version))
    (values command
            outcome-kind
            (string->immutable-string outcome-code)
            outcome-stream-version)))
