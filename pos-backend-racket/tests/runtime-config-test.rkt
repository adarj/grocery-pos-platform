#lang racket

(require rackunit
         racket/file
         "../pos/runtime-config.rkt")

(define (environment values)
  (lambda (name)
    (hash-ref values name #f)))

(module+ test
  (test-case "runtime configuration uses documented defaults"
    (define base-directory
      (make-temporary-file "grocery-pos-config-~a" 'directory))
    (dynamic-wind
      void
      (lambda ()
        (define config
          (load-pos-runtime-config
           #:getenv (environment (hash))
           #:base-directory base-directory))
        (check-equal? (pos-runtime-config-host config) "127.0.0.1")
        (check-equal? (pos-runtime-config-port config) 7340)
        (check-equal?
         (pos-runtime-config-sqlite-db-path config)
         (path->complete-path
          (build-path ".local" "sqlite" "pos-dev.db")
          base-directory)))
      (lambda ()
        (delete-directory/files base-directory))))

  (test-case "runtime configuration parses and resolves configured values"
    (define base-directory
      (make-temporary-file "grocery-pos-config-~a" 'directory))
    (dynamic-wind
      void
      (lambda ()
        (define config
          (load-pos-runtime-config
           #:getenv
           (environment
            (hash "RACKET_API_HOST" "0.0.0.0"
                  "RACKET_API_PORT" "8123"
                  "SQLITE_DB_PATH" "data/pos.db"))
           #:base-directory base-directory))
        (check-equal? (pos-runtime-config-host config) "0.0.0.0")
        (check-equal? (pos-runtime-config-port config) 8123)
        (check-equal?
         (pos-runtime-config-sqlite-db-path config)
         (path->complete-path (build-path "data" "pos.db")
                              base-directory)))
      (lambda ()
        (delete-directory/files base-directory))))

  (test-case "runtime configuration rejects invalid host, port, and database path"
    (define (load-with values)
      (load-pos-runtime-config
       #:getenv (environment values)))

    (check-exn exn:fail:contract?
               (lambda ()
                 (load-with (hash "RACKET_API_HOST" ""))))
    (for ([port (in-list '("not-a-port" "0" "65536" "1.5"))])
      (check-exn exn:fail:contract?
                 (lambda ()
                   (load-with (hash "RACKET_API_PORT" port)))))
    (check-exn exn:fail:contract?
               (lambda ()
                 (load-with (hash "SQLITE_DB_PATH" ""))))))
