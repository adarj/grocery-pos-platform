#lang racket
(require racket/file racket/port)
;; Nix path ingestion runs before deployableSourceFilter and cannot ingest live
;; Unix sockets. Copy Git's tracked + nonignored new source (including unstaged
;; edits) without staging, then test the actual Nix filter on regular markers.
(define args (vector->list (current-command-line-arguments)))
(unless (= (length args) 2) (raise-user-error 'source-snapshot "expected ROOT OUTPUT"))
(define root (string->path (first args))) (define output (string->path (second args)))
(define-values (proc out in err)
  (subprocess #f #f #f (find-executable-path "git") "-C" root "ls-files" "--cached" "--others" "--exclude-standard" "-z"))
(close-output-port in)
(define paths (string-split (port->string out) "\u0000"))
(subprocess-wait proc)
(unless (zero? (subprocess-status proc)) (raise-user-error 'source-snapshot "Git source inventory failed"))
(close-input-port out) (close-input-port err)
(for ([relative (remove-duplicates paths)])
  (define from (build-path root relative)) (define to (build-path output relative))
  (cond [(link-exists? from)
         (raise-user-error 'source-snapshot "source symlink needs explicit classification")]
        [(file-exists? from)
         (make-parent-directory* to)
         (copy-file from to)]
        [(directory-exists? from) (raise-user-error 'source-snapshot "submodule source needs explicit classification")]
        [else (void)])) ; deleted tracked paths are absent in current source
