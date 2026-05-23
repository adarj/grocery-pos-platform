#lang racket

(require web-server/servlet-env
         "pos/api/server.rkt")

(define host
  (or (getenv "RACKET_API_HOST") "127.0.0.1"))

(define port
  (string->number
   (or (getenv "RACKET_API_PORT") "7340")))

(printf "Starting Grocery POS Core on http://~a:~a\n" host port)
(printf "Health endpoint: http://~a:~a/health\n" host port)

(serve/servlet
 app
 #:launch-browser? #f
 #:quit? #f
 #:listen-ip host
 #:port port
 #:servlet-path "/")
