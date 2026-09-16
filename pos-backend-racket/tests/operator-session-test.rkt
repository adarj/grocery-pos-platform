#lang racket

(require rackunit
         "../pos/security/operator-session.rkt")

(define (make-deterministic-random)
  (define next-byte (box 0))
  (lambda (count)
    (define byte (modulo (unbox next-byte) 256))
    (set-box! next-byte (add1 (unbox next-byte)))
    (make-bytes count byte)))

(module+ test
  (test-case "session tokens are opaque 256-bit values and raw tokens are not retained"
    (define monotonic-now (box 1000))
    (define epoch-now (box 1700000000000))
    (define store
      (make-operator-session-store
       #:current-monotonic-ms (lambda () (unbox monotonic-now))
       #:current-epoch-ms (lambda () (unbox epoch-now))
       #:random-bytes (make-deterministic-random)))
    (define issued (operator-session-store-issue! store "operator-1" 3))
    (define token (issued-operator-session-access-token issued))
    (check-regexp-match #px"^gpos_s1_[0-9a-f]{64}$" token)
    (define retained (operator-session-store-current store))
    (check-false (equal? token (operator-session-token-digest retained)))
    (check-false (regexp-match? (regexp-quote token) (format "~s" retained)))
    (check-equal? (operator-session-operator-id retained) "operator-1")
    (check-equal? (operator-session-credential-revision retained) 3))

  (test-case "one register session replaces the prior session"
    (define store
      (make-operator-session-store #:random-bytes (make-deterministic-random)))
    (define first (operator-session-store-issue! store "first" 1))
    (define second (operator-session-store-issue! store "second" 1))
    (check-false
     (operator-session-store-find
      store (issued-operator-session-access-token first)))
    (check-equal?
     (operator-session-operator-id
      (operator-session-store-find
       store (issued-operator-session-access-token second)))
     "second"))

  (test-case "normal idle expiry uses monotonic elapsed time"
    (define monotonic-now (box 0))
    (define epoch-now (box 1700000000000))
    (define store
      (make-operator-session-store
       #:current-monotonic-ms (lambda () (unbox monotonic-now))
       #:current-epoch-ms (lambda () (unbox epoch-now))
       #:random-bytes (make-deterministic-random)))
    (define issued (operator-session-store-issue! store "operator-1" 1))
    (define token (issued-operator-session-access-token issued))
    (set-box! monotonic-now (sub1 operator-session-idle-timeout-ms))
    (check-not-false (operator-session-store-find store token))
    (set-box! monotonic-now operator-session-idle-timeout-ms)
    (check-false (operator-session-store-find store token))
    (check-false (operator-session-store-current store)))

  (test-case "normal absolute expiry uses monotonic elapsed time"
    (define monotonic-now (box 0))
    (define store
      (make-operator-session-store
       #:current-monotonic-ms (lambda () (unbox monotonic-now))
       #:current-epoch-ms (lambda () 1700000000000)
       #:random-bytes (make-deterministic-random)))
    (define issued (operator-session-store-issue! store "operator-1" 1))
    (define token (issued-operator-session-access-token issued))
    (for ([now (in-range (sub1 operator-session-idle-timeout-ms)
                         operator-session-absolute-timeout-ms
                         (sub1 operator-session-idle-timeout-ms))])
      (set-box! monotonic-now now)
      (check-not-false (operator-session-store-refresh! store token)))
    (set-box! monotonic-now operator-session-absolute-timeout-ms)
    (check-false (operator-session-store-find store token)))

  (test-case "wall-clock rollback does not extend an idle session"
    (define monotonic-now (box 1000))
    (define epoch-now (box 1700000000000))
    (define store
      (make-operator-session-store
       #:current-monotonic-ms (lambda () (unbox monotonic-now))
       #:current-epoch-ms (lambda () (unbox epoch-now))
       #:random-bytes (make-deterministic-random)))
    (define issued (operator-session-store-issue! store "operator-1" 1))
    (define token (issued-operator-session-access-token issued))
    (set-box! epoch-now 1000)
    (set-box! monotonic-now (+ 1000 operator-session-idle-timeout-ms))
    (check-false (operator-session-store-find store token)))

  (test-case "wall-clock jump forward does not prematurely expire a session"
    (define monotonic-now (box 1000))
    (define epoch-now (box 1700000000000))
    (define store
      (make-operator-session-store
       #:current-monotonic-ms (lambda () (unbox monotonic-now))
       #:current-epoch-ms (lambda () (unbox epoch-now))
       #:random-bytes (make-deterministic-random)))
    (define issued (operator-session-store-issue! store "operator-1" 1))
    (define token (issued-operator-session-access-token issued))
    (set-box! epoch-now (+ (unbox epoch-now)
                           (* 10 operator-session-absolute-timeout-ms)))
    (set-box! monotonic-now 2000)
    (check-not-false (operator-session-store-find store token)))

  (test-case "monotonic idle refresh never moves the absolute deadline"
    (define monotonic-now (box 0))
    (define epoch-now (box 1700000000000))
    (define store
      (make-operator-session-store
       #:current-monotonic-ms (lambda () (unbox monotonic-now))
       #:current-epoch-ms (lambda () (unbox epoch-now))
       #:random-bytes (make-deterministic-random)))
    (define issued (operator-session-store-issue! store "operator-1" 1))
    (define token (issued-operator-session-access-token issued))
    (define absolute-monotonic
      (operator-session-absolute-expires-at-monotonic-ms
       (operator-session-store-current store)))
    (define absolute-epoch
      (issued-operator-session-absolute-expires-at-epoch-ms issued))
    (set-box! monotonic-now (sub1 operator-session-idle-timeout-ms))
    (define refreshed (operator-session-store-refresh! store token))
    (check-equal?
     (operator-session-last-activity-at-monotonic-ms refreshed)
     (unbox monotonic-now))
    (check-equal?
     (operator-session-absolute-expires-at-monotonic-ms refreshed)
     absolute-monotonic)
    (check-equal?
     (operator-session-absolute-expires-at-epoch-ms refreshed)
     absolute-epoch))

  (test-case "idle expiry logout and store reconstruction invalidate tokens"
    (define monotonic-now (box 100))
    (define epoch-now (box 1700000000000))
    (define random (make-deterministic-random))
    (define store
      (make-operator-session-store
       #:current-monotonic-ms (lambda () (unbox monotonic-now))
       #:current-epoch-ms (lambda () (unbox epoch-now))
       #:random-bytes random))
    (define issued (operator-session-store-issue! store "operator-1" 1))
    (define token (issued-operator-session-access-token issued))
    (operator-session-store-invalidate! store token)
    (check-false (operator-session-store-find store token))
    (define reissued (operator-session-store-issue! store "operator-1" 1))
    (define reissued-token (issued-operator-session-access-token reissued))
    (set-box! monotonic-now
              (+ (unbox monotonic-now) operator-session-idle-timeout-ms))
    (check-false (operator-session-store-find store reissued-token))
    (define reconstructed
      (make-operator-session-store
       #:current-monotonic-ms (lambda () (unbox monotonic-now))
       #:current-epoch-ms (lambda () (unbox epoch-now))
       #:random-bytes random))
    (check-false (operator-session-store-find reconstructed reissued-token)))

  (test-case "malformed tokens fail without changing the current session"
    (define store
      (make-operator-session-store #:random-bytes (make-deterministic-random)))
    (operator-session-store-issue! store "operator-1" 1)
    (define before (operator-session-store-current store))
    (for ([token (in-list '(#f "" "Bearer token" "gpos_s1_short"
                              "gpos_s1_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"))])
      (check-false (operator-session-store-find store token)))
    (check-equal? (operator-session-store-current store) before)))
