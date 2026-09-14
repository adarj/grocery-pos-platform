#lang racket

(require crypto
         crypto/argon2)

(provide operator-pin-minimum-length
         operator-pin-maximum-length
         operator-pin-argon2-memory-kib
         operator-pin-argon2-iterations
         operator-pin-argon2-parallelism
         operator-pin-valid?
         hash-operator-pin
         verify-operator-pin)

(define operator-pin-minimum-length 8)
(define operator-pin-maximum-length 12)
(define operator-pin-argon2-memory-kib 19456)
(define operator-pin-argon2-iterations 2)
(define operator-pin-argon2-parallelism 1)

(define (repeated-motif? pin width)
  (and (zero? (remainder (string-length pin) width))
       (string=?
        pin
        (apply string-append
               (make-list (/ (string-length pin) width)
                          (substring pin 0 width))))))

(define (simple-numeric-sequence? pin)
  (define (digit-at index)
    (- (char->integer (string-ref pin index))
       (char->integer #\0)))
  (define (follows-step? step)
    (for/and ([index (in-range 1 (string-length pin))])
      (= (digit-at index)
         (modulo (+ (digit-at (sub1 index)) step) 10))))
  (or (follows-step? 1)
      (follows-step? -1)))

(define (operator-pin-valid? pin)
  (and (string? pin)
       (regexp-match? #px"^[0-9]{8,12}$" pin)
       (not (repeated-motif? pin 1))
       (not (repeated-motif? pin 2))
       (not (simple-numeric-sequence? pin))))

(define argon2id-implementation
  (get-kdf 'argon2id argon2-factory))

(unless argon2id-implementation
  (error 'operator-pin "Argon2id provider is unavailable"))

(define argon2id-config
  `((m ,operator-pin-argon2-memory-kib)
    (t ,operator-pin-argon2-iterations)
    (p ,operator-pin-argon2-parallelism)))

(define (call-with-pin-bytes pin procedure)
  (define pin-bytes (string->bytes/utf-8 pin))
  (dynamic-wind
    void
    (lambda () (procedure pin-bytes))
    (lambda ()
      ;; This limits one avoidable copy; Racket's garbage collector does not
      ;; provide a deterministic whole-process zeroization guarantee.
      (bytes-fill! pin-bytes 0))))

(define (hash-operator-pin pin)
  (unless (operator-pin-valid? pin)
    (raise-arguments-error
     'hash-operator-pin
     "PIN does not satisfy policy"))
  (call-with-pin-bytes
   pin
   (lambda (pin-bytes)
     (pwhash argon2id-implementation pin-bytes argon2id-config))))

(define (verify-operator-pin pin password-hash)
  (and
   (operator-pin-valid? pin)
   (string? password-hash)
   (string-prefix? password-hash "$argon2id$")
   (with-handlers ([exn:fail? (lambda (_exception) #f)])
     (call-with-pin-bytes
      pin
      (lambda (pin-bytes)
        (pwhash-verify argon2id-implementation pin-bytes password-hash))))))
