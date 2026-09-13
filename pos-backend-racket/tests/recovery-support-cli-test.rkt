#lang racket

(require json
         rackunit
         "../scripts/database-recovery.rkt"
         "../scripts/support-diagnostics.rkt")

(define secret-sentinel "CLI_MUST_NOT_SERIALIZE_THIS_EXCEPTION")

(define (output-json output)
  (read-json (open-input-string (get-output-string output))))

(module+ test
  (test-case "appliance support command requires root before collection"
    (define output (open-output-string))
    (define error-output (open-output-string))
    (define collected? #f)
    (check-equal?
     (run-support-diagnostics-cli
      #("collect-appliance" "/tmp/support.tar.gz")
      #:output-port output
      #:error-port error-output
      #:effective-user-id (lambda () 1000)
      #:collector
      (lambda (_database _output)
        (set! collected? #t)
        (error 'test "must not collect")))
     1)
    (check-false collected?)
    (define response (output-json error-output))
    (check-equal? (hash-ref (hash-ref response 'error) 'code)
                  "not_privileged"))

  (test-case "recovery CLI never serializes arbitrary exception details"
    (define output (open-output-string))
    (define error-output (open-output-string))
    (check-equal?
     (run-database-recovery-cli
      #("restore" "/selected.db")
      #:output-port output
      #:error-port error-output
      #:appliance-restore
      (lambda (_backup) (error 'test secret-sentinel)))
     1)
    (define serialized (get-output-string error-output))
    (check-false (regexp-match? (regexp secret-sentinel) serialized))
    (define response (read-json (open-input-string serialized)))
    (check-equal? (hash-ref (hash-ref response 'error) 'code)
                  "restore_failed")))
