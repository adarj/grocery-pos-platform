#lang racket

(require rackunit
         "../pos/support/health.rkt")

(module+ test
  (define payload (current-health))

  (check-true (hash-ref payload 'ok))
  (check-equal? (hash-ref payload 'service) "grocery-pos-core")
  (check-equal? (hash-ref payload 'version) "0.0.0-dev")
  (check-equal? (hash-ref payload 'environment) "dev"))
