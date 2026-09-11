#lang racket

(require (prefix-in db: db)
         file/sha1
         racket/file
         racket/random
         "atomic-file.rkt"
         "pos-database-migrations.rkt"
         "sqlite-connection.rkt")

(provide (struct-out sqlite-database-info)
         (struct-out sqlite-check-result)
         (struct-out sqlite-integrity-result)
         (struct-out sqlite-backup-validation)
         (struct-out sqlite-backup-created)
         call-with-pos-sqlite-inspection-connection
         inspect-pos-sqlite-database
         quick-check-pos-sqlite-database
         integrity-check-pos-sqlite-database
         validate-pos-sqlite-backup
         create-pos-sqlite-backup!)

(struct sqlite-database-info
  (path
   file-exists?
   regular-file?
   read-only-openable?
   journal-mode
   migration-history
   highest-applied-migration-version
   current-supported-migration-version
   migration-status
   schema-valid?
   schema-diagnostic
   page-size
   page-count
   freelist-count
   main-file-size
   wal-file-exists?
   wal-file-size
   shm-file-exists?
   shm-file-size
   open-diagnostic)
  #:transparent)

(struct sqlite-check-result (healthy? messages)
  #:transparent)

(struct sqlite-integrity-result
  (healthy? messages foreign-key-violations)
  #:transparent)

(struct sqlite-backup-validation
  (valid?
   file-size
   integrity-result
   migration-history
   migration-status
   schema-valid?
   diagnostics)
  #:transparent)

(struct sqlite-backup-created (path validation)
  #:transparent)

(define (check-database-path who label value)
  (unless (path-string? value)
    (raise-argument-error who "path-string?" value))
  (define path-value
    (if (path? value) value (string->path value)))
  (when (zero? (bytes-length (path->bytes path-value)))
    (raise-arguments-error
     who
     "SQLite database path must not be empty"
     label
     value))
  (simplify-path (path->complete-path path-value) #f))

(define (path-kind path)
  (file-or-directory-type path #f))

(define (regular-file? path)
  (eq? (path-kind path) 'file))

(define (database-sidecar-path database-path suffix)
  (bytes->path
   (bytes-append (path->bytes database-path) suffix)))

(define (file-size-if-regular path)
  (and (regular-file? path) (file-size path)))

(define (disconnect-if-connected! connection)
  (when (and (db:connection? connection)
             (db:connected? connection))
    (with-handlers ([exn:fail? void])
      (db:disconnect connection))))

(define (call-with-pos-sqlite-inspection-connection
         database-path
         procedure
         #:sqlite3-connect [sqlite3-connect db:sqlite3-connect])
  (define who 'call-with-pos-sqlite-inspection-connection)
  (define resolved-path
    (check-database-path who "database-path" database-path))
  (unless (procedure? procedure)
    (raise-argument-error who "procedure?" procedure))
  (unless (procedure-arity-includes? procedure 1)
    (raise-arguments-error
     who
     "inspection procedure must accept one connection argument"
     "procedure"
     procedure))
  (unless (procedure? sqlite3-connect)
    (raise-argument-error who "procedure?" sqlite3-connect))
  (unless (regular-file? resolved-path)
    (raise-arguments-error
     who
     "inspection requires an existing regular SQLite database file"
     "database-path"
     resolved-path))

  (define connection #f)
  (dynamic-wind
    void
    (lambda ()
      (set! connection
            (sqlite3-connect
             #:database resolved-path
             #:mode 'read-only
             #:busy-retry-limit pos-sqlite-busy-retry-limit
             #:busy-retry-delay pos-sqlite-busy-retry-delay))
      (unless (db:connection? connection)
        (raise-arguments-error
         who
         "SQLite connector did not return a database connection"
         "connection"
         connection))
      (procedure connection))
    (lambda () (disconnect-if-connected! connection))))

(define (migration-table-exists? connection)
  (= 1
     (db:query-value
      connection
      #<<SQL
SELECT COUNT(*)
FROM sqlite_schema
WHERE type = 'table' AND name = 'pos_schema_migrations'
SQL
      )))

(define (history-highest-version history)
  (and (pair? history)
       (vector-ref (last history) 0)))

(define (inspect-pos-sqlite-database database-path)
  (define who 'inspect-pos-sqlite-database)
  (define resolved-path
    (check-database-path who "database-path" database-path))
  (define exists? (file-exists? resolved-path))
  (define regular? (regular-file? resolved-path))
  (define wal-path (database-sidecar-path resolved-path #"-wal"))
  (define shm-path (database-sidecar-path resolved-path #"-shm"))

  (define read-only-openable? #f)
  (define journal-mode #f)
  (define migration-history #f)
  (define highest-version #f)
  (define migration-status
    (cond
      [(not exists?) 'missing-file]
      [(not regular?) 'not-a-regular-file]
      [else 'unavailable]))
  (define schema-valid? #f)
  (define schema-diagnostic #f)
  (define page-size #f)
  (define page-count #f)
  (define freelist-count #f)
  (define open-diagnostic #f)

  (when regular?
    (with-handlers
        ([exn:fail?
          (lambda (exception)
            (set! read-only-openable? #f)
            (set! migration-status 'unavailable)
            (set! open-diagnostic (exn-message exception)))])
      (call-with-pos-sqlite-inspection-connection
       resolved-path
       (lambda (connection)
         ;; These PRAGMAs only observe the target. No migration, journal-mode
         ;; assignment, checkpoint, or repair operation belongs in inspection.
         (set! journal-mode
               (db:query-value connection "PRAGMA journal_mode"))
         (set! page-size
               (db:query-value connection "PRAGMA page_size"))
         (set! page-count
               (db:query-value connection "PRAGMA page_count"))
         (set! freelist-count
               (db:query-value connection "PRAGMA freelist_count"))
         (set! read-only-openable? #t)

         (cond
           [(not (migration-table-exists? connection))
            (set! migration-status 'missing)
            (set! schema-diagnostic
                  "pos_schema_migrations is missing")]
           [else
            (set! migration-history
                  (read-pos-database-migration-history connection))
            (set! highest-version
                  (history-highest-version migration-history))
            (set! migration-status
                  (classify-pos-database-migration-history
                   migration-history))
            (cond
              [(eq? migration-status 'unsupported)
               (set! schema-diagnostic
                     "POS migration history is unsupported")]
              [else
               (with-handlers
                   ([exn:fail?
                     (lambda (exception)
                       (set! migration-status 'invalid)
                       (set! schema-valid? #f)
                       (set! schema-diagnostic
                             (exn-message exception)))])
                 (validate-pos-database-schema! connection)
                 (set! schema-valid? #t))])])))))

  (sqlite-database-info
   resolved-path
   exists?
   regular?
   read-only-openable?
   journal-mode
   migration-history
   highest-version
   current-pos-database-schema-version
   migration-status
   schema-valid?
   schema-diagnostic
   page-size
   page-count
   freelist-count
   (file-size-if-regular resolved-path)
   (file-exists? wal-path)
   (file-size-if-regular wal-path)
   (file-exists? shm-path)
   (file-size-if-regular shm-path)
   open-diagnostic))

(define (healthy-check-messages? messages)
  (equal? messages '("ok")))

(define (quick-check/in-connection connection)
  (define messages
    (db:query-list connection "PRAGMA quick_check"))
  (sqlite-check-result
   (healthy-check-messages? messages)
   messages))

(define (integrity-check/in-connection connection)
  (define messages
    (db:query-list connection "PRAGMA integrity_check"))
  (define foreign-key-violations
    (db:query-rows connection "PRAGMA foreign_key_check"))
  (sqlite-integrity-result
   (and (healthy-check-messages? messages)
        (null? foreign-key-violations))
   messages
   foreign-key-violations))

(define (quick-check-pos-sqlite-database database-path)
  (call-with-pos-sqlite-inspection-connection
   database-path
   quick-check/in-connection))

(define (integrity-check-pos-sqlite-database database-path)
  (call-with-pos-sqlite-inspection-connection
   database-path
   integrity-check/in-connection))

(define (invalid-backup-validation file-size diagnostics
                                   #:integrity-result [integrity-result #f]
                                   #:migration-history [migration-history #f]
                                   #:migration-status
                                   [migration-status 'unavailable]
                                   #:schema-valid? [schema-valid? #f])
  (sqlite-backup-validation
   #f
   file-size
   integrity-result
   migration-history
   migration-status
   schema-valid?
   diagnostics))

(define (validate-pos-sqlite-backup backup-path)
  (define who 'validate-pos-sqlite-backup)
  (define resolved-path
    (check-database-path who "backup-path" backup-path))
  (define size (file-size-if-regular resolved-path))
  (cond
    [(not (regular-file? resolved-path))
     (invalid-backup-validation
      #f
      '("backup candidate is not an existing regular file")
      #:migration-status
      (if (file-exists? resolved-path) 'not-a-regular-file 'missing-file))]
    [(zero? size)
     (invalid-backup-validation
      size
      '("backup candidate is empty"))]
    [else
     (with-handlers
         ([exn:fail?
           (lambda (exception)
             (invalid-backup-validation
              size
              (list (exn-message exception))))])
       (call-with-pos-sqlite-inspection-connection
        resolved-path
        (lambda (connection)
          (define integrity-result
            (integrity-check/in-connection connection))
          (define migration-history #f)
          (define migration-status 'missing)
          (define schema-valid? #f)
          (define diagnostics '())

          (unless (sqlite-integrity-result-healthy? integrity-result)
            (set! diagnostics
                  (append
                   diagnostics
                   (sqlite-integrity-result-messages integrity-result)))
            (unless
                (null?
                 (sqlite-integrity-result-foreign-key-violations
                  integrity-result))
              (set! diagnostics
                    (append diagnostics
                            '("foreign key violations were reported")))))

          (cond
            [(not (migration-table-exists? connection))
             (set! diagnostics
                   (append diagnostics
                           '("pos_schema_migrations is missing")))]
            [else
             (set! migration-history
                   (read-pos-database-migration-history connection))
             (set! migration-status
                   (classify-pos-database-migration-history
                    migration-history))
             (with-handlers
                 ([exn:fail?
                   (lambda (exception)
                     (set! diagnostics
                           (append diagnostics
                                   (list (exn-message exception)))))])
               (validate-pos-database-schema!
                connection
                #:require-current? #t)
               (set! schema-valid? #t))])

          (define valid?
            (and (sqlite-integrity-result-healthy? integrity-result)
                 (eq? migration-status 'current)
                 schema-valid?))
          (sqlite-backup-validation
           valid?
           size
           integrity-result
           migration-history
           migration-status
           schema-valid?
           diagnostics))))]))

(define (create-owned-candidate-path! final-path)
  (define parent-directory (path-only final-path))
  (define token
    (string->bytes/utf-8
     (bytes->hex-string (crypto-random-bytes 16))))
  (define candidate-name
    (bytes->path
     (bytes-append
      #".grocery-pos-backup."
      token
      #".partial")))
  (define candidate-path
    (build-path parent-directory candidate-name))
  ;; SQLite VACUUM INTO accepts an existing empty target. Exclusive creation
  ;; reserves this cryptographically random name and proves that any candidate
  ;; later removed by cleanup belongs to this invocation.
  (call-with-output-file
   candidate-path
   #:exists 'error
   void)
  candidate-path)

(define (create-pos-sqlite-backup!
         source-path
         final-path
         #:validate-candidate
         [validate-candidate validate-pos-sqlite-backup])
  (define who 'create-pos-sqlite-backup!)
  (define resolved-source
    (check-database-path who "source-path" source-path))
  (define resolved-final
    (check-database-path who "final-path" final-path))
  (unless (procedure? validate-candidate)
    (raise-argument-error who "procedure?" validate-candidate))
  (unless (procedure-arity-includes? validate-candidate 1)
    (raise-arguments-error
     who
     "candidate validator must accept one path argument"
     "validate-candidate"
     validate-candidate))
  (unless (regular-file? resolved-source)
    (raise-arguments-error
     who
     "backup source must be an existing regular database file"
     "source-path"
     resolved-source))
  (when (equal? resolved-source resolved-final)
    (raise-arguments-error
     who
     "backup source and final destination must be different paths"
     "source-path"
     resolved-source
     "final-path"
     resolved-final))
  (define final-parent (path-only resolved-final))
  (define final-name (file-name-from-path resolved-final))
  (unless (and final-parent final-name (directory-exists? final-parent))
    (raise-arguments-error
     who
     "backup destination parent directory must already exist"
     "final-path"
     resolved-final
     "parent-directory"
     final-parent))
  (when (path-kind resolved-final)
    (raise-arguments-error
     who
     "backup final destination already exists"
     "final-path"
     resolved-final))

  (define candidate-path #f)
  (with-handlers
      ([(lambda (_value) #t)
        (lambda (value)
          ;; Delete only the unique candidate owned by this invocation. Never
          ;; remove or replace a caller's final destination.
          (when (and candidate-path
                     (file-exists? candidate-path))
            (with-handlers ([exn:fail? void])
              (delete-file candidate-path)))
          (raise value))])
    ;; The live source is opened through the Checkpoint 1 writable policy.
    ;; VACUUM INTO gets a dedicated connection and no application transaction.
    (define source-connection
      (open-pos-sqlite-connection resolved-source 'read/write))
    (dynamic-wind
      void
      (lambda ()
        (validate-pos-database-schema!
         source-connection
         #:require-current? #t)
        (set! candidate-path (create-owned-candidate-path! resolved-final))
        (db:query-exec
         source-connection
         "VACUUM INTO ?"
         (path->string candidate-path)))
      (lambda () (disconnect-if-connected! source-connection)))

    ;; Candidate validation is independent, read-only, and occurs only after
    ;; the live-source connection has been released.
    (define validation (validate-candidate candidate-path))
    (unless (and (sqlite-backup-validation? validation)
                 (sqlite-backup-validation-valid? validation))
      (error who "generated backup candidate failed validation"))
    ;; The candidate and final name share a directory. Linux RENAME_NOREPLACE
    ;; makes destination absence part of the atomic rename, so a final path
    ;; that appears after initial validation is never overwritten.
    (atomic-rename-file-no-replace!
     candidate-path
     resolved-final
     #:who who)
    (set! candidate-path #f)
    (sqlite-backup-created resolved-final validation)))
