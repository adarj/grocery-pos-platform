#lang racket

(require racket/runtime-path
         "pos/api/server.rkt"
         "pos/runtime-config.rkt"
         "pos/runtime.rkt")

(define-runtime-path project-root "..")

(define config
  (load-pos-runtime-config #:base-directory project-root))

(define runtime
  (start-pos-runtime config))

(dynamic-wind
  void
  (lambda ()
    (define host (pos-runtime-config-host config))
    (define port (pos-runtime-config-port config))
    (printf "SQLite database ready: ~a\n"
            (pos-runtime-sqlite-db-path runtime))
    (printf "Starting Grocery POS Core on http://~a:~a\n" host port)
    (printf "Health endpoint: http://~a:~a/health\n" host port)
    (printf "Readiness endpoint: http://~a:~a/ready\n" host port)
    (serve-pos-app
     (make-app (pos-runtime-transaction-service runtime)
               (pos-runtime-register-operations-service runtime)
               #:authentication-service
               (pos-runtime-authentication-service runtime)
               #:transaction-void-approval-service
               (pos-runtime-transaction-void-approval-service runtime)
               #:readiness-probe
               (lambda () (pos-runtime-readiness runtime)))
     host
     port))
  (lambda ()
    (stop-pos-runtime! runtime)))
