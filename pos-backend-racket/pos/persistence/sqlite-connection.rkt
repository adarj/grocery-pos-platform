#lang racket

(require (prefix-in db: db))

(provide pos-sqlite-busy-retry-limit
         pos-sqlite-busy-retry-delay
         pos-sqlite-wal-autocheckpoint-pages
         open-pos-sqlite-connection)

(define pos-sqlite-busy-retry-limit 10)
(define pos-sqlite-busy-retry-delay 0.1)
(define pos-sqlite-wal-autocheckpoint-pages 1000)
(define pos-sqlite-synchronous-full 2)

(define (supported-mode? mode)
  (memq mode '(create read/write)))

(define (check-database-path who database-path)
  (unless (path-string? database-path)
    (raise-argument-error who "path-string?" database-path))
  (define path-value
    (if (path? database-path)
        database-path
        (string->path database-path)))
  (when (zero? (bytes-length (path->bytes path-value)))
    (raise-arguments-error
     who
     "SQLite database path must not be empty"
     "database-path"
     database-path)))

(define (check-effective-value who setting expected actual)
  (unless (equal? actual expected)
    (raise-arguments-error
     who
     "SQLite connection does not satisfy the Grocery POS operating policy"
     "setting"
     setting
     "expected"
     expected
     "effective"
     actual)))

(define (check-wal-mode who effective-mode)
  (unless (and (string? effective-mode)
               (string-ci=? effective-mode "wal"))
    (raise-arguments-error
     who
     "SQLite journal mode must be WAL for the authoritative POS database"
     "expected"
     "wal"
     "effective"
     effective-mode)))

(define (establish-or-verify-wal! connection mode)
  (define effective-mode
    (db:query-value
     connection
     (if (eq? mode 'create)
         "PRAGMA journal_mode = WAL"
         "PRAGMA journal_mode")))
  (check-wal-mode 'open-pos-sqlite-connection effective-mode))

(define (apply-and-verify-per-connection-policy! connection)
  (db:query-exec connection "PRAGMA synchronous = FULL")
  (check-effective-value
   'open-pos-sqlite-connection
   'synchronous
   pos-sqlite-synchronous-full
   (db:query-value connection "PRAGMA synchronous"))

  (db:query-exec connection "PRAGMA foreign_keys = ON")
  (check-effective-value
   'open-pos-sqlite-connection
   'foreign_keys
   1
   (db:query-value connection "PRAGMA foreign_keys"))

  (db:query-exec
   connection
   (format "PRAGMA wal_autocheckpoint = ~a"
           pos-sqlite-wal-autocheckpoint-pages))
  (check-effective-value
   'open-pos-sqlite-connection
   'wal_autocheckpoint
   pos-sqlite-wal-autocheckpoint-pages
   (db:query-value connection "PRAGMA wal_autocheckpoint")))

(define (disconnect-after-failure! connection)
  (when (and (db:connection? connection)
             (db:connected? connection))
    (with-handlers ([exn:fail? void])
      (db:disconnect connection))))

(define (open-pos-sqlite-connection
         database-path
         mode
         #:sqlite3-connect [sqlite3-connect db:sqlite3-connect])
  (define who 'open-pos-sqlite-connection)
  (check-database-path who database-path)
  (unless (supported-mode? mode)
    (raise-argument-error who "(or/c 'create 'read/write)" mode))
  (unless (procedure? sqlite3-connect)
    (raise-argument-error who "procedure?" sqlite3-connect))

  (define connection #f)
  (with-handlers
      ([(lambda (_value) #t)
        (lambda (value)
          (disconnect-after-failure! connection)
          (raise value))])
    (set! connection
          (sqlite3-connect
           #:database database-path
           #:mode mode
           #:busy-retry-limit pos-sqlite-busy-retry-limit
           #:busy-retry-delay pos-sqlite-busy-retry-delay))
    (unless (db:connection? connection)
      (raise-arguments-error
       who
       "SQLite connector did not return a database connection"
       "connection"
       connection))
    (establish-or-verify-wal! connection mode)
    (apply-and-verify-per-connection-policy! connection)
    connection))
