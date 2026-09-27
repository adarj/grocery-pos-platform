#lang racket

(require json
         "../pos/persistence/sqlite-restore.rkt"
         "../pos/support/appliance-recovery.rkt")

(provide run-database-recovery-cli)

(define usage
  (string-append
   "Usage:\n"
   "  database-recovery.rkt restore-offline <backup-path> <database-path>\n"
   "  database-recovery.rkt restore <backup-path>\n"))

(define (write-json-line value output)
  (write-json value output)
  (newline output))

(define (safe-failure code message output
                      #:operation-id [operation-id #f]
                      #:recovery-directory [recovery-directory #f])
  (write-json-line
   (hasheq
    'ok #f
    'operation "restore"
    'error
    (hasheq 'code (symbol->string code)
            'message message)
    'operation_id (if operation-id operation-id (json-null))
    'recovery_evidence_directory
    (if recovery-directory
        (path->string recovery-directory)
        (json-null)))
   output)
  1)

(define (offline-success->json restored)
  (define prepared (sqlite-restore-installed-prepared restored))
  (hasheq
   'ok #t
   'operation "restore_offline"
   'operation_id (prepared-sqlite-restore-operation-id prepared)
   'restored_schema_version
   (sqlite-restore-installed-restored-schema-version restored)
   'recovery_evidence_directory
   (path->string (sqlite-restore-installed-recovery-directory restored))
   'caller_confirmed_offline #t))

(define (appliance-success->json restored)
  (hasheq
   'ok #t
   'operation "restore"
   'operation_id (appliance-restore-success-operation-id restored)
   'restored_schema_version
   (appliance-restore-success-restored-schema-version restored)
   'security_state_restored_from_backup #t
   'reauthentication_required #t
   'recovery_evidence_directory
   (path->string (appliance-restore-success-recovery-directory restored))
   'service_status
   (symbol->string (appliance-restore-success-service-status restored))
   'readiness_status
   (symbol->string (appliance-restore-success-readiness-status restored))))

(define (run-database-recovery-cli
         arguments
         #:output-port [output-port (current-output-port)]
         #:error-port [error-port (current-error-port)]
         #:offline-restore
         [offline-restore restore-pos-sqlite-database-offline!]
         #:appliance-restore
         [appliance-restore restore-pos-appliance!])
  (unless (vector? arguments)
    (raise-argument-error 'run-database-recovery-cli "vector?" arguments))
  (match (vector->list arguments)
    [(list "restore-offline" backup-path database-path)
     (with-handlers
         ([exn:fail:pos-restore?
           (lambda (exception)
             (safe-failure
              (exn:fail:pos-restore-code exception)
              "Offline restore failed; inspect preserved state before retrying."
              error-port
              #:operation-id
              (exn:fail:pos-restore-operation-id exception)
              #:recovery-directory
              (exn:fail:pos-restore-recovery-directory exception)))]
          [exn:fail?
           (lambda (_exception)
             (safe-failure
              'restore_failed
              "Offline restore failed."
              error-port))])
       (define restored (offline-restore backup-path database-path))
       (write-json-line (offline-success->json restored) output-port)
       0)]
    [(list "restore" backup-path)
     (with-handlers
         ([exn:fail:appliance-recovery?
           (lambda (exception)
             (safe-failure
              (exn:fail:appliance-recovery-code exception)
              (exn-message exception)
              error-port
              #:operation-id
              (exn:fail:appliance-recovery-operation-id exception)
              #:recovery-directory
              (exn:fail:appliance-recovery-recovery-directory exception)))]
          [exn:fail?
           (lambda (_exception)
             (safe-failure
              'restore_failed
              "Appliance restore failed."
              error-port))])
       (define restored (appliance-restore backup-path))
       (write-json-line (appliance-success->json restored) output-port)
       0)]
    [_
     (display usage error-port)
     2]))

(module+ main
  (exit
   (run-database-recovery-cli
    (current-command-line-arguments))))
