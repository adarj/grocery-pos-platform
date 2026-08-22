#lang racket

(require (prefix-in db: db)
         "runtime-config.rkt"
         "application/transaction-service.rkt"
         "persistence/pos-database-migrations.rkt"
         "persistence/sqlite-catalog.rkt")

(provide runtime-sqlite-max-connections
         runtime-sqlite-max-idle-connections
         initialize-sqlite-database!
         start-pos-runtime
         stop-pos-runtime!
         pos-runtime?
         pos-runtime-transaction-service
         pos-runtime-sqlite-db-path
         pos-runtime-stopped?)

;; One local register has modest concurrency. A fixed small bound prevents a
;; burst of request threads from creating an unbounded number of SQLite
;; connections while still allowing independent request transactions.
(define runtime-sqlite-max-connections 4)
(define runtime-sqlite-max-idle-connections 4)
(define runtime-sqlite-max-idle-seconds 300)

(struct pos-runtime
  (transaction-service sqlite-db-path custodian stopped-box))

(define (pos-runtime-stopped? runtime)
  (unless (pos-runtime? runtime)
    (raise-argument-error 'pos-runtime-stopped? "pos-runtime?" runtime))
  (unbox (pos-runtime-stopped-box runtime)))

(define (open-sqlite-connection database-path mode)
  (db:sqlite3-connect #:database database-path #:mode mode))

(define (check-database-parent! who database-path)
  (define parent-directory (path-only database-path))
  (unless (and parent-directory
               (directory-exists? parent-directory))
    (raise-arguments-error
     who
     "SQLite database parent directory does not exist"
     "sqlite-db-path"
     database-path
     "parent-directory"
     parent-directory)))

(define (initialize-sqlite-database!
         database-path
         #:connect [connect open-sqlite-connection]
         #:migrate! [migrate! migrate-pos-database!])
  (define who 'initialize-sqlite-database!)
  (unless (path-string? database-path)
    (raise-argument-error who "path-string?" database-path))
  (unless (procedure? connect)
    (raise-argument-error who "procedure?" connect))
  (unless (procedure? migrate!)
    (raise-argument-error who "procedure?" migrate!))
  (define resolved-path
    (path->complete-path database-path))
  (check-database-parent! who resolved-path)

  (define connection #f)
  (dynamic-wind
    void
    (lambda ()
      (set! connection (connect resolved-path 'create))
      (unless (db:connection? connection)
        (raise-arguments-error
         who
         "SQLite connector did not return a database connection"
         "connection"
         connection))
      (migrate! connection))
    (lambda ()
      (when (and (db:connection? connection)
                 (db:connected? connection))
        (db:disconnect connection)))))

(define (start-pos-runtime
         config
         #:catalog-lookup [catalog-lookup #f]
         #:connect [connect open-sqlite-connection])
  (define who 'start-pos-runtime)
  (unless (pos-runtime-config? config)
    (raise-argument-error who "pos-runtime-config?" config))
  (unless (or (not catalog-lookup) (procedure? catalog-lookup))
    (raise-argument-error who "(or/c #f procedure?)" catalog-lookup))
  (unless (procedure? connect)
    (raise-argument-error who "procedure?" connect))

  (define database-path
    (pos-runtime-config-sqlite-db-path config))

  ;; The one create-capable connection exists only for startup schema work and
  ;; is disconnected before any request-time resource is constructed.
  (initialize-sqlite-database!
   database-path
   #:connect connect)

  (define runtime-custodian (make-custodian))
  (define stopped-box (box #f))
  (with-handlers
      ([(lambda (_value) #t)
        (lambda (value)
          (set-box! stopped-box #t)
          (custodian-shutdown-all runtime-custodian)
          (raise value))])
    (define service
      (parameterize ([current-custodian runtime-custodian])
        (define pool
          (db:connection-pool
           (lambda ()
             ;; Request connections cannot create a missing replacement DB.
             (connect database-path 'read/write))
           #:max-connections runtime-sqlite-max-connections
           #:max-idle-connections runtime-sqlite-max-idle-connections
           #:max-idle-seconds runtime-sqlite-max-idle-seconds))
        (define virtual-connection
          (db:virtual-connection pool))
        (define effective-catalog-lookup
          (or catalog-lookup
              (lambda (barcode)
                (lookup-catalog-item-by-barcode
                 virtual-connection barcode))))
        (make-transaction-service
         virtual-connection
         #:catalog-lookup effective-catalog-lookup)))
    (pos-runtime service
                 database-path
                 runtime-custodian
                 stopped-box)))

(define (stop-pos-runtime! runtime)
  (unless (pos-runtime? runtime)
    (raise-argument-error 'stop-pos-runtime! "pos-runtime?" runtime))
  (unless (unbox (pos-runtime-stopped-box runtime))
    (set-box! (pos-runtime-stopped-box runtime) #t)
    (custodian-shutdown-all (pos-runtime-custodian runtime)))
  (void))
