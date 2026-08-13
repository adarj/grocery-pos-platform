#lang racket

(provide (struct-out money))

(struct money (minor-units)
  #:transparent
  #:guard
  (lambda (minor-units type-name)
    (unless (and (exact-integer? minor-units)
                 (>= minor-units 0))
      (raise-argument-error
       type-name
       "exact nonnegative integer"
       minor-units))
    minor-units))
