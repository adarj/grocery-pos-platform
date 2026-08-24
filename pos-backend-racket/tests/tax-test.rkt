#lang racket

(require rackunit
         "../pos/domain/money.rkt"
         "../pos/domain/tax.rkt")

(module+ test
  (test-case "line tax uses exact integer millionths and half-up rounding"
    (check-equal? (calculate-line-tax (money 0) (tax-rate 100000))
                  (money 0))
    (check-equal? (calculate-line-tax (money 199) (tax-rate 0))
                  (money 0))
    (check-equal? (calculate-line-tax (money 199) (tax-rate 100000))
                  (money 20))
    (check-equal? (calculate-line-tax (money 199) (tax-rate 88750))
                  (money 18))
    (check-equal? (calculate-line-tax (money 5) (tax-rate 100000))
                  (money 1))
    (check-equal? (calculate-line-tax (money 4) (tax-rate 100000))
                  (money 0))
    (check-equal? (calculate-line-tax (money 100) (tax-rate 1000000))
                  (money 100)))

  (test-case "tax rates reject values outside exact integer millionths"
    (for ([invalid-rate (in-list (list -1 1000001 1.0 1/2 "100000"))])
      (check-exn exn:fail:contract?
                 (lambda () (tax-rate invalid-rate)))))

  (test-case "line tax requires domain money and tax-rate values"
    (check-exn exn:fail:contract?
               (lambda () (calculate-line-tax 199 (tax-rate 100000))))
    (check-exn exn:fail:contract?
               (lambda () (calculate-line-tax (money 199) 100000)))))
