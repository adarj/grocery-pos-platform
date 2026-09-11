#lang racket

(require json
         "../pos/support/appliance-recovery.rkt"
         "../pos/support/support-bundle.rkt")

(provide run-support-diagnostics-cli)

(define usage
  (string-append
   "Usage:\n"
   "  support-diagnostics.rkt collect <database-path> <output.tar.gz>\n"
   "  support-diagnostics.rkt collect-appliance <output.tar.gz>\n"))

(define (write-json-line value output)
  (write-json value output)
  (newline output))

(define (write-failure code message output)
  (write-json-line
   (hasheq 'ok #f
           'operation "support_bundle_collect"
           'error (hasheq 'code code 'message message))
   output)
  1)

(define (write-success created output)
  (write-json-line
   (hasheq
    'ok #t
    'operation "support_bundle_collect"
    'support_bundle_schema_version support-bundle-schema-version
    'bundle_id (support-bundle-created-bundle-id created)
    'published_path (path->string (support-bundle-created-path created)))
   output)
  0)

(define (run-support-diagnostics-cli
         arguments
         #:output-port [output-port (current-output-port)]
         #:error-port [error-port (current-error-port)]
         #:collector [collector collect-pos-support-bundle!]
         #:effective-user-id [effective-user-id pos-effective-user-id])
  (unless (vector? arguments)
    (raise-argument-error 'run-support-diagnostics-cli "vector?" arguments))
  (match (vector->list arguments)
    [(list "collect" database-path output-path)
     (with-handlers
         ([exn:fail?
           (lambda (_exception)
             (write-failure
              "support_bundle_failed"
              "Support bundle was not published."
              error-port))])
       (write-success (collector database-path output-path) output-port))]
    [(list "collect-appliance" output-path)
     (cond
       [(not (zero? (effective-user-id)))
        (write-failure
         "not_privileged"
         "Appliance support collection requires root privilege."
         error-port)]
       [else
        (with-handlers
            ([exn:fail?
              (lambda (_exception)
                (write-failure
                 "support_bundle_failed"
                 "Support bundle was not published."
                 error-port))])
          (write-success
           (collector canonical-pos-database-path output-path)
           output-port))])]
    [_
     (display usage error-port)
     2]))

(module+ main
  (exit
   (run-support-diagnostics-cli
    (current-command-line-arguments))))
