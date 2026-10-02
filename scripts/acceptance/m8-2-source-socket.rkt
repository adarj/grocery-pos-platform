#lang racket

(require racket/file racket/unix-socket racket/system)

(define source-root (current-directory))

(make-directory* (build-path source-root ".local"))

(define marker
  (make-temporary-file "source-socket-~a" 'directory (build-path source-root ".local")))

(define socket (build-path marker "probe.sock"))

(define listener #f)

(dynamic-wind
 void
 (lambda ()
   (set! listener (unix-socket-listen socket))
   (unless (system*
            (find-executable-path "racket")
            "scripts/acceptance/nix-source-snapshot.rkt"
            (path->string source-root)
            (vector-ref (current-command-line-arguments) 0))
     (raise-user-error 'source-isolation "source materialization failed"))
   (define relative (find-relative-path source-root socket))
   (when (or
          (file-exists? (build-path (vector-ref (current-command-line-arguments) 0) relative))
          (link-exists? (build-path (vector-ref (current-command-line-arguments) 0) relative)))
     (raise-user-error 'source-isolation "ignored socket entered source")))
 (lambda ()
   (when listener
     (unix-socket-close-listener listener))
   (delete-directory/files marker)))
