#lang racket

(require web-server/safety-limits)

(provide pos-http-max-concurrent
         pos-http-max-waiting
         pos-http-request-read-timeout-seconds
         pos-http-max-request-body-bytes
         pos-http-response-timeout-seconds
         pos-http-response-send-timeout-seconds
         pos-http-safety-limits)

(define pos-http-max-concurrent 64)
(define pos-http-max-waiting 64)
(define pos-http-request-read-timeout-seconds 10)
(define pos-http-max-request-body-bytes (* 64 1024))
(define pos-http-response-timeout-seconds 30)
(define pos-http-response-send-timeout-seconds 10)

;; Keep Racket's safe defaults for request lines, headers, multipart data, and
;; future safety fields. Only the Grocery POS-specific limits are overridden.
(define pos-http-safety-limits
  (make-safety-limits
   #:max-concurrent pos-http-max-concurrent
   #:max-waiting pos-http-max-waiting
   #:request-read-timeout pos-http-request-read-timeout-seconds
   #:max-request-body-length pos-http-max-request-body-bytes
   #:response-timeout pos-http-response-timeout-seconds
   #:response-send-timeout pos-http-response-send-timeout-seconds))
