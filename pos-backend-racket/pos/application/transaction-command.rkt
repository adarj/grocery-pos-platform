#lang racket

(require "../domain/money.rkt")

(provide transaction-command?
         transaction-command-command-id
         transaction-command-transaction-id
         transaction-command-expected-version
         (struct-out start-transaction-command)
         (struct-out scan-barcode-command)
         (struct-out tender-cash-command)
         (struct-out complete-transaction-command))

(define (non-empty-string? value)
  (and (string? value)
       (positive? (string-length value))))

;; The base constructor is deliberately private. Only one of the four concrete
;; Schema v1 command variants can cross the application boundary.
(struct transaction-command (command-id transaction-id expected-version)
  #:transparent
  #:guard
  (lambda (command-id transaction-id expected-version type-name)
    (unless (non-empty-string? command-id)
      (raise-argument-error type-name "non-empty string?" command-id))
    (unless (non-empty-string? transaction-id)
      (raise-argument-error type-name "non-empty string?" transaction-id))
    (unless (and (exact-integer? expected-version)
                 (>= expected-version 0))
      (raise-argument-error
       type-name
       "exact nonnegative integer"
       expected-version))
    (values (string->immutable-string command-id)
            (string->immutable-string transaction-id)
            expected-version)))

(struct start-transaction-command transaction-command ()
  #:transparent)

(struct scan-barcode-command transaction-command (barcode)
  #:transparent
  #:guard
  (lambda (command-id transaction-id expected-version barcode type-name)
    (unless (non-empty-string? barcode)
      (raise-argument-error type-name "non-empty string?" barcode))
    (values command-id
            transaction-id
            expected-version
            (string->immutable-string barcode))))

(struct tender-cash-command transaction-command (amount)
  #:transparent
  #:guard
  (lambda (command-id transaction-id expected-version amount type-name)
    (unless (money? amount)
      (raise-argument-error type-name "money?" amount))
    (values command-id transaction-id expected-version amount)))

(struct complete-transaction-command transaction-command ()
  #:transparent)
