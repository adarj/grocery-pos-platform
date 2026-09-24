#lang racket

(require (prefix-in db: db)
         json
         net/http-client
         racket/file
         racket/port
         racket/string
         "../pos/application/operator-service.rkt"
         "../pos/persistence/atomic-file.rkt"
         "../pos/persistence/pos-database-migrations.rkt"
         "../pos/support/appliance-provisioning.rkt"
         "../pos/support/appliance-recovery.rkt"
         "catalog.rkt"
         "register-configuration.rkt")

(provide run-appliance-cli appliance-auth-status)

(define canonical-database (string->path "/var/lib/grocery-pos/pos.db"))
(define provisioning-state-directory
  (string->path "/var/lib/grocery-pos-appliance"))
(define provisioning-state-path
  (build-path provisioning-state-directory "provisioning-v1.json"))
(define maintenance-directory
  (string->path "/run/grocery-pos-appliance"))
(define maintenance-marker
  (build-path maintenance-directory "kiosk-maintenance"))
(define appliance-flatpak-id "com.grocerypos.pos_terminal")
(define appliance-flatpak-ref
  "app/com.grocerypos.pos_terminal/x86_64/stable")
(define readiness-timeout-seconds 30)

(define usage
  (string-append
   "Usage:\n"
   "  grocery-pos-appliance status\n"
   "  grocery-pos-appliance kiosk-stop\n"
   "  grocery-pos-appliance kiosk-start\n"
   "  grocery-pos-appliance provision --terminal-flatpak FILE"
   " --catalog FILE --register-config FILE\n"))

(define (write-json-line value output)
  (write-json value output)
  (newline output))

(define (run-command executable . arguments)
  (parameterize ([current-output-port (open-output-nowhere)]
                 [current-error-port (open-output-nowhere)])
    (apply system* executable arguments)))

(define (command-output executable . arguments)
  (define output (open-output-string))
  (define succeeded?
    (parameterize ([current-output-port output]
                   [current-error-port (open-output-nowhere)])
      (apply system* executable arguments)))
  (values succeeded? (string-trim (get-output-string output))))

(define (require-root!)
  (unless (zero? (pos-effective-user-id))
    (raise
     (exn:fail:appliance-provisioning
      "This appliance operation requires root privilege."
      (current-continuation-marks)
      'not_privileged))))

(define (unquote-os-release-value value)
  (define length (string-length value))
  (if (and (>= length 2)
           (char=? (string-ref value 0) #\")
           (char=? (string-ref value (sub1 length)) #\"))
      (substring value 1 (sub1 length))
      value))

(define (read-os-release [path "/etc/os-release"])
  (define values (make-hash))
  (call-with-input-file
   path
   (lambda (input)
     (for ([line (in-lines input)])
       (match (regexp-match #px"^([A-Z0-9_]+)=(.*)$" line)
         [(list _ key value)
          (hash-set! values key (unquote-os-release-value value))]
         [_ (void)]))))
  values)

(define (current-host-profile)
  (define release (read-os-release))
  (define-values (uname-ok? architecture)
    (command-output "/usr/bin/uname" "-m"))
  (appliance-host-profile
   (hash-ref release "ID" "")
   (hash-ref release "VERSION_ID" "")
   (hash-ref release "VARIANT_ID" "")
   (if uname-ok? architecture "")
   (or (file-exists? "/run/ostree-booted")
       (directory-exists? "/run/ostree-booted")
       (link-exists? "/run/ostree-booted"))))

(define (state->jsexpr state)
  (define hashes (appliance-provisioning-state-input-hashes state))
  (hasheq
   'schema_version (appliance-provisioning-state-schema-version state)
   'operation_id (appliance-provisioning-state-operation-id state)
   'phase (symbol->string (appliance-provisioning-state-phase state))
   'input_hashes
   (hasheq
    'terminal_flatpak
    (appliance-provisioning-input-hashes-terminal-flatpak hashes)
    'catalog (appliance-provisioning-input-hashes-catalog hashes)
    'register_configuration
    (appliance-provisioning-input-hashes-register-configuration hashes))))

(define (jsexpr->state value)
  (unless (hash? value)
    (error 'read-provisioning-state "state is not a JSON object"))
  (define hashes (hash-ref value 'input_hashes))
  (appliance-provisioning-state
   (hash-ref value 'schema_version)
   (hash-ref value 'operation_id)
   (string->symbol (hash-ref value 'phase))
   (appliance-provisioning-input-hashes
    (hash-ref hashes 'terminal_flatpak)
    (hash-ref hashes 'catalog)
    (hash-ref hashes 'register_configuration))))

(define (read-provisioning-state)
  (and (file-exists? provisioning-state-path)
       (call-with-input-file provisioning-state-path
         (lambda (input) (jsexpr->state (read-json input))))))

(define (write-provisioning-state! state)
  (make-directory* provisioning-state-directory)
  (file-or-directory-permissions provisioning-state-directory #o700)
  (define temporary
    (make-temporary-file ".provisioning-state-~a.partial"
                         #f provisioning-state-directory))
  (dynamic-wind
    void
    (lambda ()
      (call-with-output-file temporary
        (lambda (output)
          (write-json (state->jsexpr state) output)
          (newline output)
          (flush-output output))
        #:exists 'truncate)
      (file-or-directory-permissions temporary #o600)
      (synchronize-file! temporary #:who 'write-provisioning-state!)
      (rename-file-or-directory temporary provisioning-state-path #t)
      (synchronize-directory! provisioning-state-directory
                              #:who 'write-provisioning-state!))
    (lambda ()
      (when (file-exists? temporary)
        (with-handlers ([exn:fail? void]) (delete-file temporary))))))

(define (validate-flatpak-bundle! path)
  (define repository
    (make-temporary-file "grocery-pos-flatpak-inspection-~a" 'directory))
  (dynamic-wind
    void
    (lambda ()
      (unless (run-command "/usr/bin/ostree" "init"
                           (string-append "--repo="
                                          (path->string repository))
                           "--mode=archive")
        (error 'validate-flatpak-bundle! "Flatpak repository setup failed"))
      (unless (run-command "/usr/bin/flatpak"
                           "build-import-bundle"
                           (path->string repository)
                           path)
        (error 'validate-flatpak-bundle! "Flatpak bundle import failed"))
      (define-values (ref-ok? ref)
        (command-output "/usr/bin/ostree"
                        "refs"
                        (string-append "--repo="
                                       (path->string repository))))
      (unless (and ref-ok? (string=? ref appliance-flatpak-ref))
        (error 'validate-flatpak-bundle!
               "Flatpak bundle identity or branch is unsupported")))
    (lambda () (delete-directory/files repository))))

(define (canonical-snapshot-valid? runner path)
  (zero?
   (runner (vector "validate" path)
           #:output-port (open-output-nowhere)
           #:error-port (open-output-nowhere))))

(define (validate-provisioning-inputs! terminal catalog register)
  (validate-flatpak-bundle! terminal)
  (unless (canonical-snapshot-valid? run-catalog-cli catalog)
    (error 'validate-provisioning-inputs! "Catalog validation failed"))
  (unless (canonical-snapshot-valid?
           run-register-configuration-cli register)
    (error 'validate-provisioning-inputs!
           "Register configuration validation failed")))

(define (install-terminal! path)
  (unless (run-command "/usr/bin/flatpak"
                       "install" "--system" "--noninteractive"
                       "--or-update" path)
    (error 'install-terminal! "System Flatpak installation failed")))

(define (terminal-installed?)
  (define-values (ok? ref)
    (command-output "/usr/bin/flatpak" "info" "--system" "--show-ref"
                    appliance-flatpak-id))
  (and ok? (string=? ref appliance-flatpak-ref)))

(define (kiosk-user-exists?)
  (run-command "/usr/bin/id" "-u" "grocery-pos-kiosk"))

(define (kiosk-user-ready?)
  (and
   (kiosk-user-exists?)
   (let-values ([(passwd-ok? passwd-entry)
                 (command-output "/usr/bin/getent" "passwd"
                                 "grocery-pos-kiosk")]
                [(groups-ok? groups-text)
                 (command-output "/usr/bin/id" "-nG"
                                 "grocery-pos-kiosk")]
                [(status-ok? password-status)
                 (command-output "/usr/bin/passwd" "--status"
                                 "grocery-pos-kiosk")])
     (define passwd-fields
       (and passwd-ok? (string-split passwd-entry ":")))
     (define groups (and groups-ok? (string-split groups-text)))
     (and passwd-fields
          (= (length passwd-fields) 7)
          (equal? (list-ref passwd-fields 5) "/var/lib/grocery-pos-kiosk")
          (equal? (list-ref passwd-fields 6) "/bin/bash")
          groups
          (not (member "wheel" groups))
          (not (member "grocery-pos" groups))
          status-ok?
          (regexp-match? #px"^grocery-pos-kiosk L(?: |$)"
                         password-status)))))

(define (ensure-kiosk-user!)
  (unless (kiosk-user-exists?)
    (unless
        (run-command
         "/usr/sbin/useradd"
         "--create-home"
         "--home-dir" "/var/lib/grocery-pos-kiosk"
         "--shell" "/bin/bash"
         "--user-group"
         "--comment" "Grocery POS cashier kiosk"
         "grocery-pos-kiosk")
      (error 'ensure-kiosk-user! "Kiosk user creation failed")))
  (unless (run-command "/usr/bin/passwd" "--lock" "grocery-pos-kiosk")
    (error 'ensure-kiosk-user! "Kiosk account could not be locked"))
  (unless (kiosk-user-ready?)
    (error 'ensure-kiosk-user!
           "Kiosk account properties do not satisfy appliance policy")))

(define (finalize-initial-candidate! path)
  (unless (run-command "/usr/bin/chown"
                       "grocery-pos:grocery-pos" "--" (path->string path))
    (error 'finalize-initial-candidate! "Database ownership failed"))
  (file-or-directory-permissions path #o640))

(define (ensure-canonical-state-directory!)
  (define state-directory (path-only canonical-database))
  (when (link-exists? state-directory)
    (error 'ensure-canonical-state-directory!
           "Canonical state directory must not be a symbolic link"))
  (define existing-type (file-or-directory-type state-directory #f))
  (when (and existing-type (not (eq? existing-type 'directory)))
    (error 'ensure-canonical-state-directory!
           "Canonical state path is not a directory"))
  (unless (run-command "/usr/bin/install" "-d" "-m" "0750"
                       "-o" "grocery-pos" "-g" "grocery-pos"
                       (path->string state-directory))
    (error 'ensure-canonical-state-directory!
           "Canonical state directory could not be prepared"))
  (when (or (link-exists? state-directory)
            (not (eq? (file-or-directory-type state-directory #f)
                      'directory)))
    (error 'ensure-canonical-state-directory!
           "Canonical state directory failed validation")))

(define (publish-initial-database! catalog register)
  (build-initial-pos-database!
   catalog register canonical-database
   #:finalize-candidate! finalize-initial-candidate!))

(define (local-api-response? path expected-status)
  (with-handlers ([(lambda (_value) #t) (lambda (_value) #f)])
    (define-values (host port) (read-pos-core-listener-config))
    (define-values (status _headers body-port)
      (http-sendrecv host path #:port port #:method #"GET"))
    (define body
      (dynamic-wind
        void
        (lambda () (read-json body-port))
        (lambda () (close-input-port body-port))))
    (and (regexp-match? #rx#" 200 " status)
         (hash? body)
         (eq? (hash-ref body 'ok #f) #t)
         (or (not expected-status)
             (equal? (hash-ref body 'status #f) expected-status)))))

(define (ready-response?)
  (local-api-response? "/ready" "ready"))

(define (health-response?)
  (local-api-response? "/health" #f))

(define (wait-for-core-readiness)
  (define deadline
    (+ (current-inexact-milliseconds)
       (* readiness-timeout-seconds 1000)))
  (let loop ()
    (cond
      [(not (run-command "/usr/bin/systemctl" "is-active" "--quiet"
                         "grocery-pos-core.service"))
       #f]
      [(ready-response?) #t]
      [(>= (current-inexact-milliseconds) deadline) #f]
      [else (sleep 0.25) (loop)])))

(define (enable-core!)
  (unless (run-command "/usr/bin/systemctl"
                       "enable" "grocery-pos-core.service")
    (error 'enable-core! "POS Core enablement failed"))
  (unless (run-command "/usr/bin/systemctl"
                       "start" "grocery-pos-core.service")
    (error 'enable-core! "POS Core startup failed")))

(define (configure-kiosk!)
  (unless (run-command
           "/usr/libexec/grocery-pos-appliance/configure-kiosk")
    (error 'configure-kiosk! "Kiosk finalization failed")))

(define (systemd-unit-masked? unit)
  (define-values (_ok? state)
    (command-output "/usr/bin/systemctl" "is-enabled" unit))
  (string=? state "masked"))

(define (kiosk-configured?)
  (and
   (file-exists? "/etc/plasmalogin.conf.d/90-grocery-pos.conf")
   (link-exists?
    "/var/lib/grocery-pos-kiosk/.config/systemd/user/graphical-session.target.wants/grocery-pos-terminal.service")
   (run-command "/usr/bin/systemctl" "is-enabled" "--quiet"
                "plasmalogin.service")
   (for/and ([unit (in-list '("sleep.target"
                              "suspend.target"
                              "hibernate.target"
                              "hybrid-sleep.target"))])
     (systemd-unit-masked? unit))))

(define (run-provision terminal catalog register output)
  (define result
    (provision-pos-appliance!
     terminal catalog register
     #:effective-user-id pos-effective-user-id
     #:host-profile current-host-profile
     #:file-exists?
     (lambda (path) (eq? (file-or-directory-type path #f) 'file))
     #:canonical-database-exists?
     (lambda () (file-or-directory-type canonical-database #f))
     #:validate-inputs! validate-provisioning-inputs!
     #:read-state read-provisioning-state
     #:write-state! write-provisioning-state!
     #:terminal-installed? terminal-installed?
     #:install-terminal! install-terminal!
     #:kiosk-user-ready? kiosk-user-ready?
     #:ensure-kiosk-user! ensure-kiosk-user!
     #:ensure-state-directory! ensure-canonical-state-directory!
     #:publish-database! publish-initial-database!
     #:enable-core! enable-core!
     #:core-ready? wait-for-core-readiness
     #:kiosk-configured? kiosk-configured?
     #:configure-kiosk! configure-kiosk!))
  (write-json-line
   (hasheq 'ok #t
           'operation "provision"
           'operation_id
           (appliance-provisioning-state-operation-id result)
           'phase "complete"
           'reboot_required #t)
   output)
  0)

(define (safe-state-phase)
  (with-handlers ([exn:fail? (lambda (_exception) "unavailable")])
    (define state (read-provisioning-state))
    (if state
        (symbol->string (appliance-provisioning-state-phase state))
        "not_started")))

(define (appliance-auth-status [database-path canonical-database])
  ;; Root-only status opens the current database without creating or migrating
  ;; it. Failure is reported as unavailable readiness, never as a roster.
  (with-handlers ([exn:fail?
                   (lambda (_exception)
                     (hasheq 'register_auth_ready #f
                             'approval_auth_ready #f
                             'audit_event_count (json-null)))])
    (define connection
      (db:sqlite3-connect #:database database-path #:mode 'read-only))
    (dynamic-wind
      void
      (lambda ()
        (validate-pos-database-schema! connection #:require-current? #t)
        (operator-service-auth-status (make-operator-service connection)))
      (lambda () (db:disconnect connection)))))

(define (run-status output)
  (require-root!)
  (define auth-status (appliance-auth-status))
  (define supported?
    (with-handlers ([exn:fail? (lambda (_exception) #f)])
      (validate-kinoite-host! (current-host-profile))
      #t))
  (write-json-line
   (hasheq
    'ok #t
    'operation "status"
    'register_auth_ready (hash-ref auth-status 'register_auth_ready)
    'approval_auth_ready (hash-ref auth-status 'approval_auth_ready)
    'audit_event_count (hash-ref auth-status 'audit_event_count)
    'supported_reference_host supported?
    'ostree_booted (appliance-host-profile-ostree-booted?
                    (current-host-profile))
    'provisioning_phase (safe-state-phase)
    'core_active
    (run-command "/usr/bin/systemctl" "is-active" "--quiet"
                 "grocery-pos-core.service")
    'health (if (health-response?) "healthy" "unreachable")
    'readiness (if (ready-response?) "ready" "not_ready_or_unreachable")
    'kiosk_user_present (kiosk-user-exists?)
    'terminal_flatpak_installed
    (run-command "/usr/bin/flatpak" "info" "--system" appliance-flatpak-id)
    'display_manager
    (if (run-command "/usr/bin/systemctl" "is-enabled" "--quiet"
                     "plasmalogin.service")
        "plasmalogin"
        "not_configured")
    'maintenance_mode (file-exists? maintenance-marker))
   output)
  0)

(define (run-kiosk-stop)
  (require-root!)
  (make-directory* maintenance-directory)
  (file-or-directory-permissions maintenance-directory #o700)
  (display-to-file "temporary kiosk maintenance mode\n"
                   maintenance-marker #:exists 'replace)
  (unless (run-command "/usr/bin/systemctl" "stop" "plasmalogin.service")
    (delete-file maintenance-marker)
    (error 'kiosk-stop "Plasma Login Manager could not be stopped"))
  0)

(define (run-kiosk-start)
  (require-root!)
  (unless (run-command "/usr/bin/systemctl" "start" "plasmalogin.service")
    (error 'kiosk-start "Plasma Login Manager could not be started"))
  (when (file-exists? maintenance-marker) (delete-file maintenance-marker))
  0)

(define (parse-provision-arguments arguments)
  (match arguments
    [(list "provision"
           "--terminal-flatpak" terminal
           "--catalog" catalog
           "--register-config" register)
     (values terminal catalog register)]
    [_ (values #f #f #f)]))

(define (run-appliance-cli
         arguments
         #:output-port [output (current-output-port)]
         #:error-port [error-output (current-error-port)])
  (unless (vector? arguments)
    (raise-argument-error 'run-appliance-cli "vector?" arguments))
  (with-handlers
      ([exn:fail:appliance-provisioning?
        (lambda (exception)
          (write-json-line
           (hasheq
            'ok #f
            'error
            (hasheq
             'code
             (symbol->string
              (exn:fail:appliance-provisioning-code exception))
             'message (exn-message exception)))
           error-output)
          1)]
       [exn:fail?
        (lambda (_exception)
          (write-json-line
           (hasheq 'ok #f
                   'error
                   (hasheq 'code "appliance_operation_failed"
                           'message "The appliance operation failed."))
           error-output)
          1)])
    (match (vector->list arguments)
      [(list "status") (run-status output)]
      [(list "kiosk-stop") (run-kiosk-stop)]
      [(list "kiosk-start") (run-kiosk-start)]
      [provision-arguments
       (define-values (terminal catalog register)
         (parse-provision-arguments provision-arguments))
       (if terminal
           (begin
             (require-root!)
             (run-provision terminal catalog register output))
           (begin (display usage error-output) 2))])))

(module+ main
  (exit (run-appliance-cli (current-command-line-arguments))))
