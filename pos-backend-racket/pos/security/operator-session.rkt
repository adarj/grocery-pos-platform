#lang racket

(require file/sha1
         racket/random)

(provide operator-session-idle-timeout-ms
         operator-session-absolute-timeout-ms
         operator-session-token-valid-shape?
         (struct-out operator-session)
         (struct-out issued-operator-session)
         (struct-out operator-session-expiration)
         make-operator-session-store
         operator-session-store?
         operator-session-store-current
         operator-session-store-issue!
         operator-session-store-find
         operator-session-store-find/observed
         operator-session-store-refresh!
         operator-session-store-invalidate!)

(define operator-session-idle-timeout-ms (* 5 60 1000))
(define operator-session-absolute-timeout-ms (* 12 60 60 1000))
(define token-prefix "gpos_s1_")
(define token-digest-domain #"grocery-pos/register-session/v1\0")

;; This server-side record contains only a digest of the capability. It is
;; deliberately process-local and never belongs in SQLite or a filesystem.
(struct operator-session
  (session-id
   token-digest
   operator-id
   credential-revision
   created-at-monotonic-ms
   last-activity-at-monotonic-ms
   absolute-expires-at-monotonic-ms
   absolute-expires-at-epoch-ms)
  #:transparent)

;; The raw token crosses this issuance boundary once for the login response.
(struct issued-operator-session
  (access-token
   session-id
   operator-id
   credential-revision
   created-at-epoch-ms
   absolute-expires-at-epoch-ms)
  #:transparent)

;; Safe observation returned only after leaving the session-store semaphore.
;; It contains no bearer token or token digest.
(struct operator-session-expiration (session-id operator-id reason)
  #:transparent)

(struct operator-session-store
  (lock current-box current-monotonic-ms current-epoch-ms random-bytes)
  #:transparent)

(define (system-current-monotonic-ms)
  (inexact->exact (floor (current-inexact-monotonic-milliseconds))))

(define (system-current-epoch-ms)
  (inexact->exact (floor (current-inexact-milliseconds))))

(define (check-zero-argument-procedure who value name)
  (unless (and (procedure? value) (procedure-arity-includes? value 0))
    (raise-arguments-error who "expected zero-argument procedure" name value)))

(define (make-operator-session-store
         #:current-monotonic-ms
         [current-monotonic-ms system-current-monotonic-ms]
         #:current-epoch-ms [current-epoch-ms system-current-epoch-ms]
         #:random-bytes [random-bytes crypto-random-bytes])
  (check-zero-argument-procedure
   'make-operator-session-store current-monotonic-ms "current-monotonic-ms")
  (check-zero-argument-procedure
   'make-operator-session-store current-epoch-ms "current-epoch-ms")
  (unless (and (procedure? random-bytes)
               (procedure-arity-includes? random-bytes 1))
    (raise-arguments-error
     'make-operator-session-store
     "expected one-argument random byte provider"
     "random-bytes"
     random-bytes))
  (operator-session-store
   (make-semaphore 1)
   (box #f)
   current-monotonic-ms
   current-epoch-ms
   random-bytes))

(define (check-store who store)
  (unless (operator-session-store? store)
    (raise-argument-error who "operator-session-store?" store)))

(define (operator-session-token-valid-shape? token)
  (and (string? token)
       (regexp-match? #px"^gpos_s1_[0-9a-f]{64}$" token)))

(define (token->digest token)
  (sha256-bytes
   (bytes-append token-digest-domain (string->bytes/utf-8 token))))

(define (constant-time-bytes=? left right)
  (and (= (bytes-length left) (bytes-length right))
       (zero?
        (for/fold ([difference 0])
                  ([left-byte (in-bytes left)]
                   [right-byte (in-bytes right)])
          (bitwise-ior difference (bitwise-xor left-byte right-byte))))))

(define (session-matches-token? session token)
  (constant-time-bytes=?
   (operator-session-token-digest session)
   (token->digest token)))

(define (session-expiration-reason session monotonic-now)
  (cond
    [(>= monotonic-now
         (operator-session-absolute-expires-at-monotonic-ms session))
     'absolute_timeout]
    [(>= (- monotonic-now
            (operator-session-last-activity-at-monotonic-ms session))
         operator-session-idle-timeout-ms)
     'idle_timeout]
    [else #f]))

(define (operator-session-store-current store)
  (check-store 'operator-session-store-current store)
  (call-with-semaphore
   (operator-session-store-lock store)
   (lambda () (unbox (operator-session-store-current-box store)))))

(define (operator-session-store-issue! store operator-id credential-revision)
  (check-store 'operator-session-store-issue! store)
  (unless (and (string? operator-id) (positive? (string-length operator-id)))
    (raise-argument-error
     'operator-session-store-issue! "non-empty-string?" operator-id))
  (unless (and (exact-integer? credential-revision)
               (positive? credential-revision))
    (raise-argument-error
     'operator-session-store-issue! "exact-positive-integer?" credential-revision))
  (call-with-semaphore
   (operator-session-store-lock store)
   (lambda ()
     (define monotonic-now
       ((operator-session-store-current-monotonic-ms store)))
     (define epoch-now ((operator-session-store-current-epoch-ms store)))
     (define token
       (string-append
        token-prefix
        (bytes->hex-string
         ((operator-session-store-random-bytes store) 32))))
     (define session-id
       (string-append
        "session_"
        (bytes->hex-string
         ((operator-session-store-random-bytes store) 16))))
     (define absolute-expires-at-monotonic-ms
       (+ monotonic-now operator-session-absolute-timeout-ms))
     (define absolute-expires-at-epoch-ms
       (+ epoch-now operator-session-absolute-timeout-ms))
     (define session
       (operator-session
        session-id
        (token->digest token)
        operator-id
        credential-revision
        monotonic-now
        monotonic-now
        absolute-expires-at-monotonic-ms
        absolute-expires-at-epoch-ms))
     ;; Replacing this single slot invalidates the previous register session.
     (set-box! (operator-session-store-current-box store) session)
     (issued-operator-session
      token
      session-id
      operator-id
      credential-revision
      epoch-now
      absolute-expires-at-epoch-ms))))

(define (find-under-lock store token refresh? report-expiration?)
  (cond
    [(not (operator-session-token-valid-shape? token)) #f]
    [else
     (define current (unbox (operator-session-store-current-box store)))
     (cond
       [(or (not current) (not (session-matches-token? current token))) #f]
       [else
        (define monotonic-now
          ((operator-session-store-current-monotonic-ms store)))
        (cond
          [(session-expiration-reason current monotonic-now)
           => (lambda (reason)
           (set-box! (operator-session-store-current-box store) #f)
           (and report-expiration?
                (operator-session-expiration
                 (operator-session-session-id current)
                 (operator-session-operator-id current)
                 reason)))]
          [refresh?
           (define refreshed
             (struct-copy operator-session current
                          [last-activity-at-monotonic-ms monotonic-now]))
           (set-box! (operator-session-store-current-box store) refreshed)
           refreshed]
          [else current])])]))

(define (operator-session-store-find store token)
  (check-store 'operator-session-store-find store)
  (call-with-semaphore
   (operator-session-store-lock store)
   (lambda () (find-under-lock store token #f #f))))

(define (operator-session-store-find/observed store token)
  (check-store 'operator-session-store-find/observed store)
  (call-with-semaphore
   (operator-session-store-lock store)
   (lambda () (find-under-lock store token #f #t))))

(define (operator-session-store-refresh! store token)
  (check-store 'operator-session-store-refresh! store)
  (call-with-semaphore
   (operator-session-store-lock store)
   (lambda () (find-under-lock store token #t #f))))

(define (operator-session-store-invalidate! store token)
  (check-store 'operator-session-store-invalidate! store)
  (call-with-semaphore
   (operator-session-store-lock store)
   (lambda ()
     (when (and (operator-session-token-valid-shape? token)
                (let ([current
                       (unbox (operator-session-store-current-box store))])
                  (and current (session-matches-token? current token))))
       (set-box! (operator-session-store-current-box store) #f))))
  (void))
