#lang racket

(require "../../scripts/operator-auth.rkt")

;; Test-only isolated path injection. The production wrapper remains root-only,
;; canonical-path-only, and interactive-TTY-only.
(module+ main
  (match (vector->list (current-command-line-arguments))
    [(list database-path operator-id)
     (exit
      (run-operator-auth-cli
       (vector "operator" "reset-pin" operator-id)
       #:database-path database-path
       #:effective-user-id (lambda () 0)))]
    [_ (exit 2)]))
