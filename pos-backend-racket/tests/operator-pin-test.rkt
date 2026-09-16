#lang racket

(require crypto
         crypto/argon2
         rackunit
         "../pos/security/operator-pin.rkt")

(module+ test
  (test-case "PIN policy accepts only nontrivial 8-12 ASCII digits"
    (for ([pin (in-list '("80421637" "804216379" "8042163790"
                           "80421637901" "804216379015"))])
      (check-true (operator-pin-valid? pin) pin))
    (for ([pin (in-list '("8042163"
                           "8042163790159"
                           "8042 1637"
                           " 80421637"
                           "８０４２１６３７"
                           "11111111"
                           "12121212"
                           "12345678"
                           "98765432"
                           "34567890"
                           "56789012"
                           "21098765"))])
      (check-false (operator-pin-valid? pin) pin)))

  (test-case "Argon2id hashing uses the frozen parameters and unique salts"
    (define pin "80421637")
    (define first (hash-operator-pin pin))
    (define second (hash-operator-pin pin))
    (check-regexp-match #rx"^\\$argon2id\\$v=19\\$m=19456,t=2,p=1\\$" first)
    (check-regexp-match #rx"^\\$argon2id\\$v=19\\$m=19456,t=2,p=1\\$" second)
    (check-not-equal? first second)
    (check-true (verify-operator-pin pin first))
    (check-false (verify-operator-pin "80421638" first)))

  (test-case "verification syntax remains compatible with enrolled weak PINs"
    ;; This bypasses enrollment intentionally to model a credential created
    ;; under an earlier strength policy. Verification format is frozen for
    ;; credential v1 even when new enrollment rejects the value.
    (define weak-pin "12121212")
    (define implementation (get-kdf 'argon2id argon2-factory))
    (define verifier
      (pwhash implementation
              (string->bytes/utf-8 weak-pin)
              `((m ,operator-pin-argon2-memory-kib)
                (t ,operator-pin-argon2-iterations)
                (p ,operator-pin-argon2-parallelism))))
    (check-false (operator-pin-valid? weak-pin))
    (check-true (operator-pin-verification-input-valid? weak-pin))
    (check-true (verify-operator-pin weak-pin verifier)))

  (test-case "unsupported PHC profiles fail before invoking native verification"
    (define provider-called? #f)
    (define (recording-provider _implementation _pin-bytes _password-hash)
      (set! provider-called? #t)
      #t)
    (for ([password-hash
           (in-list
            '("$argon2id$v=19$m=19457,t=2,p=1$c2FsdHNhbHRzYWx0c2FsdA$aGFzaGhhc2hoYXNoaGFzaGhhc2hoYXNoaGFzaGhhc2g"
              "$argon2id$v=19$m=19456,t=999999,p=1$c2FsdHNhbHRzYWx0c2FsdA$aGFzaGhhc2hoYXNoaGFzaGhhc2hoYXNoaGFzaGhhc2g"
              "$argon2id$v=19$m=19456,t=2,p=999$c2FsdHNhbHRzYWx0c2FsdA$aGFzaGhhc2hoYXNoaGFzaGhhc2hoYXNoaGFzaGhhc2g"
              "$argon2id$v=19$m=19456,t=2,p=1,p=1$c2FsdHNhbHRzYWx0c2FsdA$aGFzaGhhc2hoYXNoaGFzaGhhc2hoYXNoaGFzaGhhc2g"
              "$argon2i$v=19$m=19456,t=2,p=1$c2FsdHNhbHRzYWx0c2FsdA$aGFzaGhhc2hoYXNoaGFzaGhhc2hoYXNoaGFzaGhhc2g"
              "$argon2id$v=16$m=19456,t=2,p=1$c2FsdHNhbHRzYWx0c2FsdA$aGFzaGhhc2hoYXNoaGFzaGhhc2hoYXNoaGFzaGhhc2g"
              "$argon2id$v=19$m=19456,t=2,p=1$short$short"
              "$argon2id$malformed"))])
      (set! provider-called? #f)
      (check-false
       (verify-operator-pin
        "80421637"
        password-hash
        #:verify-provider recording-provider))
      (check-false provider-called? password-hash)))

  (test-case "supported PHC profile reaches the configured verification provider"
    (define provider-called? #f)
    (define password-hash
      "$argon2id$v=19$m=19456,t=2,p=1$c2FsdHNhbHRzYWx0c2FsdA$aGFzaGhhc2hoYXNoaGFzaGhhc2hoYXNoaGFzaGhhc2g")
    (check-true
     (verify-operator-pin
      "80421637"
      password-hash
      #:verify-provider
      (lambda (_implementation _pin-bytes received-hash)
        (set! provider-called? #t)
        (string=? received-hash password-hash))))
    (check-true provider-called?))

  (test-case "verification fails closed for other or malformed hash families"
    (check-false (verify-operator-pin "80421637" "$argon2i$malformed"))
    (check-false (verify-operator-pin "80421637" "$argon2id$malformed")))

  (test-case "PIN policy failures do not include the PIN in the error"
    (define sentinel "77777777")
    (with-handlers
        ([exn:fail?
          (lambda (exception)
            (check-false
             (string-contains? (exn-message exception) sentinel)))])
      (hash-operator-pin sentinel)
      (fail "expected PIN policy rejection"))))
