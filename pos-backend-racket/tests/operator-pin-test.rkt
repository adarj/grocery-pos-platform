#lang racket

(require rackunit
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
