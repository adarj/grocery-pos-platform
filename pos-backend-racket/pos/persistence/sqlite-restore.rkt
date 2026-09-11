#lang racket

(require file/sha1
         json
         racket/file
         racket/port
         racket/random
         "atomic-file.rkt"
         "pos-database-migrations.rkt"
         "sqlite-maintenance.rkt")

(provide (struct-out exn:fail:pos-restore)
         (struct-out prepared-sqlite-restore)
         (struct-out displaced-sqlite-file)
         (struct-out sqlite-restore-installed)
         prepare-pos-sqlite-restore!
         abandon-prepared-pos-sqlite-restore!
         install-prepared-pos-sqlite-restore!
         restore-pos-sqlite-database-offline!)

(struct exn:fail:pos-restore exn:fail
  (code operation-id recovery-directory displacement-started?)
  #:transparent)

(struct prepared-sqlite-restore
  (operation-id
   started-at-epoch-ms
   backup-path
   target-path
   staging-path
   selected-validation
   staged-validation)
  #:transparent)

(struct displaced-sqlite-file (name size)
  #:transparent)

(struct sqlite-restore-installed
  (prepared recovery-directory displaced-files restored-schema-version)
  #:transparent)

(define canonical-state-suffixes
  (list #"" #"-wal" #"-shm" #"-journal"))

(define (raise-restore-error code message operation-id
                             #:recovery-directory [recovery-directory #f]
                             #:displacement-started?
                             [displacement-started? #f])
  (raise
   (exn:fail:pos-restore
    message
    (current-continuation-marks)
    code
    operation-id
    recovery-directory
    displacement-started?)))

(define (checked-path who label value)
  (unless (path-string? value)
    (raise-argument-error who "path-string?" value))
  (define path-value (if (path? value) value (string->path value)))
  (when (zero? (bytes-length (path->bytes path-value)))
    (raise-arguments-error who "path must not be empty" label value))
  (simplify-path (path->complete-path path-value) #f))

(define (generate-operation-id)
  (string-append
   "restore-"
   (bytes->hex-string (crypto-random-bytes 16))))

(define (valid-operation-id? value)
  (and (string? value)
       (regexp-match? #px"^[a-z0-9][a-z0-9-]{0,79}$" value)))

(define (canonical-state-path target-path suffix)
  (bytes->path
   (bytes-append (path->bytes target-path) suffix)))

(define (path-kind/no-follow path)
  (with-handlers ([exn:fail:filesystem? (lambda (_exception) #f)])
    (define mode
      (hash-ref (file-or-directory-stat path #t) 'mode))
    (case (bitwise-and mode #o170000)
      [(#o100000) 'regular-file]
      [(#o040000) 'directory]
      [(#o120000) 'symlink]
      [(#o010000) 'fifo]
      [(#o140000) 'socket]
      [(#o020000) 'character-device]
      [(#o060000) 'block-device]
      [else 'unsupported])))

(define (check-target-namespace! target-path operation-id)
  (define parent (path-only target-path))
  (unless (and parent (eq? (path-kind/no-follow parent) 'directory))
    (raise-restore-error
     'staging_failed
     "restore target parent must be an existing non-symlink directory"
     operation-id))
  (for ([suffix (in-list canonical-state-suffixes)])
    (define path (canonical-state-path target-path suffix))
    (define kind (path-kind/no-follow path))
    (unless (memq kind '(#f regular-file))
      (raise-restore-error
       'displacement_failed
       "canonical SQLite path is not absent or a regular file"
       operation-id))))

(define (default-make-staging-file! parent-directory)
  (define path
    (make-temporary-file
     ".grocery-pos-restore.~a.partial"
     #f
     parent-directory))
  (file-or-directory-permissions path #o600)
  path)

(define (copy-file-contents! source destination)
  (call-with-input-file
   source
   #:mode 'binary
   (lambda (input)
     (call-with-output-file
      destination
      #:mode 'binary
      #:exists 'truncate
      (lambda (output) (copy-port input output))))))

(define (valid-backup? value)
  (and (sqlite-backup-validation? value)
       (sqlite-backup-validation-valid? value)))

(define (same-existing-file? first second)
  (with-handlers ([exn:fail:filesystem? (lambda (_exception) #f)])
    (and (file-exists? first)
         (file-exists? second)
         (equal? (file-or-directory-identity first)
                 (file-or-directory-identity second)))))

(define (delete-staging-if-owned! path)
  (when (and path (eq? (path-kind/no-follow path) 'regular-file))
    (with-handlers ([exn:fail? void])
      (delete-file path))))

(define (prepare-pos-sqlite-restore!
         backup-path
         target-path
         #:operation-id [operation-id (generate-operation-id)]
         #:validate-backup [validate-backup validate-pos-sqlite-backup]
         #:make-staging-file!
         [make-staging-file! default-make-staging-file!])
  (define who 'prepare-pos-sqlite-restore!)
  (unless (valid-operation-id? operation-id)
    (raise-argument-error who "safe restore operation ID" operation-id))
  (unless (and (procedure? validate-backup)
               (procedure-arity-includes? validate-backup 1))
    (raise-argument-error who "procedure accepting one path" validate-backup))
  (unless (and (procedure? make-staging-file!)
               (procedure-arity-includes? make-staging-file! 1))
    (raise-argument-error
     who "procedure accepting one directory path" make-staging-file!))

  (define backup (checked-path who "backup-path" backup-path))
  (define target (checked-path who "target-path" target-path))
  (when (or (for/or ([suffix (in-list canonical-state-suffixes)])
              (equal? backup (canonical-state-path target suffix)))
            (same-existing-file? backup target))
    (raise-restore-error
     'backup_invalid
     "selected backup must not be a canonical target or sidecar path"
     operation-id))
  (check-target-namespace! target operation-id)

  (define selected-validation
    (with-handlers
        ([exn:fail?
          (lambda (_exception)
            (raise-restore-error
             'backup_invalid
             "selected backup could not be validated"
             operation-id))])
      (validate-backup backup)))
  (unless (valid-backup? selected-validation)
    (raise-restore-error
     'backup_invalid
     "selected backup failed validation"
     operation-id))

  (define staging-path #f)
  (with-handlers
      ([exn:fail:pos-restore?
        (lambda (exception)
          (delete-staging-if-owned! staging-path)
          (raise exception))]
       [exn:fail?
        (lambda (_exception)
          (delete-staging-if-owned! staging-path)
          (raise-restore-error
           'staging_failed
           "restore staging or staged validation failed"
           operation-id))])
    (set! staging-path (make-staging-file! (path-only target)))
    (unless (and (path-string? staging-path)
                 (eq? (path-kind/no-follow staging-path) 'regular-file)
                 (zero? (file-size staging-path))
                 (equal? (path-only (path->complete-path staging-path))
                         (path-only target)))
      (raise-restore-error
       'staging_failed
       "staging creator did not return a new empty same-directory file"
       operation-id))
    (file-or-directory-permissions staging-path #o600)
    (copy-file-contents! backup staging-path)
    (synchronize-file! staging-path #:who who)
    (define staged-validation (validate-backup staging-path))
    (unless (valid-backup? staged-validation)
      (raise-restore-error
       'staging_failed
       "staged restore candidate failed validation"
       operation-id))
    (synchronize-directory! (path-only target) #:who who)
    (prepared-sqlite-restore
     operation-id
     (inexact->exact (floor (current-inexact-milliseconds)))
     backup
     target
     staging-path
     selected-validation
     staged-validation)))

(define (abandon-prepared-pos-sqlite-restore! prepared)
  (unless (prepared-sqlite-restore? prepared)
    (raise-argument-error
     'abandon-prepared-pos-sqlite-restore!
     "prepared-sqlite-restore?"
     prepared))
  (delete-staging-if-owned!
   (prepared-sqlite-restore-staging-path prepared)))

(define (validation->manifest validation)
  (hasheq
   'valid #t
   'migration_status
   (symbol->string (sqlite-backup-validation-migration-status validation))
   'schema_valid (sqlite-backup-validation-schema-valid? validation)))

(define (displaced-file->manifest displaced)
  (hasheq
   'name (displaced-sqlite-file-name displaced)
   'size (displaced-sqlite-file-size displaced)))

(define (write-recovery-manifest! prepared recovery-directory displaced-files)
  (define manifest-path
    (build-path recovery-directory "restore-manifest.json"))
  (call-with-output-file
   manifest-path
   #:exists 'error
   (lambda (output)
     (write-json
      (hasheq
       'manifest_schema_version 1
       'operation_id (prepared-sqlite-restore-operation-id prepared)
       'restore_started_at_epoch_ms
       (prepared-sqlite-restore-started-at-epoch-ms prepared)
       'displaced_files
       (map displaced-file->manifest displaced-files)
       'selected_backup_validation
       (validation->manifest
        (prepared-sqlite-restore-selected-validation prepared))
       'staged_backup_validation
       (validation->manifest
        (prepared-sqlite-restore-staged-validation prepared))
       'current_supported_schema_version
       current-pos-database-schema-version)
      output)
     (newline output)))
  (file-or-directory-permissions manifest-path #o600)
  (synchronize-file! manifest-path #:who 'install-prepared-pos-sqlite-restore!)
  manifest-path)

(define (ensure-recovery-root! target-parent operation-id)
  (define recovery-root (build-path target-parent "recovery"))
  (case (path-kind/no-follow recovery-root)
    [(#f)
     (make-directory recovery-root)
     (file-or-directory-permissions recovery-root #o700)
     (synchronize-directory! target-parent
                             #:who 'install-prepared-pos-sqlite-restore!)]
    [(directory)
     (file-or-directory-permissions recovery-root #o700)]
    [else
     (raise-restore-error
      'displacement_failed
      "recovery evidence root is not a non-symlink directory"
      operation-id)])
  recovery-root)

(define (present-state-files target-path)
  (for/list ([suffix (in-list canonical-state-suffixes)]
             #:do [(define source (canonical-state-path target-path suffix))]
             #:when (eq? (path-kind/no-follow source) 'regular-file))
    (cons source
          (displaced-sqlite-file
           (path->string (file-name-from-path source))
           (file-size source)))))

(define (install-prepared-pos-sqlite-restore! prepared)
  (define who 'install-prepared-pos-sqlite-restore!)
  (unless (prepared-sqlite-restore? prepared)
    (raise-argument-error who "prepared-sqlite-restore?" prepared))
  (define operation-id (prepared-sqlite-restore-operation-id prepared))
  (define target (prepared-sqlite-restore-target-path prepared))
  (define staging (prepared-sqlite-restore-staging-path prepared))
  (unless (eq? (path-kind/no-follow staging) 'regular-file)
    (raise-restore-error
     'install_failed
     "validated restore staging file is unavailable"
     operation-id))
  (check-target-namespace! target operation-id)

  (define target-parent (path-only target))
  (define recovery-directory #f)
  (define displacement-started? #f)
  (with-handlers
      ([exn:fail:pos-restore? raise]
       [exn:fail?
        (lambda (_exception)
          (when (and recovery-directory
                     (not displacement-started?)
                     (eq? (path-kind/no-follow recovery-directory) 'directory))
            (with-handlers ([exn:fail? void])
              (delete-directory/files recovery-directory))
            (set! recovery-directory #f))
          (raise-restore-error
           (if displacement-started? 'install_failed 'displacement_failed)
           "offline restore installation failed"
           operation-id
           #:recovery-directory recovery-directory
           #:displacement-started? displacement-started?))])
    (define recovery-root
      (ensure-recovery-root! target-parent operation-id))
    (set! recovery-directory (build-path recovery-root operation-id))
    (when (path-kind/no-follow recovery-directory)
      (raise-restore-error
       'displacement_failed
       "restore recovery operation directory already exists"
       operation-id))
    (make-directory recovery-directory)
    (file-or-directory-permissions recovery-directory #o700)
    (synchronize-directory! recovery-root #:who who)

    (define state-files (present-state-files target))
    (define displaced-files (map cdr state-files))
    (write-recovery-manifest! prepared recovery-directory displaced-files)
    (synchronize-directory! recovery-directory #:who who)

    (for ([state-file (in-list state-files)])
      (define source (car state-file))
      (define destination
        (build-path recovery-directory (file-name-from-path source)))
      (atomic-rename-file-no-replace! source destination #:who who)
      (set! displacement-started? #t))
    (synchronize-directory! recovery-directory #:who who)
    (synchronize-directory! target-parent #:who who)

    (atomic-rename-file-no-replace! staging target #:who who)
    (set! displacement-started? #t)
    (file-or-directory-permissions target #o640)
    (synchronize-file! target #:who who)
    (synchronize-directory! target-parent #:who who)

    (sqlite-restore-installed
     prepared
     recovery-directory
     displaced-files
     current-pos-database-schema-version)))

(define (restore-pos-sqlite-database-offline!
         backup-path
         target-path
         #:operation-id [operation-id (generate-operation-id)]
         #:validate-backup [validate-backup validate-pos-sqlite-backup]
         #:make-staging-file!
         [make-staging-file! default-make-staging-file!])
  (define prepared #f)
  (with-handlers
      ([exn:fail:pos-restore?
        (lambda (exception)
          (when (and prepared
                     (not (exn:fail:pos-restore-displacement-started?
                           exception)))
            (abandon-prepared-pos-sqlite-restore! prepared))
          (raise exception))]
       [exn:fail?
        (lambda (exception)
          (when prepared
            (abandon-prepared-pos-sqlite-restore! prepared))
          (raise exception))])
    (set! prepared
          (prepare-pos-sqlite-restore!
           backup-path
           target-path
           #:operation-id operation-id
           #:validate-backup validate-backup
           #:make-staging-file! make-staging-file!))
    (install-prepared-pos-sqlite-restore! prepared)))
