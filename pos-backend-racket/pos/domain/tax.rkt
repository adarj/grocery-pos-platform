#lang racket

(require "money.rkt")

(provide (struct-out tax-rate)
         calculate-line-tax)

(define rate-scale 1000000)
(define half-rate-scale 500000)

(struct tax-rate (millionths)
  #:transparent
  #:guard
  (lambda (millionths type-name)
    (unless (and (exact-integer? millionths)
                 (<= 0 millionths rate-scale))
      (raise-argument-error
       type-name
       "exact integer from 0 through 1000000"
       millionths))
    millionths))

(define (calculate-line-tax unit-price rate)
  (unless (money? unit-price)
    (raise-argument-error 'calculate-line-tax "money?" unit-price))
  (unless (tax-rate? rate)
    (raise-argument-error 'calculate-line-tax "tax-rate?" rate))
  (money
   (quotient
    (+ (* (money-minor-units unit-price)
          (tax-rate-millionths rate))
       half-rate-scale)
    rate-scale)))
