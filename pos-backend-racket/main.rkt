#lang racket

(require racket/runtime-path
         web-server/servlet-env
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
    (serve/servlet
     (make-app (pos-runtime-transaction-service runtime))
     #:launch-browser? #f
     #:quit? #f
     #:listen-ip host
     #:port port
     #:servlet-path "/"
     #:servlet-regexp #rx""))
  (lambda ()
    (stop-pos-runtime! runtime)))
