#lang racket
(require json (submod json for-extension) racket/date racket/file racket/list racket/string)
(provide (struct-out case-spec) cases generate-report)
;; The local summary supplies execution facts, never inventory/requirements.
(struct case-spec (id title requirements evidence) #:transparent)
(define cases
  (list
    (case-spec "M8.2-A-001" "Locked Rust workspace regression" '("M8.2-CP2-001" "M8.2-CP2-002" "M8.2-CP2-003" "M8.2-CP2-004" "M8.2-CP2-005" "M8.2-CP2-006" "M8.2-CP2-007" "M8.2-CP2-008" "M8.2-CP3-001" "M8.2-CP3-002" "M8.2-CP3-003" "M8.2-CP3-004" "M8.2-CP3-005" "M8.2-CP3-006" "M8.2-CP4-001" "M8.2-CP4-002" "M8.2-CP4-003" "M8.2-CP4-004" "M8.2-CP4-005" "M8.2-CP4-006" "M8.2-CP5-001" "M8.2-CP5-002" "M8.2-CP5-003" "M8.2-CP5-004" "M8.2-CP5-005") '("rust/edge"))
    (case-spec "M8.2-A-002" "Focused Racket Edge protocol/client/session regression" '("M8.2-CP6-001" "M8.2-CP6-002" "M8.2-CP6-003" "M8.2-CP6-004" "M8.2-CP6-005" "M8.2-CP6-006" "M8.2-CP6-007") '("pos-backend-racket/tests/edge-protocol-test.rkt"))
    (case-spec "M8.2-A-003" "Complete repository quality gate" '("M8.2-CP7-002") '("justfile"))
    (case-spec "M8.2-A-004" "Whole-M8.2 static authority/security audit" '("M8.2-CP1-001" "M8.2-CP1-002" "M8.2-CP1-003" "M8.2-CP1-004" "M8.2-CP1-005" "M8.2-CP7-003") '("scripts/acceptance/check-m8-2-static.sh"))
    (case-spec "M8.2-A-005" "Command identity/admission/retention campaign" '("M8.2-CP2-001" "M8.2-CP2-002" "M8.2-CP2-003" "M8.2-CP2-004" "M8.2-CP2-005" "M8.2-CP2-006" "M8.2-CP2-007" "M8.2-CP2-008") '("rust/edge/crates/edge-core/src/actor/tests.rs"))
    (case-spec "M8.2-A-006" "Effect/timeout/panic/resource execution campaign" '("M8.2-CP3-001" "M8.2-CP3-002" "M8.2-CP3-003" "M8.2-CP3-004" "M8.2-CP3-005" "M8.2-CP3-006") '("rust/edge/crates/edge-core/tests/execution.rs"))
    (case-spec "M8.2-A-007" "Binding/rebind/event-continuity campaign" '("M8.2-CP4-001" "M8.2-CP4-002" "M8.2-CP4-003" "M8.2-CP4-004" "M8.2-CP4-005" "M8.2-CP4-006") '("rust/edge/crates/edge-core/tests/execution/lifecycle_events.rs"))
    (case-spec "M8.2-A-008" "Hostile UDS/HTTP/strict-codec campaign" '("M8.2-CP5-001" "M8.2-CP5-002" "M8.2-CP5-003" "M8.2-CP5-004" "M8.2-CP5-005") '("rust/edge/crates/edge-server/tests/transport.rs"))
    (case-spec "M8.2-A-009" "Racket uncertainty/lost-response dedupe campaign" '("M8.2-CP6-001" "M8.2-CP6-002" "M8.2-CP6-003" "M8.2-CP6-004" "M8.2-CP6-005" "M8.2-CP6-006" "M8.2-CP6-007") '("pos-backend-racket/tests/edge-process-test.rkt"))
    (case-spec "M8.2-A-010" "Default capacity and bounded-load campaign" '("M8.2-CP2-003" "M8.2-CP2-004" "M8.2-CP2-005" "M8.2-CP2-006" "M8.2-CP2-007" "M8.2-CP3-004" "M8.2-CP4-001" "M8.2-CP4-004" "M8.2-CP4-006" "M8.2-CP5-002" "M8.2-CP5-004" "M8.2-CP7-004") '("scripts/acceptance/m8-2-process.rkt"))
    (case-spec "M8.2-A-011" "Controlled edge process-death/new-agent campaign" '("M8.2-CP3-005" "M8.2-CP6-006" "M8.2-CP6-007" "M8.2-CP7-005") '("scripts/acceptance/m8-2-process.rkt"))
    (case-spec "M8.2-A-012" "Racket HTTP patch and dependency reproducibility" '("M8.2-CP6-002" "M8.2-CP6-004" "M8.2-CP6-005" "M8.2-CP7-006") '("nix/racket-http-client-bounds.patch"))
    (case-spec "M8.2-A-013" "Source and simulation isolation" '("M8.2-CP1-001" "M8.2-CP1-002" "M8.2-CP1-003" "M8.2-CP1-004" "M8.2-CP1-005" "M8.2-CP7-003" "M8.2-CP7-006") '("scripts/acceptance/check-nix-source-filter.sh"))
    (case-spec "M8.2-A-014" "Acceptance runner/report integrity" '("M8.2-CP7-001" "M8.2-CP7-007") '("scripts/acceptance/m8-2-runner-test.sh"))))
(define (fail) (raise-user-error 'm8-2-report "invalid or incomplete execution evidence"))
(define (text? x) (and (string? x) (positive? (string-length (string-trim x))) (<= (string-length x) 4096)))
(define (utc? x)
  (define parts (and (string? x) (regexp-match #px"^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})Z$" x)))
  (and parts
       (with-handlers ([exn:fail? (lambda (_) #f)])
         (define ns (map string->number (cdr parts)))
         (define d (seconds->date (apply find-seconds (append (reverse (drop ns 3)) (list (third ns) (second ns) (first ns) #f))) #f))
         (equal? ns (list (date-year d) (date-month d) (date-day d) (date-hour d) (date-minute d) (date-second d))))))
(define (read-evidence in)
  ;; Racket's standard parser extension preserves object pairs until duplicate
  ;; decoded keys have been rejected; ordinary read-json silently keeps the last.
  (with-handlers ([exn:fail? (lambda (_) (fail))])
    (read-json* 'm8-2-report in #:null 'null #:replace-malformed-surrogate? #f
                #:make-list values #:make-string values #:make-key string->symbol
                #:make-object
                (lambda (entries)
                  (for/fold ([object (hasheq)]) ([entry entries])
                    (when (hash-has-key? object (car entry)) (fail))
                    (hash-set object (car entry) (cdr entry)))))))
(define (shape h keys)
  (unless (and (hash? h) (equal? (sort (hash-keys h) symbol<?) (sort keys symbol<?))) (fail)))
;; Stable key order independent of Racket hash traversal. No executable input.
(define (write-canonical value out)
  (cond [(hash? value)
         (display "{" out)
         (for ([key (in-list (sort (hash-keys value) symbol<?))] [i (in-naturals)])
           (unless (zero? i) (display "," out))
           (write-json (symbol->string key) out) (display ":" out)
           (write-canonical (hash-ref value key) out))
         (display "}" out)]
        [(list? value)
         (display "[" out)
         (for ([v (in-list value)] [i (in-naturals)])
           (unless (zero? i) (display "," out)) (write-canonical v out))
         (display "]" out)]
        [else (write-json value out)]))
(define (generate-report summary-path output-path)
  (define summary (call-with-input-file summary-path
                    (lambda (in) (define v (read-evidence in))
                      (unless (eof-object? (read-evidence in)) (fail)) v)))
  (shape summary '(reference_commit tested_worktree_state generated_at environment groups evidence_kind))
  (unless (and (regexp-match? #px"^[0-9a-f]{40}$" (hash-ref summary 'reference_commit))
               (equal? (hash-ref summary 'tested_worktree_state) "clean")
               (member (hash-ref summary 'evidence_kind) '("authoritative" "self_test"))
               (utc? (hash-ref summary 'generated_at)) (text? (hash-ref summary 'environment))
               (list? (hash-ref summary 'groups))) (fail))
  (when (and (equal? (path->string (file-name-from-path output-path)) "acceptance-results.json")
             (not (equal? (hash-ref summary 'evidence_kind) "authoritative")))
    (fail)) ; synthetic summaries may never publish the final evidence filename
  (define indexed
    (for/fold ([index (hash)]) ([entry (in-list (hash-ref summary 'groups))])
      (shape entry '(id status timestamp environment evidence_log command exit_code blocking_issue))
      (define id (hash-ref entry 'id))
      (unless (and (member id (map case-spec-id cases)) (not (hash-has-key? index id))
                   (member (hash-ref entry 'status) '("passed" "failed" "blocked" "not_run"))
                   (utc? (hash-ref entry 'timestamp)) (text? (hash-ref entry 'environment))
                   (text? (hash-ref entry 'command))
                   (equal? (hash-ref entry 'evidence_log) (format ".local/acceptance/m8-2/~a.log" id))
                   (exact-nonnegative-integer? (hash-ref entry 'exit_code))
                   (<= (hash-ref entry 'exit_code) 255)
                   ;; Exit 77 is the runner's sole blocked-capability signal.
                   ;; An assertion failure cannot be relabeled conditional.
                   (cond [(equal? (hash-ref entry 'status) "blocked")
                          (= (hash-ref entry 'exit_code) 77)]
                         [(equal? (hash-ref entry 'status) "failed")
                          (not (= (hash-ref entry 'exit_code) 77))]
                         [else #t])
                   (string? (hash-ref entry 'blocking_issue))
                   (if (equal? (hash-ref entry 'status) "passed")
                       (and (zero? (hash-ref entry 'exit_code)) (equal? (hash-ref entry 'blocking_issue) ""))
                       (and (positive? (hash-ref entry 'exit_code)) (text? (hash-ref entry 'blocking_issue))))) (fail))
      (hash-set index id entry)))
  (unless (= (hash-count indexed) (length cases)) (fail))
  (define groups
    (for/list ([c (in-list cases)])
      (define e (hash-ref indexed (case-spec-id c)))
      (hasheq 'id (case-spec-id c) 'title (case-spec-title c) 'tier "A"
              'requirements (case-spec-requirements c) 'status (hash-ref e 'status)
              'execution_timestamp (hash-ref e 'timestamp) 'environment_description (hash-ref e 'environment)
              'command (hash-ref e 'command) 'exit_code (hash-ref e 'exit_code)
              'evidence_references (append (case-spec-evidence c) (list (hash-ref e 'evidence_log)))
              'notes "Repository evidence only; source references identify harnesses, not execution. Canonical gates intentionally repeat focused suites."
              'blocking_issue (if (equal? (hash-ref e 'status) "passed") 'null (hash-ref e 'blocking_issue)))))
  (define statuses (map (lambda (g) (hash-ref g 'status)) groups))
  (define document
    (hasheq 'schema_version 1 'milestone 8 'submilestone "M8.2 Generic Edge Foundation — Tier A"
            'authoritative (equal? (hash-ref summary 'evidence_kind) "authoritative")
            'generated_at (hash-ref summary 'generated_at) 'reference_commit (hash-ref summary 'reference_commit)
            'tested_worktree_state "clean" 'repository_tier_a_environment (hash-ref summary 'environment)
            'overall_status (cond [(member "failed" statuses) "failing"]
                                  [(andmap (lambda (s) (equal? s "passed")) statuses) "passing"]
                                  [else "conditional"])
            'test_groups groups))
  (make-parent-directory* output-path)
  (define temp (make-temporary-file "m8-2-report-~a" #f (path-only (path->complete-path output-path))))
  (dynamic-wind void
    (lambda ()
      (call-with-output-file temp (lambda (out) (write-canonical document out) (newline out)) #:exists 'truncate)
      (rename-file-or-directory temp output-path #t))
    (lambda () (when (file-exists? temp) (delete-file temp))))
  document)
(module+ main
  (define args (vector->list (current-command-line-arguments)))
  (unless (= (length args) 2) (fail))
  (void (generate-report (first args) (second args))))
(module+ test
  (require rackunit)
  (define scratch (make-temporary-file "m8-2-report-test-~a" 'directory))
  (dynamic-wind void
    (lambda ()
      (define summary (hasheq 'reference_commit (make-string 40 #\0) 'tested_worktree_state "clean"
                              'generated_at "2026-09-30T00:00:00Z" 'environment "synthetic reporter self-test"
                              'evidence_kind "self_test"
                              'groups (for/list ([c (in-list cases)])
                                        (hasheq 'id (case-spec-id c) 'status "passed" 'timestamp "2026-09-30T00:00:00Z"
                                                'environment "synthetic self-test" 'command "mock" 'exit_code 0 'blocking_issue ""
                                                'evidence_log (format ".local/acceptance/m8-2/~a.log" (case-spec-id c))))))
      (define in (build-path scratch "summary.json")) (define out (build-path scratch "report.json"))
      (define (run s) (call-with-output-file in (lambda (p) (write-json s p)) #:exists 'truncate)
                      (generate-report in out))
      (define pass (run summary))
      (check-equal? (hash-ref pass 'overall_status) "passing")
      (check-false (hash-ref pass 'authoritative))
      (define bytes (file->bytes out)) (run summary) (check-equal? bytes (file->bytes out))
      (for ([status '("failed" "blocked" "not_run")] [expected '("failing" "conditional" "conditional")])
        (define entries (hash-ref summary 'groups))
        (define bad (hash-set* (car entries) 'status status
                               'exit_code (if (equal? status "blocked") 77 1)
                               'blocking_issue "synthetic failure"))
        (check-equal? (hash-ref (run (hash-set summary 'groups (cons bad (cdr entries)))) 'overall_status) expected))
      (define entries (hash-ref summary 'groups))
      (check-exn exn:fail?
        (lambda ()
          (run (hash-set summary 'groups
                         (cons (hash-set* (car entries) 'status "blocked" 'exit_code 1
                                          'blocking_issue "ordinary assertion failure")
                               (cdr entries))))))
      (check-exn exn:fail?
        (lambda ()
          (run (hash-set summary 'groups
                         (cons (hash-set* (car entries) 'status "failed" 'exit_code 77
                                          'blocking_issue "unavailable capability")
                               (cdr entries))))))
      (define previous-report (file->bytes out))
      (for ([invalid (in-list (list (cdr entries) (cons (hash-set (car entries) 'id "unknown") (cdr entries))
                                    (cons (car entries) entries)
                                    (cons (hash-set (car entries) 'status "skipped") (cdr entries))
                                    (cons (hash-remove (car entries) 'command) (cdr entries))
                                    (cons (hash-set (car entries) 'requirements '("invented")) (cdr entries))
                                    (cons (hash-set (car entries) 'exit_code 1) (cdr entries))))])
        (check-exn exn:fail? (lambda () (run (hash-set summary 'groups invalid))))
        (check-equal? (file->bytes out) previous-report))
      (check-exn exn:fail? (lambda () (run (hash-set summary 'tested_worktree_state "dirty"))))
      (for ([id '("M8.2-A-005 " "m8.2-A-005" "M8.2-A-005-extra" "identity" "capacity2")])
        (check-exn exn:fail? (lambda () (run (hash-set summary 'groups (cons (hash-set (car entries) 'id id) (cdr entries)))))))
      (for ([key '(title tier notes)])
        (check-exn exn:fail? (lambda () (run (hash-set summary 'groups (cons (hash-set (car entries) key "injected") (cdr entries)))))))
      (for ([path '("/etc/passwd" "../../secret" ".local/acceptance/m8-2/M8.2-A-999.log")])
        (check-exn exn:fail? (lambda () (run (hash-set summary 'groups (cons (hash-set (car entries) 'evidence_log path) (cdr entries)))))))
      (for ([timestamp '("2026-13-30T00:00:00Z" "2026-02-30T00:00:00Z" "2026-09-30T25:00:00Z")])
        (check-exn exn:fail? (lambda () (run (hash-set summary 'generated_at timestamp)))))
      (run summary)
      (define invalid-utf8 (regexp-replace #rx#"synthetic reporter self-test" (file->bytes in) #"invalid-\377"))
      (call-with-output-file in (lambda (p) (write-bytes invalid-utf8 p)) #:exists 'truncate)
      (check-exn exn:fail? (lambda () (generate-report in out)))
      (run summary)
      (define escaped-duplicate (regexp-replace #rx#"\"status\":\"passed\"" (file->bytes in)
                                                #"\"status\":\"failed\",\"\\u0073tatus\":\"passed\""))
      (call-with-output-file in (lambda (p) (write-bytes escaped-duplicate p)) #:exists 'truncate)
      (check-exn exn:fail? (lambda () (generate-report in out)))
      (run summary)
      (define duplicate-status (regexp-replace #rx#"\"status\":\"passed\"" (file->bytes in)
                                               #"\"status\":\"failed\",\"status\":\"passed\""))
      (call-with-output-file in (lambda (p) (write-bytes duplicate-status p)) #:exists 'truncate)
      (check-exn exn:fail? (lambda () (generate-report in out)))
      (run summary)
      (check-exn exn:fail? (lambda () (generate-report in (build-path scratch "acceptance-results.json"))))
      (check-exn exn:fail? (lambda () (generate-report in scratch))))
    (lambda () (delete-directory/files scratch))))
