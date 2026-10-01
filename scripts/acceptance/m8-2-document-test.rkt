#lang racket

(require rackunit racket/file racket/runtime-path "m8-2-report.rkt")

(define-runtime-path root "../..")

(define (source path)
  (file->string (build-path root path)))

(module+ test
  (test-case "closed requirements, inventory and all E1–E30 dispositions agree"
    (define requirements
      (regexp-match*
       #px"(?m:^\\| (M8[.]2-CP[1-7]-[0-9]{3}) \\|)"
       (source "docs/acceptance/m8.2/requirements.md")
       #:match-select cadr))
    (check-equal? (length requirements) 44)
    (check-equal? (length requirements) (length (remove-duplicates requirements)))
    (check-equal?
     (sort requirements string<?)
     (sort (remove-duplicates (append-map case-spec-requirements cases)) string<?))
    (define matrix (source "docs/acceptance/m8.2/invariant-matrix.md"))
    (define invariants (regexp-match* #px"(?m:^\\| (E[0-9]+) \\|)" matrix #:match-select cadr))
    (check-equal? invariants (for/list ([n (in-range 1 31)]) (format "E~a" n)))
    (for ([id (regexp-match* #px"M8[.]2-CP[0-9]+-[0-9]+" matrix)])
      (check-not-false (member id requirements)))
    (define ids (map case-spec-id cases))
    (check-equal? (length ids) 14)
    (check-equal?
     (regexp-match*
      #px"run_group (M8[.]2-A-[0-9]{3})"
      (source "scripts/acceptance/accept-m8-2.sh")
      #:match-select cadr)
     ids)
    (check-equal?
     (regexp-match*
      #px"(?m:^\\| (M8[.]2-A-[0-9]{3}) \\|)"
      (source "docs/acceptance/m8.2/test-plan.md")
      #:match-select cadr)
     ids)
    (for ([recipe '("accept-m8-2" "acceptance-report-m8-2" "stress-m8-2")])
      (check-true (regexp-match? (pregexp (format "(?m:^~a(?:[ :]))" recipe)) (source "justfile"))))
    (for* ([c cases] [file (case-spec-evidence c)])
      (check-true
       (or (file-exists? (build-path root file)) (directory-exists? (build-path root file)))))))
