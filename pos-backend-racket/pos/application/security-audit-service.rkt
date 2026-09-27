#lang racket

(require "../domain/security-audit-event.rkt"
         "../persistence/security-audit-store.rkt")

(provide make-security-audit-source
         security-audit-source?
         security-audit-append-required!
         security-audit-append-required!/in-transaction!
         security-audit-append-best-effort!)

(struct security-audit-source (kind instance-id current-epoch-ms))

(define (make-security-audit-source kind instance-id current-epoch-ms)
  (unless (memq kind '(pos_core root_cli))
    (raise-argument-error 'make-security-audit-source
                          "(or/c 'pos_core 'root_cli)" kind))
  (unless (and (string? instance-id) (positive? (string-length instance-id)))
    (raise-argument-error 'make-security-audit-source "non-empty string?"
                          instance-id))
  (unless (and (procedure? current-epoch-ms)
               (procedure-arity-includes? current-epoch-ms 0))
    (raise-argument-error 'make-security-audit-source
                          "zero-argument procedure?" current-epoch-ms))
  (security-audit-source kind instance-id current-epoch-ms))

(define (security-audit-append-required!/in-transaction!
         source connection event)
  (append-security-audit-event!/in-transaction!
   connection event
   #:source-kind (security-audit-source-kind source)
   #:source-instance-id (security-audit-source-instance-id source)
   #:occurred-at-epoch-ms ((security-audit-source-current-epoch-ms source))))

(define (security-audit-append-required! source connection event)
  (append-security-audit-event!
   connection event
   #:source-kind (security-audit-source-kind source)
   #:source-instance-id (security-audit-source-instance-id source)
   #:occurred-at-epoch-ms ((security-audit-source-current-epoch-ms source))))

(define (security-audit-append-best-effort! source connection event)
  (with-handlers ([exn:fail?
                   (lambda (_exception)
                     (eprintf "security audit append failed\n")
                     #f)])
    (security-audit-append-required! source connection event)
    #t))
