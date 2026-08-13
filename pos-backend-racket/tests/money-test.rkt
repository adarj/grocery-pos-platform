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
               (lambda () (money 1.99)))))
