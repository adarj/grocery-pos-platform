#lang racket

(require file/sha1
         file/tar
         json
         net/http-client
         racket/file
         racket/list
         racket/port
         racket/random
         racket/string
         racket/system
         "../persistence/atomic-file.rkt"
         "../persistence/sqlite-maintenance.rkt"
         "appliance-recovery.rkt")

(provide support-bundle-schema-version
         (struct-out support-bundle-created)
         collect-pos-support-bundle!)

(define support-bundle-schema-version 1)
(define support-section-schema-version 1)
(define collector-application-version "0.0.0-dev")
(define maximum-command-output-bytes (* 64 1024))
(define maximum-api-response-bytes (* 8 1024))

(struct support-bundle-created (path bundle-id generated-at-epoch-ms)
  #:transparent)

(define (checked-path who label value)
  (unless (path-string? value)
    (raise-argument-error who "path-string?" value))
  (define path-value (if (path? value) value (string->path value)))
  (when (zero? (bytes-length (path->bytes path-value)))
    (raise-arguments-error who "path must not be empty" label value))
  (simplify-path (path->complete-path path-value) #f))

(define (safe-hash-ref value key [default #f])
  (if (hash? value) (hash-ref value key default) default))

(define (optional-json-number value)
  (if (number? value) value (json-null)))

(define (optional-json-string value)
  (if (string? value) value (json-null)))

(define (safe-command-output executable . arguments)
  (with-handlers ([(lambda (_value) #t) (lambda (_value) #f)])
    (define-values (process stdout stdin _stderr)
      (apply subprocess #f #f 'stdout executable arguments))
    (close-output-port stdin)
    (define output
      (dynamic-wind
        void
        (lambda () (read-bytes (add1 maximum-command-output-bytes) stdout))
        (lambda () (close-input-port stdout))))
    (define oversized?
      (and (bytes? output)
           (> (bytes-length output) maximum-command-output-bytes)))
    (when oversized? (subprocess-kill process #t))
    (subprocess-wait process)
    (and (not oversized?)
         (zero? (subprocess-status process))
         (bytes? output)
         (string-trim (bytes->string/utf-8 output)))))

(define (parse-key-value-lines text)
  (for/fold ([result (hasheq)])
            ([line (in-list (string-split text "\n" #:trim? #f))])
    (match (regexp-match #px"^([^=]+)=(.*)$" line)
      [(list _ key value) (hash-set result (string->symbol key) value)]
      [_ result])))

(define (strip-outer-quotes value)
  (if (and (>= (string-length value) 2)
           (char=? (string-ref value 0) #\")
           (char=? (string-ref value (sub1 (string-length value))) #\"))
      (substring value 1 (sub1 (string-length value)))
      value))

(define (read-os-release)
  (with-handlers ([exn:fail? (lambda (_exception) (hasheq))])
    (call-with-input-file
     "/etc/os-release"
     (lambda (input)
       (for/fold ([result (hasheq)])
                 ([line (in-lines input)])
         (match (regexp-match #px"^([A-Z0-9_]+)=(.*)$" line)
           [(list _ key value)
            (if (member key '("ID" "VERSION_ID" "VARIANT_ID"))
                (hash-set result
                          (string->symbol key)
                          (strip-outer-quotes value))
                result)]
           [_ result]))))))

(define (default-platform-provider)
  (define release (read-os-release))
  (hasheq
   'os_id (hash-ref release 'ID #f)
   'os_version_id (hash-ref release 'VERSION_ID #f)
   'os_variant_id (hash-ref release 'VARIANT_ID #f)
   'kernel_release (safe-command-output "/usr/bin/uname" "-r")
   'cpu_architecture (safe-command-output "/usr/bin/uname" "-m")))

(define (default-package-provider)
  (define output
    (safe-command-output
     "/usr/bin/rpm"
     "-q"
     "--queryformat"
     "%{NAME}\t%{VERSION}\t%{RELEASE}\t%{ARCH}"
     "grocery-pos-core"))
  (define values (and output (string-split output "\t" #:trim? #f)))
  (if (and values (= (length values) 4))
      (hasheq 'name (list-ref values 0)
              'version (list-ref values 1)
              'release (list-ref values 2)
              'architecture (list-ref values 3))
      (hasheq)))

(define service-properties
  '(LoadState ActiveState SubState UnitFileState Result
              ExecMainCode ExecMainStatus NRestarts))

(define (default-service-provider)
  (define output
    (safe-command-output
     "/usr/bin/systemctl"
     "show"
     pos-core-systemd-unit
     (string-append
      "--property="
      (string-join (map symbol->string service-properties) ","))))
  (if output (parse-key-value-lines output) (hasheq)))

(define (response-status-code status)
  (match (regexp-match #rx#" ([0-9][0-9][0-9]) " status)
    [(list _ digits) (string->number (bytes->string/utf-8 digits))]
    [_ #f]))

(define (fetch-safe-api-state host port path)
  (with-handlers ([(lambda (_value) #t)
                   (lambda (_value) (hasheq 'availability "unreachable"))])
    (define-values (status _headers body-port)
      (http-sendrecv host path #:port port #:method #"GET"))
    (define body-bytes
      (dynamic-wind
        void
        (lambda () (read-bytes (add1 maximum-api-response-bytes) body-port))
        (lambda () (close-input-port body-port))))
    (unless (and (bytes? body-bytes)
                 (<= (bytes-length body-bytes) maximum-api-response-bytes))
      (error 'fetch-safe-api-state "API response exceeds diagnostic limit"))
    (define body (bytes->jsexpr body-bytes))
    (hasheq
     'availability "available"
     'http_status (response-status-code status)
     'ok (safe-hash-ref body 'ok #f)
     'service (safe-hash-ref body 'service #f)
     'status (safe-hash-ref body 'status #f)
     'reason (safe-hash-ref body 'reason #f)
     'database_schema_version
     (safe-hash-ref body 'database_schema_version #f))))

(define (default-api-provider)
  (define-values (host port) (read-pos-core-listener-config))
  (hasheq 'health (fetch-safe-api-state host port "/health")
          'ready (fetch-safe-api-state host port "/ready")))

(define (default-storage-provider state-path)
  (define output
    (safe-command-output
     "/usr/bin/df"
     "-B1"
     "--output=size,used,avail,pcent"
     (path->string state-path)))
  (define lines
    (and output
         (filter (lambda (line) (not (string=? (string-trim line) "")))
                 (string-split output "\n"))))
  (define fields
    (and lines
         (>= (length lines) 2)
         (string-split (string-trim (last lines)))))
  (if (and fields (= (length fields) 4))
      (hasheq
       'total_bytes (string->number (list-ref fields 0))
       'used_bytes (string->number (list-ref fields 1))
       'available_bytes (string->number (list-ref fields 2))
       'usage_percent
       (string->number (string-trim (list-ref fields 3) "%")))
      (hasheq)))

(define (sanitize-provider provider sanitizer)
  (with-handlers ([(lambda (_value) #t)
                   (lambda (_value) (hasheq 'availability "unavailable"))])
    (sanitizer (provider))))

(define (sanitize-platform value)
  (hasheq 'availability "available"
          'os_id (optional-json-string (safe-hash-ref value 'os_id))
          'os_version_id
          (optional-json-string (safe-hash-ref value 'os_version_id))
          'os_variant_id
          (optional-json-string (safe-hash-ref value 'os_variant_id))
          'kernel_release
          (optional-json-string (safe-hash-ref value 'kernel_release))
          'cpu_architecture
          (optional-json-string (safe-hash-ref value 'cpu_architecture))))

(define (sanitize-package value)
  (hasheq 'availability
          (if (string? (safe-hash-ref value 'name)) "available" "unavailable")
          'name (optional-json-string (safe-hash-ref value 'name))
          'version (optional-json-string (safe-hash-ref value 'version))
          'release (optional-json-string (safe-hash-ref value 'release))
          'architecture
          (optional-json-string (safe-hash-ref value 'architecture))))

(define (service-value value key)
  (define raw (safe-hash-ref value key))
  (if (member key '(ExecMainCode ExecMainStatus NRestarts))
      (let ([number (cond [(number? raw) raw]
                          [(string? raw) (string->number raw)]
                          [else #f])])
        (optional-json-number number))
      (optional-json-string raw)))

(define (sanitize-service value)
  (hasheq
   'availability
   (if (string? (safe-hash-ref value 'LoadState)) "available" "unavailable")
   'load_state (service-value value 'LoadState)
   'active_state (service-value value 'ActiveState)
   'sub_state (service-value value 'SubState)
   'unit_file_state (service-value value 'UnitFileState)
   'result (service-value value 'Result)
   'exec_main_code (service-value value 'ExecMainCode)
   'exec_main_status (service-value value 'ExecMainStatus)
   'restart_count (service-value value 'NRestarts)))

(define (sanitize-api-endpoint value)
  (if (hash? value)
      (hasheq
       'availability
       (if (equal? (safe-hash-ref value 'availability) "unreachable")
           "unreachable"
           "available")
       'http_status (optional-json-number (safe-hash-ref value 'http_status))
       'ok (and (safe-hash-ref value 'ok #f) #t)
       'service (optional-json-string (safe-hash-ref value 'service))
       'status (optional-json-string (safe-hash-ref value 'status))
       'reason (optional-json-string (safe-hash-ref value 'reason))
       'database_schema_version
       (optional-json-number
        (safe-hash-ref value 'database_schema_version)))
      (hasheq 'availability "unreachable")))

(define (sanitize-api value)
  (hasheq 'availability "available"
          'health (sanitize-api-endpoint (safe-hash-ref value 'health))
          'ready (sanitize-api-endpoint (safe-hash-ref value 'ready))))

(define (sanitize-storage value)
  (hasheq
   'availability
   (if (number? (safe-hash-ref value 'total_bytes))
       "available"
       "unavailable")
   'total_bytes (optional-json-number (safe-hash-ref value 'total_bytes))
   'used_bytes (optional-json-number (safe-hash-ref value 'used_bytes))
   'available_bytes
   (optional-json-number (safe-hash-ref value 'available_bytes))
   'usage_percent
   (optional-json-number (safe-hash-ref value 'usage_percent))))

(define (history->json history)
  (if (list? history)
      (for/list ([entry (in-list history)])
        (hasheq 'version (vector-ref entry 0)
                'name (vector-ref entry 1)))
      (json-null)))

(define (sanitize-database-info info)
  (hasheq
   'availability
   (if (sqlite-database-info-read-only-openable? info)
       "available"
       "unavailable")
   'file_present (sqlite-database-info-file-exists? info)
   'regular_file (sqlite-database-info-regular-file? info)
   'read_only_openable (sqlite-database-info-read-only-openable? info)
   'journal_mode
   (optional-json-string (sqlite-database-info-journal-mode info))
   'migration_status
   (symbol->string (sqlite-database-info-migration-status info))
   'migration_history
   (history->json (sqlite-database-info-migration-history info))
   'highest_applied_migration_version
   (optional-json-number
    (sqlite-database-info-highest-applied-migration-version info))
   'current_supported_migration_version
   (sqlite-database-info-current-supported-migration-version info)
   'schema_valid (sqlite-database-info-schema-valid? info)
   'page_size (optional-json-number (sqlite-database-info-page-size info))
   'page_count (optional-json-number (sqlite-database-info-page-count info))
   'freelist_count
   (optional-json-number (sqlite-database-info-freelist-count info))
   'main_file_size
   (optional-json-number (sqlite-database-info-main-file-size info))
   'wal
   (hasheq 'present (sqlite-database-info-wal-file-exists? info)
           'size
           (optional-json-number (sqlite-database-info-wal-file-size info)))
   'shm
   (hasheq 'present (sqlite-database-info-shm-file-exists? info)
           'size
           (optional-json-number (sqlite-database-info-shm-file-size info)))))

(define (collect-database-info database-path inspector)
  (with-handlers ([(lambda (_value) #t)
                   (lambda (_value)
                     (hasheq 'availability "unavailable"
                             'file_present #f
                             'regular_file #f
                             'read_only_openable #f
                             'migration_status "unavailable"))])
    (sanitize-database-info (inspector database-path))))

(define (write-json-file! directory name value)
  (define path (build-path directory name))
  (call-with-output-file
   path
   #:exists 'error
   (lambda (output)
     (write-json value output)
     (newline output)))
  (file-or-directory-permissions path #o600)
  (synchronize-file! path #:who 'collect-pos-support-bundle!)
  path)

(define section-names
  '("platform.json" "package.json" "service.json" "database.json"
                    "api.json" "storage.json"))

(define excluded-sensitive-categories
  '("authoritative POS database and SQLite sidecars"
    "backup databases and displaced recovery state"
    "transaction events, receipts, catalog, cashier, and shift contents"
    "raw journal messages"
    "complete configuration files and process environments"
    "hostnames, machine identifiers, network identifiers, and device identifiers"
    "credentials, keys, tokens, passwords, and payment data"))

(define (collect-pos-support-bundle!
         database-path
         output-path
         #:platform-provider [platform-provider default-platform-provider]
         #:package-provider [package-provider default-package-provider]
         #:service-provider [service-provider default-service-provider]
         #:database-inspector [database-inspector inspect-pos-sqlite-database]
         #:api-provider [api-provider default-api-provider]
         #:storage-provider [storage-provider default-storage-provider])
  (define who 'collect-pos-support-bundle!)
  (define database (checked-path who "database-path" database-path))
  (define output (checked-path who "output-path" output-path))
  (define output-parent (path-only output))
  (unless (and output-parent (directory-exists? output-parent))
    (raise-arguments-error
     who "output parent directory must already exist" "output-path" output))
  (when (file-or-directory-type output #f)
    (raise-arguments-error
     who "support bundle destination already exists" "output-path" output))

  (define generated-at
    (inexact->exact (floor (current-inexact-milliseconds))))
  (define bundle-id
    (string-append "support-"
                   (bytes->hex-string (crypto-random-bytes 16))))
  (define staging-directory
    (make-temporary-file ".grocery-pos-support.~a.partial" 'directory
                         output-parent))
  (file-or-directory-permissions staging-directory #o700)
  (define candidate-path (build-path staging-directory "bundle.tar.gz"))

  (with-handlers
      ([(lambda (_value) #t)
        (lambda (value)
          (when (directory-exists? staging-directory)
            (with-handlers ([exn:fail? void])
              (delete-directory/files staging-directory)))
          (raise value))])
    (define sections
      (hasheq
       'platform.json
       (sanitize-provider platform-provider sanitize-platform)
       'package.json
       (sanitize-provider package-provider sanitize-package)
       'service.json
       (sanitize-provider service-provider sanitize-service)
       'database.json
       (collect-database-info database database-inspector)
       'api.json
       (sanitize-provider api-provider sanitize-api)
       'storage.json
       (with-handlers ([(lambda (_value) #t)
                        (lambda (_value)
                          (hasheq 'availability "unavailable"))])
         (sanitize-storage
          (storage-provider (or (path-only database) database))))))
    (define manifest
      (hasheq
       'support_bundle_schema_version support-bundle-schema-version
       'generated_at_epoch_ms generated-at
       'bundle_id bundle-id
       'collector_application_version collector-application-version
       'included_sections
       (for/list ([name (in-list section-names)])
         (hasheq 'name name
                 'schema_version support-section-schema-version))
       'excluded_sensitive_categories excluded-sensitive-categories))

    (write-json-file! staging-directory "manifest.json" manifest)
    (for ([name (in-list section-names)])
      (write-json-file!
       staging-directory
       name
       (hash-ref sections (string->symbol name))))
    (synchronize-directory! staging-directory #:who who)

    (parameterize ([current-directory staging-directory])
      (apply tar-gzip
             candidate-path
             #:timestamp (current-seconds)
             (cons "manifest.json" section-names)))
    (file-or-directory-permissions candidate-path #o600)
    (synchronize-file! candidate-path #:who who)
    (atomic-rename-file-no-replace! candidate-path output #:who who)
    (file-or-directory-permissions output #o600)
    (synchronize-file! output #:who who)
    (synchronize-directory! output-parent #:who who)
    (delete-directory/files staging-directory)
    (support-bundle-created output bundle-id generated-at)))
