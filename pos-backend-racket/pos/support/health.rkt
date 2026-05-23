#lang racket

(provide current-health)

(define (env-or-default name default)
  (define value (getenv name))
  (if (and value (not (string=? value "")))
      value
      default))

(define (current-health)
  (hasheq
   'ok #t
   'service "grocery-pos-core"
   'version "0.0.0-dev"
   'environment (env-or-default "GROCERY_POS_ENV" "dev")))
