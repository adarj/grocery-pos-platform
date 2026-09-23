#lang racket

(require file/sha1
         racket/random)

(provide transaction-void-approval-lifetime-ms
         transaction-void-approval-token-valid-shape?
         transaction-void-approval-token->capability
         transaction-void-approval-capability?
         transaction-void-approval-capability-token-digest
         make-transaction-void-approval-authority
         transaction-void-approval-authority?
         transaction-void-approval-authority-issuer-instance-id
         transaction-void-approval-authority-current-monotonic-ms
         transaction-void-approval-authority-current-epoch-ms
         transaction-void-approval-authority-issue
         issued-transaction-void-approval?
         issued-transaction-void-approval-token
         issued-transaction-void-approval-approval-id
         issued-transaction-void-approval-capability
         issued-transaction-void-approval-granted-at-monotonic-ms
         issued-transaction-void-approval-expires-at-monotonic-ms
         issued-transaction-void-approval-expires-at-epoch-ms)

(define transaction-void-approval-lifetime-ms (* 90 1000))
(define token-prefix "gpos_a1_")
(define token-digest-domain #"grocery-pos/transaction-void-approval/v1\0")

;; Deliberately opaque: deep layers receive only a digest-bearing capability,
;; and ordinary structural printing cannot disclose even that digest.
(struct transaction-void-approval-capability (token-digest))

;; The raw token crosses this boundary once and is never retained by the
;; authority. This value is likewise opaque to reduce accidental diagnostics.
(struct issued-transaction-void-approval
  (token
   approval-id
   capability
   granted-at-monotonic-ms
   expires-at-monotonic-ms
   expires-at-epoch-ms))

(struct transaction-void-approval-authority
  (issuer-instance-id current-monotonic-ms current-epoch-ms random-bytes))

(define (system-current-monotonic-ms)
  (inexact->exact (floor (current-inexact-monotonic-milliseconds))))

(define (system-current-epoch-ms)
  (inexact->exact (floor (current-inexact-milliseconds))))

(define (non-empty-string? value)
  (and (string? value) (positive? (string-length value))))

(define (check-zero-argument-procedure who value name)
  (unless (and (procedure? value) (procedure-arity-includes? value 0))
    (raise-arguments-error who "expected zero-argument procedure" name value)))

(define (check-random-provider who value)
  (unless (and (procedure? value) (procedure-arity-includes? value 1))
    (raise-arguments-error
     who "expected one-argument random byte provider" "random-bytes" value)))

(define (make-transaction-void-approval-authority
         #:issuer-instance-id [issuer-instance-id #f]
         #:current-monotonic-ms
         [current-monotonic-ms system-current-monotonic-ms]
         #:current-epoch-ms [current-epoch-ms system-current-epoch-ms]
         #:random-bytes [random-bytes crypto-random-bytes])
  (define who 'make-transaction-void-approval-authority)
  (check-zero-argument-procedure
   who current-monotonic-ms "current-monotonic-ms")
  (check-zero-argument-procedure who current-epoch-ms "current-epoch-ms")
  (check-random-provider who random-bytes)
  (define effective-instance-id
    (or issuer-instance-id
        (string-append
         "approval_instance_"
         (bytes->hex-string (random-bytes 16)))))
  (unless (non-empty-string? effective-instance-id)
    (raise-argument-error who "non-empty-string?" effective-instance-id))
  (transaction-void-approval-authority
   (string->immutable-string effective-instance-id)
   current-monotonic-ms
   current-epoch-ms
   random-bytes))

(define (transaction-void-approval-token-valid-shape? token)
  (and (string? token)
       (regexp-match? #px"^gpos_a1_[0-9a-f]{64}$" token)))

(define (transaction-void-approval-token->capability token)
  (and
   (transaction-void-approval-token-valid-shape? token)
   (transaction-void-approval-capability
    (sha256-bytes
     (bytes-append
      token-digest-domain
      (string->bytes/utf-8 token))))))

(define (checked-time who name value)
  (unless (and (exact-integer? value) (>= value 0))
    (raise-arguments-error who "clock returned invalid milliseconds" name value))
  value)

(define (transaction-void-approval-authority-issue authority)
  (define who 'transaction-void-approval-authority-issue)
  (unless (transaction-void-approval-authority? authority)
    (raise-argument-error who "transaction-void-approval-authority?" authority))
  (define monotonic-now
    (checked-time
     who
     "current-monotonic-ms"
     ((transaction-void-approval-authority-current-monotonic-ms authority))))
  (define epoch-now
    (checked-time
     who
     "current-epoch-ms"
     ((transaction-void-approval-authority-current-epoch-ms authority))))
  (define random-bytes
    (transaction-void-approval-authority-random-bytes authority))
  (define token
    (string-append token-prefix (bytes->hex-string (random-bytes 32))))
  (define approval-id
    (string-append "approval_" (bytes->hex-string (random-bytes 16))))
  (define capability
    (transaction-void-approval-token->capability token))
  (unless capability
    (error who "generated an invalid approval capability"))
  (issued-transaction-void-approval
   token
   approval-id
   capability
   monotonic-now
   (+ monotonic-now transaction-void-approval-lifetime-ms)
   (+ epoch-now transaction-void-approval-lifetime-ms)))
