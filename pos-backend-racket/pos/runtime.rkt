#lang racket

(require (prefix-in db: db)
         file/sha1
         racket/random
         "runtime-config.rkt"
         "application/authentication-service.rkt"
         "application/operator-service.rkt"
         "application/register-operations-service.rkt"
         "application/transaction-service.rkt"
         "application/transaction-void-approval-service.rkt"
         "persistence/pos-database-migrations.rkt"
         "persistence/sqlite-catalog.rkt"
         "persistence/sqlite-connection.rkt"
         "persistence/transaction-void-approval-store.rkt"
         "security/transaction-void-approval.rkt"
         "support/readiness.rkt")

(provide runtime-sqlite-max-connections
         runtime-sqlite-max-idle-connections
         initialize-sqlite-database!
         start-pos-runtime
         stop-pos-runtime!
         pos-runtime?
         pos-runtime-transaction-service
         pos-runtime-register-operations-service
         pos-runtime-operator-service
         pos-runtime-authentication-service
         pos-runtime-transaction-void-approval-service
         pos-runtime-sqlite-db-path
         pos-runtime-stopped?
         pos-runtime-readiness)

;; One local register has modest concurrency. A fixed small bound prevents a
;; burst of request threads from creating an unbounded number of SQLite
;; connections while still allowing independent request transactions.
(define runtime-sqlite-max-connections 4)
(define runtime-sqlite-max-idle-connections 4)
(define runtime-sqlite-max-idle-seconds 300)

(struct pos-runtime
  (transaction-service
   register-operations-service
   operator-service
   authentication-service
   transaction-void-approval-service
   sqlite-db-path
   custodian
   stopped-box
   connect))

(define (system-current-epoch-ms)
  (inexact->exact (floor (current-inexact-milliseconds))))

(define (system-current-monotonic-ms)
  (inexact->exact (floor (current-inexact-monotonic-milliseconds))))

(define (secure-shift-id)
  (string-append "shift_" (bytes->hex-string (crypto-random-bytes 16))))

(define (pos-runtime-stopped? runtime)
  (unless (pos-runtime? runtime)
    (raise-argument-error 'pos-runtime-stopped? "pos-runtime?" runtime))
  (unbox (pos-runtime-stopped-box runtime)))

(define (pos-runtime-readiness runtime)
  (unless (pos-runtime? runtime)
    (raise-argument-error 'pos-runtime-readiness "pos-runtime?" runtime))
  (if (pos-runtime-stopped? runtime)
      (runtime-not-ready 'runtime_stopped)
      (parameterize ([current-custodian (pos-runtime-custodian runtime)])
        (probe-pos-database-readiness
         (pos-runtime-sqlite-db-path runtime)
         #:connect (pos-runtime-connect runtime)))))

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
         #:connect [connect open-pos-sqlite-connection]
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
         #:connect [connect open-pos-sqlite-connection]
         #:current-monotonic-ms
         [current-monotonic-ms system-current-monotonic-ms]
         #:current-epoch-ms [current-epoch-ms system-current-epoch-ms]
         #:generate-shift-id [generate-shift-id secure-shift-id])
  (define who 'start-pos-runtime)
  (unless (pos-runtime-config? config)
    (raise-argument-error who "pos-runtime-config?" config))
  (unless (or (not catalog-lookup) (procedure? catalog-lookup))
    (raise-argument-error who "(or/c #f procedure?)" catalog-lookup))
  (unless (procedure? connect)
    (raise-argument-error who "procedure?" connect))
  (for ([value (in-list
                (list current-monotonic-ms current-epoch-ms generate-shift-id))]
        [name (in-list
               '(current-monotonic-ms current-epoch-ms generate-shift-id))])
    (unless (and (procedure? value) (procedure-arity-includes? value 0))
      (raise-arguments-error
       who "expected a zero-argument procedure" (symbol->string name) value)))

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
    (define-values
      (transaction-service register-service operator-service auth-service
                           approval-service)
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
        (define operator-service
          (make-operator-service virtual-connection))
        (define auth-service
          (make-authentication-service
           virtual-connection
           #:current-monotonic-ms current-monotonic-ms
           #:current-epoch-ms current-epoch-ms))
        (define approval-authority
          (make-transaction-void-approval-authority
           #:current-monotonic-ms current-monotonic-ms
           #:current-epoch-ms current-epoch-ms))
        (define transaction-service
          (make-transaction-service
           virtual-connection
           #:catalog-lookup effective-catalog-lookup
           #:approval-consumer
           (lambda (connection capability requester command)
             (consume-transaction-void-approval!/in-transaction!
              connection
              capability
              (transaction-void-approval-authority-issuer-instance-id
               approval-authority)
              requester
              command
              (current-monotonic-ms)))
           #:current-epoch-ms current-epoch-ms))
        (define approval-service
          (make-transaction-void-approval-service
           auth-service transaction-service approval-authority))
        (values
         transaction-service
         (make-register-operations-service
          virtual-connection
          #:current-epoch-ms current-epoch-ms
          #:generate-shift-id generate-shift-id)
         operator-service
         auth-service
         approval-service)))
    (pos-runtime transaction-service
                 register-service
                 operator-service
                 auth-service
                 approval-service
                 database-path
                 runtime-custodian
                 stopped-box
                 connect)))

(define (stop-pos-runtime! runtime)
  (unless (pos-runtime? runtime)
    (raise-argument-error 'stop-pos-runtime! "pos-runtime?" runtime))
  (unless (unbox (pos-runtime-stopped-box runtime))
    (set-box! (pos-runtime-stopped-box runtime) #t)
    (custodian-shutdown-all (pos-runtime-custodian runtime)))
  (void))
