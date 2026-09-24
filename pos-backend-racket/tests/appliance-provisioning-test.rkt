#lang racket

(require (prefix-in db: db)
         racket/file
         racket/runtime-path
         rackunit
         "../pos/persistence/pos-database-migrations.rkt"
         "../pos/persistence/sqlite-connection.rkt"
         "../pos/persistence/sqlite-maintenance.rkt"
         "../pos/support/appliance-provisioning.rkt"
         "../scripts/appliance.rkt")

(define-runtime-path valid-catalog-path
  "../fixtures/development/catalog-snapshot-v2.json")
(define-runtime-path valid-register-path
  "../../fixtures/development/register-configuration-v1.json")

(define (supported-host)
  (appliance-host-profile "fedora" "44" "kinoite" "x86_64" #t))

(module+ test
  (test-case "root appliance auth status reflects enrolled register and approver readiness"
    (define directory
      (make-temporary-file "grocery-pos-auth-status-~a" 'directory))
    (dynamic-wind
      void
      (lambda ()
        (define database-path (build-path directory "pos.db"))
        (define missing (appliance-auth-status database-path))
        (check-false (hash-ref missing 'register_auth_ready))
        (check-false (hash-ref missing 'approval_auth_ready))
        (define connection
          (open-pos-sqlite-connection database-path 'create))
        (migrate-pos-database! connection)
        (db:query-exec connection
                       "INSERT INTO operators VALUES ('Alice', 'Alice', 1), ('Morgan', 'Morgan', 1)")
        (db:query-exec connection
                       "INSERT INTO operator_roles VALUES ('Alice', 'cashier'), ('Morgan', 'manager')")
        (db:query-exec connection
                       "INSERT INTO operator_pin_credentials VALUES ('Alice', '$argon2id$fixture', 1), ('Morgan', '$argon2id$fixture', 1)")
        (db:query-exec connection
                       "INSERT INTO cashiers VALUES ('Alice', 'Alice', 1)")
        (db:disconnect connection)
        (define ready (appliance-auth-status database-path))
        (check-true (hash-ref ready 'register_auth_ready))
        (check-true (hash-ref ready 'approval_auth_ready))
        (check-equal? (hash-ref ready 'audit_event_count) 0))
      (lambda () (delete-directory/files directory))))

  (test-case "only the Fedora Kinoite 44 x86_64 ostree profile is accepted"
    (check-not-exn (lambda () (validate-kinoite-host! (supported-host))))
    (for ([profile
           (in-list
            (list
             (appliance-host-profile "fedora" "45" "kinoite" "x86_64" #t)
             (appliance-host-profile "fedora" "44" "kde" "x86_64" #t)
             (appliance-host-profile "fedora" "44" "silverblue" "x86_64" #t)
             (appliance-host-profile "fedora" "44" "kinoite" "aarch64" #t)
             (appliance-host-profile "fedora" "44" "kinoite" "x86_64" #f)))])
      (check-exn exn:fail:appliance-provisioning?
                 (lambda () (validate-kinoite-host! profile)))))

  (test-case "initial database is validated before no-overwrite publication"
    (define directory
      (make-temporary-file "grocery-pos-provision-db-~a" 'directory))
    (dynamic-wind
      void
      (lambda ()
        (define target (build-path directory "pos.db"))
        (define result
          (build-initial-pos-database!
           valid-catalog-path valid-register-path target))
        (check-equal? (initial-pos-database-schema-version result) 12)
        (check-true (file-exists? target))
        (check-true
         (sqlite-backup-validation-valid?
          (validate-pos-sqlite-backup target)))
        (check-equal?
         (for/list ([path (in-directory directory)]
                    #:when (regexp-match? #rx"\\.provision" (path->string path)))
           path)
         '())

        (define connection
          (db:sqlite3-connect #:database target #:mode 'read-only))
        (dynamic-wind
          void
          (lambda ()
            (check-equal?
             (db:query-value connection
                             "SELECT COUNT(*) FROM catalog_items")
             1)
            (check-equal?
             (db:query-value connection
                             "SELECT register_id FROM register_configuration")
             "register-development-01")
            (check-equal?
             (db:query-row
              connection
              #<<SQL
SELECT operator.operator_id,
       assignment.role,
       credential.operator_id
FROM operators AS operator
JOIN operator_roles AS assignment
  ON assignment.operator_id = operator.operator_id
LEFT JOIN operator_pin_credentials AS credential
  ON credential.operator_id = operator.operator_id
WHERE operator.operator_id = 'cashier-development-01'
SQL
              )
             (vector "cashier-development-01" "cashier" db:sql-null)))
          (lambda () (db:disconnect connection))))
      (lambda () (delete-directory/files directory))))

  (test-case "invalid input and an existing canonical target fail closed"
    (define directory
      (make-temporary-file "grocery-pos-provision-safety-~a" 'directory))
    (dynamic-wind
      void
      (lambda ()
        (define target (build-path directory "pos.db"))
        (define bad-catalog (build-path directory "bad-catalog.json"))
        (display-to-file "{not-json" bad-catalog #:exists 'error)
        (check-exn
         exn:fail:appliance-provisioning?
         (lambda ()
           (build-initial-pos-database!
            bad-catalog valid-register-path target)))
        (check-false (file-exists? target))

        (display-to-file "existing-authoritative-state" target
                         #:exists 'error)
        (define before (file->bytes target))
        (check-exn
         exn:fail:appliance-provisioning?
         (lambda ()
           (build-initial-pos-database!
            valid-catalog-path valid-register-path target)))
        (check-equal? (file->bytes target) before))
      (lambda () (delete-directory/files directory))))

  (test-case "provisioning records each completed phase and finalizes kiosk last"
    (define calls '())
    (define database-exists? #f)
    (define state-box (box #f))
    (define (record! value) (set! calls (append calls (list value))))
    (define result
      (provision-pos-appliance!
       "/artifacts/terminal.flatpak"
       "/inputs/catalog.json"
       "/inputs/register.json"
       #:effective-user-id (lambda () 0)
       #:host-profile (lambda () (supported-host))
       #:file-exists? (lambda (_path) #t)
       #:canonical-database-exists? (lambda () database-exists?)
       #:hash-file (lambda (path) (string-append "sha256:" path))
       #:read-state (lambda () (unbox state-box))
       #:write-state!
       (lambda (state)
         (set-box! state-box state)
         (record! (list 'phase (appliance-provisioning-state-phase state))))
       #:install-terminal! (lambda (_path) (record! 'terminal))
       #:ensure-kiosk-user! (lambda () (record! 'user))
       #:ensure-state-directory! (lambda () (record! 'state-directory))
       #:publish-database!
       (lambda (_catalog _register)
         (record! 'database)
         (set! database-exists? #t))
       #:enable-core! (lambda () (record! 'core))
       #:core-ready? (lambda () #t)
       #:configure-kiosk! (lambda () (record! 'kiosk))))

    (check-equal? (appliance-provisioning-state-phase result) 'complete)
    (check-equal?
     calls
     '((phase preflight)
       terminal (phase terminal_installed)
       user (phase kiosk_user_ready)
       state-directory
       database (phase database_published)
       core (phase core_ready)
       kiosk (phase kiosk_configured)
       (phase complete))))

  (test-case "a recorded post-publication failure resumes without rebuilding DB"
    (define calls '())
    (define inputs
      (appliance-provisioning-input-hashes "terminal" "catalog" "register"))
    (define state-box
      (box (appliance-provisioning-state
            1 "operation-resume" 'database_published inputs)))
    (define result
      (provision-pos-appliance!
       "/terminal" "/catalog" "/register"
       #:effective-user-id (lambda () 0)
       #:host-profile (lambda () (supported-host))
       #:file-exists? (lambda (_path) #t)
       #:canonical-database-exists? (lambda () #t)
       #:hash-file
       (lambda (path)
         (cond [(equal? path "/terminal") "terminal"]
               [(equal? path "/catalog") "catalog"]
               [else "register"]))
       #:read-state (lambda () (unbox state-box))
       #:write-state! (lambda (state) (set-box! state-box state))
       #:terminal-installed? (lambda () #t)
       #:kiosk-user-ready? (lambda () #t)
       #:install-terminal! (lambda (_path) (set! calls (cons 'terminal calls)))
       #:ensure-kiosk-user! (lambda () (set! calls (cons 'user calls)))
       #:ensure-state-directory!
       (lambda () (set! calls (cons 'state-directory calls)))
       #:publish-database!
       (lambda (_catalog _register) (set! calls (cons 'database calls)))
       #:enable-core! (lambda () (set! calls (cons 'core calls)))
       #:core-ready? (lambda () #t)
       #:configure-kiosk! (lambda () (set! calls (cons 'kiosk calls)))))
    (check-equal? (appliance-provisioning-state-phase result) 'complete)
    (check-equal? (reverse calls) '(core kiosk)))

  (test-case "resume verifies previously completed appliance boundaries"
    (define state
      (appliance-provisioning-state
       1 "operation-verify" 'database_published
       (appliance-provisioning-input-hashes "terminal" "catalog" "register")))
    (define mutations '())
    (check-exn
     exn:fail:appliance-provisioning?
     (lambda ()
       (provision-pos-appliance!
        "/terminal" "/catalog" "/register"
        #:effective-user-id (lambda () 0)
        #:host-profile (lambda () (supported-host))
        #:file-exists? (lambda (_path) #t)
        #:canonical-database-exists? (lambda () #t)
        #:hash-file
        (lambda (path)
          (cond [(equal? path "/terminal") "terminal"]
                [(equal? path "/catalog") "catalog"]
                [else "register"]))
        #:read-state (lambda () state)
        #:write-state! (lambda (_state) (set! mutations (cons 'state mutations)))
        #:terminal-installed? (lambda () #f)
        #:kiosk-user-ready? (lambda () #t)
        #:install-terminal! (lambda (_path) (set! mutations (cons 'terminal mutations)))
        #:ensure-kiosk-user! (lambda () (set! mutations (cons 'user mutations)))
        #:ensure-state-directory! void
        #:publish-database! void
        #:enable-core! (lambda () (set! mutations (cons 'core mutations)))
        #:core-ready? (lambda () #t)
        #:configure-kiosk! (lambda () (set! mutations (cons 'kiosk mutations))))))
    (check-equal? mutations '()))

  (test-case "resume rejects changed critical inputs and completed provisioning"
    (define state
      (appliance-provisioning-state
       1 "operation-fixed" 'database_published
       (appliance-provisioning-input-hashes "old" "catalog" "register")))
    (define (invoke read-state hash-file)
      (provision-pos-appliance!
       "/terminal" "/catalog" "/register"
       #:effective-user-id (lambda () 0)
       #:host-profile (lambda () (supported-host))
       #:file-exists? (lambda (_path) #t)
       #:canonical-database-exists? (lambda () #t)
       #:hash-file hash-file
       #:read-state read-state
       #:write-state! void
       #:install-terminal! void
       #:ensure-kiosk-user! void
       #:ensure-state-directory! void
       #:publish-database! void
       #:enable-core! void
       #:core-ready? (lambda () #t)
       #:configure-kiosk! void))
    (check-exn
     exn:fail:appliance-provisioning?
     (lambda ()
       (invoke (lambda () state)
               (lambda (path)
                 (if (equal? path "/terminal") "changed" (substring path 1))))))
    (check-exn
     exn:fail:appliance-provisioning?
     (lambda ()
       (invoke
        (lambda () (struct-copy appliance-provisioning-state state
                                [phase 'complete]))
        (lambda (path)
          (cond [(equal? path "/terminal") "old"]
                [(equal? path "/catalog") "catalog"]
                [else "register"]))))))

  (test-case "input preflight failure precedes all provisioning mutation"
    (define calls '())
    (check-exn
     exn:fail?
     (lambda ()
       (provision-pos-appliance!
        "/terminal" "/catalog" "/register"
        #:effective-user-id (lambda () 0)
        #:host-profile (lambda () (supported-host))
        #:file-exists? (lambda (_path) #t)
        #:canonical-database-exists? (lambda () #f)
        #:hash-file (lambda (path) path)
        #:validate-inputs!
        (lambda (_terminal _catalog _register)
          (set! calls (append calls '(validate)))
          (error 'preflight "invalid catalog"))
        #:write-state! (lambda (_state) (set! calls (append calls '(state))))
        #:install-terminal! (lambda (_path) (set! calls (append calls '(terminal))))
        #:ensure-kiosk-user! (lambda () (set! calls (append calls '(user))))
        #:ensure-state-directory!
        (lambda () (set! calls (append calls '(state-directory))))
        #:publish-database! (lambda _args (set! calls (append calls '(database))))
        #:enable-core! (lambda () (set! calls (append calls '(core))))
        #:core-ready? (lambda () #t)
        #:configure-kiosk! (lambda () (set! calls (append calls '(kiosk)))))))
    (check-equal? calls '(validate))))
