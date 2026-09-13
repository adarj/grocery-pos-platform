#lang racket

(require (prefix-in db: db)
         file/sha1
         racket/file
         racket/random
         "../persistence/atomic-file.rkt"
         "../persistence/catalog-snapshot-codec.rkt"
         "../persistence/operational-configuration-snapshot-codec.rkt"
         "../persistence/pos-database-migrations.rkt"
         "../persistence/sqlite-catalog.rkt"
         "../persistence/sqlite-connection.rkt"
         "../persistence/sqlite-maintenance.rkt"
         "../persistence/sqlite-register-operations.rkt"
         "../runtime.rkt")

(provide appliance-provisioning-schema-version
         appliance-supported-fedora-version
         appliance-supported-architecture
         appliance-supported-variant
         (struct-out exn:fail:appliance-provisioning)
         (struct-out appliance-host-profile)
         (struct-out initial-pos-database)
         (struct-out appliance-provisioning-input-hashes)
         (struct-out appliance-provisioning-state)
         validate-kinoite-host!
         build-initial-pos-database!
         provision-pos-appliance!)

(define appliance-provisioning-schema-version 1)
(define appliance-supported-fedora-version "44")
(define appliance-supported-architecture "x86_64")
(define appliance-supported-variant "kinoite")

(struct exn:fail:appliance-provisioning exn:fail (code) #:transparent)
(struct appliance-host-profile
  (os-id version-id variant-id architecture ostree-booted?)
  #:transparent)
(struct initial-pos-database (path schema-version validation) #:transparent)
(struct appliance-provisioning-input-hashes
  (terminal-flatpak catalog register-configuration)
  #:transparent)
(struct appliance-provisioning-state
  (schema-version operation-id phase input-hashes)
  #:transparent)

(define (raise-provisioning-error code message)
  (raise
   (exn:fail:appliance-provisioning
    message (current-continuation-marks) code)))

(define (validate-kinoite-host! profile)
  (unless (appliance-host-profile? profile)
    (raise-argument-error
     'validate-kinoite-host! "appliance-host-profile?" profile))
  (unless (and (equal? (appliance-host-profile-os-id profile) "fedora")
               (equal? (appliance-host-profile-version-id profile)
                       appliance-supported-fedora-version)
               (equal? (appliance-host-profile-variant-id profile)
                       appliance-supported-variant)
               (equal? (appliance-host-profile-architecture profile)
                       appliance-supported-architecture)
               (appliance-host-profile-ostree-booted? profile))
    (raise-provisioning-error
     'unsupported_host
     "Provisioning requires Fedora Kinoite 44 x86_64 booted through ostree."))
  profile)

(define (read-catalog-snapshot path)
  (define decoded
    (with-handlers
        ([exn:fail?
          (lambda (_exception)
            (raise-provisioning-error
             'catalog_invalid "Catalog input could not be read."))])
      (json-bytes->catalog-snapshot (file->bytes path))))
  (unless (catalog-snapshot-decode-success? decoded)
    (raise-provisioning-error
     'catalog_invalid "Catalog input did not pass canonical validation."))
  (catalog-snapshot-decode-success-snapshot decoded))

(define (read-register-configuration path)
  (define decoded
    (with-handlers
        ([exn:fail?
          (lambda (_exception)
            (raise-provisioning-error
             'register_configuration_invalid
             "Register configuration input could not be read."))])
      (json-bytes->operational-configuration-snapshot (file->bytes path))))
  (unless (operational-configuration-decode-success? decoded)
    (raise-provisioning-error
     'register_configuration_invalid
     "Register configuration did not pass canonical validation."))
  (operational-configuration-decode-success-snapshot decoded))

(define (delete-provisioning-candidate! path)
  (for ([candidate
         (in-list
          (list path
                (bytes->path (bytes-append (path->bytes path) #"-wal"))
                (bytes->path (bytes-append (path->bytes path) #"-shm"))
                (bytes->path (bytes-append (path->bytes path) #"-journal"))))])
    (when (eq? (file-or-directory-type candidate #f) 'file)
      (with-handlers ([exn:fail? void]) (delete-file candidate)))))

(define (build-initial-pos-database!
         catalog-path
         register-configuration-path
         target-path
         #:finalize-candidate! [finalize-candidate! void])
  (define who 'build-initial-pos-database!)
  (for ([value (in-list (list catalog-path
                              register-configuration-path
                              target-path))]
        [name (in-list '(catalog-path register-configuration-path target-path))])
    (unless (path-string? value)
      (raise-argument-error who "path-string?" value)))

  ;; Decode both complete snapshots before creating even a staging database.
  (define catalog (read-catalog-snapshot catalog-path))
  (define configuration
    (read-register-configuration register-configuration-path))
  (define target (simplify-path (path->complete-path target-path) #f))
  (define parent (path-only target))
  (unless (and parent (directory-exists? parent))
    (raise-provisioning-error
     'state_directory_missing "The canonical state directory is missing."))
  (when (file-or-directory-type target #f)
    (raise-provisioning-error
     'database_exists "Provisioning never overwrites a canonical database."))

  (define staging-source
    (make-temporary-file ".provision-~a.sqlite" #f parent))
  ;; create-pos-sqlite-backup! owns no-overwrite candidate creation. Reserve a
  ;; unique basename, release it, then let that primitive create it safely.
  (define standalone-candidate
    (make-temporary-file ".provision-snapshot-~a.sqlite" #f parent))
  (delete-file standalone-candidate)
  (define published? #f)
  (dynamic-wind
    void
    (lambda ()
      (with-handlers
          ([exn:fail:appliance-provisioning? raise]
           [exn:fail?
            (lambda (_exception)
              (raise-provisioning-error
               'database_build_failed
               "The staged initial database could not be built and validated."))])
        (initialize-sqlite-database! staging-source)
        (define connection
          (open-pos-sqlite-connection staging-source 'read/write))
        (dynamic-wind
          void
          (lambda ()
            (activate-catalog-snapshot! connection catalog)
            (define activation
              (activate-operational-configuration! connection configuration))
            (unless (operational-configuration-activation-succeeded?
                     activation)
              (error who "initial operational configuration was rejected")))
          (lambda ()
            (when (db:connected? connection)
              (db:disconnect connection))))

        ;; VACUUM INTO produces a standalone offline candidate rather than
        ;; publishing a main file that might still depend on its build-time WAL.
        ;; The backup primitive performs full, exact-current validation before
        ;; returning the candidate.
        (define created
          (create-pos-sqlite-backup! staging-source standalone-candidate))
        (define validation (sqlite-backup-created-validation created))
        ;; Ownership/mode are finalized while the file is still unpublished,
        ;; so a failure cannot leave a wrongly-owned canonical database.
        (finalize-candidate! standalone-candidate)
        (synchronize-file! standalone-candidate #:who who)
        (atomic-rename-file-no-replace!
         standalone-candidate target #:who who)
        (set! published? #t)
        (synchronize-directory! parent #:who who)
        (initial-pos-database
         target
         current-pos-database-schema-version
         validation)))
    (lambda ()
      (delete-provisioning-candidate! staging-source)
      (unless published?
        (delete-provisioning-candidate! standalone-candidate)))))

(define phase-order
  '(preflight terminal_installed kiosk_user_ready database_published
              core_ready kiosk_configured complete))

(define (phase-index phase)
  (or (index-of phase-order phase)
      (raise-provisioning-error
       'state_invalid "Provisioning state contains an unknown phase.")))

(define (phase-before? phase expected)
  (< (phase-index phase) (phase-index expected)))

(define (default-operation-id)
  (string-append "provision-" (bytes->hex-string (crypto-random-bytes 16))))

(define (default-hash-file path)
  (call-with-input-file path
    (lambda (input) (bytes->hex-string (sha256-bytes input)))
    #:mode 'binary))

(define (unconfigured-adapter name)
  (lambda arguments
    (error 'provision-pos-appliance!
           "production adapter is not configured: ~a" name)))

(define (provision-pos-appliance!
         terminal-flatpak
         catalog-path
         register-configuration-path
         #:effective-user-id [effective-user-id (lambda () 1)]
         #:host-profile [current-host-profile
                         (unconfigured-adapter 'host-profile)]
         #:file-exists? [input-file-exists? file-exists?]
         #:canonical-database-exists?
         [canonical-database-exists?
          (unconfigured-adapter 'canonical-database-exists?)]
         #:hash-file [hash-file default-hash-file]
         #:validate-inputs! [validate-inputs! (lambda (_terminal _catalog _register) (void))]
         #:read-state [read-state (lambda () #f)]
         #:write-state! [write-state! (unconfigured-adapter 'write-state!)]
         #:operation-id [generate-operation-id default-operation-id]
         #:terminal-installed?
         [terminal-installed? (unconfigured-adapter 'terminal-installed?)]
         #:install-terminal!
         [install-terminal! (unconfigured-adapter 'install-terminal!)]
         #:kiosk-user-ready?
         [kiosk-user-ready? (unconfigured-adapter 'kiosk-user-ready?)]
         #:ensure-kiosk-user!
         [ensure-kiosk-user! (unconfigured-adapter 'ensure-kiosk-user!)]
         #:ensure-state-directory!
         [ensure-state-directory!
          (unconfigured-adapter 'ensure-state-directory!)]
         #:publish-database!
         [publish-database! (unconfigured-adapter 'publish-database!)]
         #:enable-core! [enable-core! (unconfigured-adapter 'enable-core!)]
         #:core-ready? [core-ready? (unconfigured-adapter 'core-ready?)]
         #:kiosk-configured?
         [kiosk-configured? (unconfigured-adapter 'kiosk-configured?)]
         #:configure-kiosk!
         [configure-kiosk! (unconfigured-adapter 'configure-kiosk!)])
  (unless (zero? (effective-user-id))
    (raise-provisioning-error
     'not_privileged "Appliance provisioning requires root privilege."))
  (validate-kinoite-host! (current-host-profile))
  (for ([path (in-list (list terminal-flatpak
                             catalog-path
                             register-configuration-path))])
    (unless (input-file-exists? path)
      (raise-provisioning-error
       'input_missing "A required provisioning input is missing.")))

  (define hashes
    (appliance-provisioning-input-hashes
     (hash-file terminal-flatpak)
     (hash-file catalog-path)
     (hash-file register-configuration-path)))
  ;; Complete artifact/catalog/config validation is a preflight concern. The
  ;; production adapter inspects the Flatpak identity and canonical snapshot
  ;; codecs here, before user, database, service, or login-manager mutation.
  (validate-inputs! terminal-flatpak catalog-path register-configuration-path)
  (define stored (read-state))
  (define state
    (cond
      [stored
       (unless (appliance-provisioning-state? stored)
         (raise-provisioning-error
          'state_invalid "Provisioning state is malformed."))
       (unless (= (appliance-provisioning-state-schema-version stored)
                  appliance-provisioning-schema-version)
         (raise-provisioning-error
          'state_invalid "Provisioning state version is unsupported."))
       (unless (equal? hashes
                       (appliance-provisioning-state-input-hashes stored))
         (raise-provisioning-error
          'inputs_changed
          "Critical provisioning inputs changed during resume."))
       (when (eq? (appliance-provisioning-state-phase stored) 'complete)
         (raise-provisioning-error
          'already_provisioned "Appliance provisioning is already complete."))
       stored]
      [else
       (when (canonical-database-exists?)
         (raise-provisioning-error
          'database_exists
          "An unrelated canonical database prevents initial provisioning."))
       (define created
         (appliance-provisioning-state
          appliance-provisioning-schema-version
          (generate-operation-id)
          'preflight
          hashes))
       (write-state! created)
       created]))

  ;; A phase record is evidence of the last completed transition, not a
  ;; substitute for the external invariant itself. Recheck already-completed
  ;; boundaries before performing the next mutation on a resumed operation.
  (define recorded-phase (appliance-provisioning-state-phase state))
  (define (recorded-at-least? phase)
    (not (phase-before? recorded-phase phase)))
  (when (and (recorded-at-least? 'terminal_installed)
             (not (terminal-installed?)))
    (raise-provisioning-error
     'terminal_missing "The recorded cashier terminal is not installed."))
  (when (and (recorded-at-least? 'kiosk_user_ready)
             (not (kiosk-user-ready?)))
    (raise-provisioning-error
     'kiosk_user_invalid "The recorded kiosk account is not ready."))
  (when (and (recorded-at-least? 'database_published)
             (not (canonical-database-exists?)))
    (raise-provisioning-error
     'database_missing "The published canonical database is missing."))
  (when (and (recorded-at-least? 'kiosk_configured)
             (not (kiosk-configured?)))
    (raise-provisioning-error
     'kiosk_configuration_missing
     "The recorded kiosk lifecycle configuration is unavailable."))

  (define (advance! phase)
    (set! state (struct-copy appliance-provisioning-state state [phase phase]))
    (write-state! state))

  (when (phase-before? (appliance-provisioning-state-phase state)
                       'terminal_installed)
    (install-terminal! terminal-flatpak)
    (advance! 'terminal_installed))
  (when (phase-before? (appliance-provisioning-state-phase state)
                       'kiosk_user_ready)
    (ensure-kiosk-user!)
    (advance! 'kiosk_user_ready))
  (when (phase-before? (appliance-provisioning-state-phase state)
                       'database_published)
    (ensure-state-directory!)
    (when (canonical-database-exists?)
      (raise-provisioning-error
       'database_exists "Canonical database appeared during provisioning."))
    (publish-database! catalog-path register-configuration-path)
    (advance! 'database_published))
  (when (phase-before? (appliance-provisioning-state-phase state) 'core_ready)
    (unless (canonical-database-exists?)
      (raise-provisioning-error
       'database_missing "The published canonical database is missing."))
    (enable-core!)
    (unless (core-ready?)
      (raise-provisioning-error
       'core_not_ready "POS Core did not reach readiness."))
    (advance! 'core_ready))
  (when (phase-before? (appliance-provisioning-state-phase state)
                       'kiosk_configured)
    ;; PLM/autologin belongs here so a cashier cannot enter a half-provisioned
    ;; appliance before the backend is known ready.
    (configure-kiosk!)
    (advance! 'kiosk_configured))
  (advance! 'complete)
  state)
