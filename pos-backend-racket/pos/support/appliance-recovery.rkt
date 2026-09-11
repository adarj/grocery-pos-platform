#lang racket

(require ffi/unsafe
         json
         net/http-client
         racket/file
         racket/port
         racket/string
         "../persistence/atomic-file.rkt"
         "../persistence/sqlite-restore.rkt"
         "../runtime-config.rkt")

(provide canonical-pos-database-path
         canonical-pos-environment-path
         pos-core-systemd-unit
         restore-readiness-timeout-seconds
         pos-effective-user-id
         (struct-out exn:fail:appliance-recovery)
         (struct-out appliance-restore-success)
         read-pos-core-listener-config
         restore-pos-appliance!)

(define canonical-pos-database-path
  (string->path "/var/lib/grocery-pos/pos.db"))
(define canonical-pos-environment-path
  (string->path "/etc/grocery-pos/pos-core.env"))
(define pos-core-systemd-unit "grocery-pos-core")
(define restore-readiness-timeout-seconds 30)
(define readiness-poll-seconds 0.25)

(struct exn:fail:appliance-recovery exn:fail
  (code operation-id recovery-directory)
  #:transparent)

(struct appliance-restore-success
  (operation-id recovery-directory restored-schema-version
                service-status readiness-status)
  #:transparent)

(define geteuid
  (get-ffi-obj "geteuid" #f (_fun -> _uint)))

(define (pos-effective-user-id)
  (geteuid))

(define (raise-recovery-error code message
                              #:operation-id [operation-id #f]
                              #:recovery-directory [recovery-directory #f])
  (raise
   (exn:fail:appliance-recovery
    message
    (current-continuation-marks)
    code
    operation-id
    recovery-directory)))

(define (run-absolute-command executable . arguments)
  (parameterize ([current-output-port (open-output-nowhere)]
                 [current-error-port (open-output-nowhere)])
    (apply system* executable arguments)))

(define (stop-pos-core-service!)
  (run-absolute-command
   "/usr/bin/systemctl" "stop" pos-core-systemd-unit))

(define (start-pos-core-service!)
  (run-absolute-command
   "/usr/bin/systemctl" "start" pos-core-systemd-unit))

(define (pos-core-service-active?)
  (run-absolute-command
   "/usr/bin/systemctl" "is-active" "--quiet" pos-core-systemd-unit))

(define (finalize-canonical-database! installed)
  (define database-path
    (prepared-sqlite-restore-target-path
     (sqlite-restore-installed-prepared installed)))
  (define recovery-directory
    (sqlite-restore-installed-recovery-directory installed))
  (unless
      (run-absolute-command
       "/usr/bin/chown" "root:root" "--" (path->string recovery-directory))
    (error 'restore-pos-appliance! "could not protect recovery evidence"))
  (file-or-directory-permissions recovery-directory #o700)
  (unless
      (run-absolute-command
       "/usr/bin/chown"
       "grocery-pos:grocery-pos"
       "--"
       (path->string database-path))
    (error 'restore-pos-appliance! "could not set restored database ownership"))
  (file-or-directory-permissions database-path #o640)
  (synchronize-file! database-path #:who 'restore-pos-appliance!)
  (synchronize-directory! (path-only database-path)
                          #:who 'restore-pos-appliance!)
  #t)

(define (parse-pos-core-environment path)
  (define values (make-hash))
  (when (file-exists? path)
    (call-with-input-file
     path
     (lambda (input)
       (for ([line (in-lines input)])
         (define trimmed (string-trim line))
         (unless (or (string=? trimmed "")
                     (string-prefix? trimmed "#"))
           (match (regexp-match #px"^([A-Z0-9_]+)=(.*)$" trimmed)
             [(list _ key value)
              (when (member key '("RACKET_API_HOST" "RACKET_API_PORT"))
                (when (hash-has-key? values key)
                  (error 'read-pos-core-listener-config
                         "duplicate POS Core listener configuration key"))
                (hash-set! values key value))]
             [_
              (error 'read-pos-core-listener-config
                     "invalid POS Core environment-file syntax")]))))))
  values)

(define (read-pos-core-listener-config
         [path canonical-pos-environment-path])
  (define environment-values (parse-pos-core-environment path))
  (define host
    (hash-ref environment-values "RACKET_API_HOST" "127.0.0.1"))
  (define port-text
    (hash-ref environment-values "RACKET_API_PORT" "7340"))
  (define port (string->number port-text))
  ;; Reuse the application's strict literal-loopback and legal-port guard.
  (define config
    (pos-runtime-config host port canonical-pos-database-path))
  (values (pos-runtime-config-host config)
          (pos-runtime-config-port config)))

(define (production-readiness-ready?)
  (with-handlers ([(lambda (_value) #t) (lambda (_value) #f)])
    (define-values (host port) (read-pos-core-listener-config))
    (define-values (status _headers body-port)
      (http-sendrecv host "/ready" #:port port #:method #"GET"))
    (define body
      (dynamic-wind
        void
        (lambda () (read-json body-port))
        (lambda () (close-input-port body-port))))
    (and (regexp-match? #rx#" 200 " status)
         (hash? body)
         (eq? (hash-ref body 'ok #f) #t)
         (equal? (hash-ref body 'status #f) "ready"))))

(define (wait-for-readiness service-active? readiness-ready?
                            now-seconds sleep-proc timeout-seconds)
  (define deadline (+ (now-seconds) timeout-seconds))
  (let loop ()
    (cond
      [(not (service-active?)) #f]
      [(readiness-ready?) #t]
      [(>= (now-seconds) deadline) #f]
      [else
       (sleep-proc readiness-poll-seconds)
       (loop)])))

(define (restore-pos-appliance!
         backup-path
         #:effective-user-id [effective-user-id pos-effective-user-id]
         #:prepare [prepare prepare-pos-sqlite-restore!]
         #:abandon [abandon abandon-prepared-pos-sqlite-restore!]
         #:stop-service! [stop-service! stop-pos-core-service!]
         #:service-active? [service-active? pos-core-service-active?]
         #:install [install install-prepared-pos-sqlite-restore!]
         #:finalize-installed!
         [finalize-installed! finalize-canonical-database!]
         #:start-service! [start-service! start-pos-core-service!]
         #:readiness-ready? [readiness-ready? production-readiness-ready?]
         #:readiness-timeout-seconds
         [readiness-timeout-seconds restore-readiness-timeout-seconds]
         #:now-seconds
         [now-seconds (lambda () (/ (current-inexact-milliseconds) 1000.0))]
         #:sleep [sleep-proc sleep])
  (unless (zero? (effective-user-id))
    (raise-recovery-error
     'not_privileged
     "Appliance restore requires root privilege."))

  (define prepared
    (with-handlers
        ([exn:fail:pos-restore?
          (lambda (exception)
            (raise-recovery-error
             (exn:fail:pos-restore-code exception)
             "The selected backup could not be staged safely."
             #:operation-id
             (exn:fail:pos-restore-operation-id exception)))])
      (prepare backup-path canonical-pos-database-path)))
  (define operation-id
    (prepared-sqlite-restore-operation-id prepared))

  (unless (stop-service!)
    (abandon prepared)
    (raise-recovery-error
     'service_stop_failed
     "POS Core could not be stopped."
     #:operation-id operation-id))
  (when (service-active?)
    (abandon prepared)
    (raise-recovery-error
     'service_still_active
     "POS Core remains active; canonical state was not changed."
     #:operation-id operation-id))

  (define installed
    (with-handlers
        ([exn:fail:pos-restore?
          (lambda (exception)
            (raise-recovery-error
             (exn:fail:pos-restore-code exception)
             "Offline canonical database replacement failed."
             #:operation-id
             (exn:fail:pos-restore-operation-id exception)
             #:recovery-directory
             (exn:fail:pos-restore-recovery-directory exception)))])
      (install prepared)))
  (define recovery-directory
    (sqlite-restore-installed-recovery-directory installed))

  (with-handlers
      ([exn:fail?
        (lambda (_exception)
          (raise-recovery-error
           'ownership_failed
           "Restored database ownership or mode could not be finalized."
           #:operation-id operation-id
           #:recovery-directory recovery-directory))])
    (unless (finalize-installed! installed)
      (error 'restore-pos-appliance! "database finalization failed")))

  (unless (start-service!)
    (stop-service!)
    (raise-recovery-error
     'service_start_failed
     "POS Core could not be started after restore."
     #:operation-id operation-id
     #:recovery-directory recovery-directory))

  (unless (wait-for-readiness service-active?
                              readiness-ready?
                              now-seconds
                              sleep-proc
                              readiness-timeout-seconds)
    ;; This stop is intentionally not a rollback. Both the installed candidate
    ;; and the displaced evidence remain for an explicit technician decision.
    (stop-service!)
    (raise-recovery-error
     'readiness_failed
     "Restored POS Core did not become ready and was stopped."
     #:operation-id operation-id
     #:recovery-directory recovery-directory))

  (appliance-restore-success
   operation-id
   recovery-directory
   (sqlite-restore-installed-restored-schema-version installed)
   'active
   'ready))
