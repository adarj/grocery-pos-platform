#lang racket

(require (prefix-in db: db)
         "../persistence/pos-database-migrations.rkt"
         "../persistence/sqlite-connection.rkt")

(provide (struct-out runtime-ready)
         (struct-out runtime-not-ready)
         probe-pos-database-readiness)

(struct runtime-ready (database-schema-version)
  #:transparent
  #:guard
  (lambda (database-schema-version type-name)
    (unless (exact-positive-integer? database-schema-version)
      (raise-argument-error
       type-name "exact-positive-integer?" database-schema-version))
    database-schema-version))

(define runtime-not-ready-reasons
  '(runtime_stopped
    database_missing
    database_unavailable
    database_schema_not_current))

(struct runtime-not-ready (reason)
  #:transparent
  #:guard
  (lambda (reason type-name)
    (unless (memq reason runtime-not-ready-reasons)
      (raise-argument-error
       type-name
       "supported runtime readiness reason"
       reason))
    reason))

(define (database-path-state database-path)
  (with-handlers ([(lambda (_value) #t)
                   (lambda (_value) 'unavailable)])
    (cond
      [(file-exists? database-path)
       (if (eq? (file-or-directory-type database-path #t) 'file)
           'present
           'unavailable)]
      [(directory-exists? database-path) 'unavailable]
      [else 'missing])))

(define (disconnect-if-open! connection)
  (when (and (db:connection? connection)
             (db:connected? connection))
    (with-handlers ([exn:fail? void])
      (db:disconnect connection))))

(define (probe-open-database database-path connect)
  (define connection #f)
  (dynamic-wind
    void
    (lambda ()
      ;; Read/write mode verifies the Checkpoint 1 production contract and
      ;; cannot create or convert the authoritative database.
      (set! connection (connect database-path 'read/write))
      (unless (db:connection? connection)
        (error 'probe-pos-database-readiness
               "connector did not return a database connection"))
      (unless (equal? (db:query-value connection "SELECT 1") 1)
        (error 'probe-pos-database-readiness
               "SQLite connectivity query returned an unexpected value"))
      (define migrations-table-count
        (db:query-value
         connection
         #<<SQL
SELECT COUNT(*)
FROM sqlite_schema
WHERE type = 'table' AND name = 'pos_schema_migrations'
SQL
         ))
      (cond
        [(not (= migrations-table-count 1))
         (runtime-not-ready 'database_schema_not_current)]
        [else
         (define history
           (read-pos-database-migration-history connection))
         (if (eq? (classify-pos-database-migration-history history)
                  'current)
             (runtime-ready current-pos-database-schema-version)
             (runtime-not-ready 'database_schema_not_current))]))
    (lambda () (disconnect-if-open! connection))))

(define (probe-pos-database-readiness
         database-path
         #:connect [connect open-pos-sqlite-connection])
  (define who 'probe-pos-database-readiness)
  (unless (path-string? database-path)
    (raise-argument-error who "path-string?" database-path))
  (unless (procedure? connect)
    (raise-argument-error who "procedure?" connect))
  (define resolved-path (path->complete-path database-path))
  (case (database-path-state resolved-path)
    [(missing)
     (runtime-not-ready 'database_missing)]
    [(unavailable)
     (runtime-not-ready 'database_unavailable)]
    [else
     ;; SQLite and connector details are intentionally diagnostic-only. The
     ;; public readiness result exposes one stable sanitized failure category.
     (with-handlers ([(lambda (_value) #t)
                      (lambda (_value)
                        (runtime-not-ready 'database_unavailable))])
       (probe-open-database resolved-path connect))]))
