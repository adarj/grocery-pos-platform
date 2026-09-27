#lang racket

(require rackunit
         "../pos/security/transaction-void-approval.rkt")

(define monotonic-now (box 1000))
(define epoch-now (box 500000))
(define random-counter (box 0))

(define (deterministic-random-bytes count)
  (define seed (unbox random-counter))
  (set-box! random-counter (add1 seed))
  (make-bytes count (modulo (+ seed 17) 256)))

(module+ test
  (test-case "approval capability uses 256 random bits and retains only its digest"
    (define authority
      (make-transaction-void-approval-authority
       #:issuer-instance-id "approval_instance_test"
       #:current-monotonic-ms (lambda () (unbox monotonic-now))
       #:current-epoch-ms (lambda () (unbox epoch-now))
       #:random-bytes deterministic-random-bytes))
    (define first (transaction-void-approval-authority-issue authority))
    (define second (transaction-void-approval-authority-issue authority))
    (check-true
     (transaction-void-approval-token-valid-shape?
      (issued-transaction-void-approval-token first)))
    (check-equal?
     (string-length (issued-transaction-void-approval-token first))
     (+ (string-length "gpos_a1_") 64))
    (check-not-equal?
     (issued-transaction-void-approval-token first)
     (issued-transaction-void-approval-token second))
    (check-equal?
     (bytes-length
      (transaction-void-approval-capability-token-digest
       (issued-transaction-void-approval-capability first)))
     32)
    (check-false
     (string-contains?
      (format "~e" (issued-transaction-void-approval-capability first))
      (issued-transaction-void-approval-token first)))
    (for ([format-string (in-list '("~a" "~v" "~e"))])
      (check-false
       (string-contains?
        (format format-string first)
        (issued-transaction-void-approval-token first)))))

  (test-case "approval deadlines use monotonic time with separate epoch metadata"
    (define authority
      (make-transaction-void-approval-authority
       #:issuer-instance-id "approval_instance_clock"
       #:current-monotonic-ms (lambda () (unbox monotonic-now))
       #:current-epoch-ms (lambda () (unbox epoch-now))
       #:random-bytes deterministic-random-bytes))
    (set-box! monotonic-now 7000)
    (set-box! epoch-now 900000)
    (define issued (transaction-void-approval-authority-issue authority))
    (check-equal?
     (issued-transaction-void-approval-granted-at-monotonic-ms issued)
     7000)
    (check-equal?
     (issued-transaction-void-approval-expires-at-monotonic-ms issued)
     (+ 7000 transaction-void-approval-lifetime-ms))
    (check-equal?
     (issued-transaction-void-approval-expires-at-epoch-ms issued)
     (+ 900000 transaction-void-approval-lifetime-ms))
    (check-equal?
     (transaction-void-approval-authority-issuer-instance-id authority)
     "approval_instance_clock"))

  (test-case "malformed approval tokens never produce a digest capability"
    (for ([token (in-list
                  '(#f
                    ""
                    "gpos_a1_short"
                    "gpos_a1_ABCDEF0000000000000000000000000000000000000000000000000000"
                    "gpos_s1_0000000000000000000000000000000000000000000000000000000000000000"))])
      (check-false (transaction-void-approval-token->capability token)))))
