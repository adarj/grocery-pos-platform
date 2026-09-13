#lang racket

(provide (struct-out pos-runtime-config)
         load-pos-runtime-config)

(define default-api-host "127.0.0.1")
(define default-api-port "7340")
(define default-sqlite-db-path ".local/sqlite/pos-dev.db")

(define (loopback-api-host? value)
  (and (string? value)
       (or (string=? value "127.0.0.1")
           (string=? value "::1"))))

(define (legal-port? value)
  (and (exact-integer? value)
       (<= 1 value 65535)))

(define (normalize-database-path who value [base-directory #f])
  (unless (path-string? value)
    (raise-argument-error who "path-string?" value))
  (when (and (string? value) (zero? (string-length value)))
    (raise-arguments-error
     who
     "SQLite database path must not be empty"
     "sqlite-db-path"
     value))
  (define path-value
    (if (path? value) value (string->path value)))
  (when (zero? (bytes-length (path->bytes path-value)))
    (raise-arguments-error
     who
     "SQLite database path must not be empty"
     "sqlite-db-path"
     value))
  (if base-directory
      (path->complete-path path-value base-directory)
      (path->complete-path path-value)))

(struct pos-runtime-config (host port sqlite-db-path)
  #:transparent
  #:guard
  (lambda (host port sqlite-db-path type-name)
    (unless (loopback-api-host? host)
      (raise-arguments-error
       type-name
       "API host must be the literal loopback address 127.0.0.1 or ::1"
       "host"
       host))
    (unless (legal-port? port)
      (raise-argument-error
       type-name
       "exact integer in [1, 65535]"
       port))
    (values host
            port
            (normalize-database-path type-name sqlite-db-path))))

(define (environment-value getenv-proc name default)
  (define value (getenv-proc name))
  (if value value default))

(define (load-pos-runtime-config
         #:getenv [getenv-proc getenv]
         #:base-directory [base-directory (current-directory)])
  (define who 'load-pos-runtime-config)
  (unless (procedure? getenv-proc)
    (raise-argument-error who "procedure?" getenv-proc))
  (unless (path-string? base-directory)
    (raise-argument-error who "path-string?" base-directory))

  (define host
    (environment-value getenv-proc "RACKET_API_HOST" default-api-host))
  (define port-text
    (environment-value getenv-proc "RACKET_API_PORT" default-api-port))
  (define database-path
    (environment-value
     getenv-proc "SQLITE_DB_PATH" default-sqlite-db-path))

  (unless (string? port-text)
    (raise-argument-error who "string? for RACKET_API_PORT" port-text))
  (define port (string->number port-text))
  (unless (legal-port? port)
    (raise-arguments-error
     who
     "RACKET_API_PORT must be an exact integer in the legal TCP port range"
     "RACKET_API_PORT"
     port-text))

  (pos-runtime-config
   host
   port
   (normalize-database-path who database-path base-directory)))
