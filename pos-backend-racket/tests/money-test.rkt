#lang racket

(require rackunit
         "../pos/domain/money.rkt")

(module+ test
  (test-case "money preserves an exact nonnegative minor-unit amount"
    (check-equal? (money-minor-units (money 0)) 0)
    (check-equal? (money-minor-units (money 199)) 199))

  (test-case "money rejects a negative minor-unit amount"
    (check-exn exn:fail:contract?
               (lambda () (money -1))))

  (test-case "money rejects an inexact amount"
    (check-exn exn:fail:contract?
               (lambda () (money 1.99))))

  (test-case "money rejects an exact non-integer amount"
    (define fractional-minor-units 199/100)

    (check-true (exact? fractional-minor-units))
    (check-false (integer? fractional-minor-units))
    (check-exn exn:fail:contract?
               (lambda () (money fractional-minor-units)))))
