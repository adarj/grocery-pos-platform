#lang racket

(require json racket/file racket/list racket/string)

;; This inventory is deliberately closed. A new command/result cannot silently
;; become qualification evidence by appearing in a local summary file.
(struct acceptance-case (id title tier requirements group evidence note) #:transparent)

(define (ids checkpoint count)
  (for/list ([number (in-range 1 (add1 count))])
    (format "M7-CP~a-~a" checkpoint (~r number #:min-width 3 #:pad-string "0"))))

(define cases
  (append
   (list
    (acceptance-case "M7-A-001" "Racket security and persistence regressions" "A"
                     (append (ids 1 4) (ids 2 3) (ids 3 5) (ids 4 5) (ids 5 7) (ids 6 7))
                     "racket" '("pos-backend-racket/tests")
                     "Existing focused tests include migration, provenance, session, approval, audit, lifecycle, and backup boundaries.")
    (acceptance-case "M7-A-002" "Flutter recovery and credential UI regressions" "A"
                     '("M7-CP2-004" "M7-CP3-001" "M7-CP4-001" "M7-CP6-003")
                     "flutter" '("flutter/apps/pos_terminal/test")
                     "Presentation tests do not constitute server authorization evidence.")
    (acceptance-case "M7-A-003" "Real Flutter/Core/SQLite integration" "A"
                     '("M7-CP2-001" "M7-CP3-002" "M7-CP4-002" "M7-CP6-001" "M7-CP7-002")
                     "integration" '("flutter/apps/pos_terminal/integration/real_pos_core_test.dart")
                     "Real-process integration; not booted appliance evidence.")
    (acceptance-case "M7-A-004" "Complete local quality gate" "A" '("M7-CP7-001")
                     "check" '("justfile") "Includes analysis and repeats component tests by project convention.")
    (acceptance-case "M7-A-005" "POS Core packaged contract" "A" '("M7-CP7-004")
                     "core-package" '("packaging/tests/check-pos-core-package.sh") "Installed RPM contract, not a production boot.")
    (acceptance-case "M7-A-006" "Appliance packaged contract" "A" '("M7-CP7-004")
                     "appliance-package" '("packaging/tests/check-pos-appliance-package.sh") "Rootless package contract.")
    (acceptance-case "M7-A-007" "POS Core RPM derivation" "A" '("M7-CP7-004")
                     "core-rpm" '("packaging/fedora/grocery-pos-core.spec") "Nix builds uncommitted source via path:.")
    (acceptance-case "M7-A-008" "Appliance RPM derivation" "A" '("M7-CP7-004")
                     "appliance-rpm" '("packaging/fedora/grocery-pos-appliance.spec") "Nix builds uncommitted source via path:.")
    (acceptance-case "M7-A-009" "Native flake checks" "A" '("M7-CP7-004")
                     "flake" '("flake.nix") "Host-compatible outputs only.")
    (acceptance-case "M7-A-010" "Whole-M7 static security boundary" "A" '("M7-CP7-009")
                     "static" '("scripts/acceptance/check-m7-static.sh") "A source-boundary screen, not proof of runtime behavior.")
    (acceptance-case "M7-A-011" "Bounded 10000-event security ledger stress" "A" '("M7-CP7-003")
                     "stress" '("scripts/acceptance/m7-security-stress.rkt") "Metrics are host-specific, not universal performance guarantees.")
    (acceptance-case "M7-A-012" "Nix deployable source isolation" "A" '("M7-CP7-004")
                     "source-isolation" '("scripts/acceptance/check-nix-source-filter.sh") "Ignored local evidence must not enter artifacts.")
    (acceptance-case "M7-A-013" "Controlled process-death recovery" "A" '("M7-CP7-002")
                     "crash" '("flutter/apps/pos_terminal/integration/real_pos_core_test.dart") "SIGKILL is process-crash evidence, not power-loss evidence.")
    (acceptance-case "M7-A-014" "Isolated disk-full failure" "A" '("M7-CP5-003" "M7-CP7-002")
                     "enospc" '("scripts/acceptance/m6-enospc.sh" "scripts/acceptance/m7-enospc.sh") "Bounded private tmpfs checks include required credential/audit rollback and best-effort login denial.")
    (acceptance-case "M7-A-015" "x86_64 terminal and appliance derivations" "A" '("M7-CP7-005")
                     "x86-artifacts" '("flake.nix") "Cross/emulated artifact success is not booted Tier B evidence."))
   (for/list ([title (in-list
                      '("Booted Kinoite platform observation and provisioning baseline"
                        "Credential bootstrap, authorization, approval, and lifecycle"
                        "Offline checkout, restart, support, backup, and older-backup restore"
                        "Ten normal reboot security cycles"
                        "rpm-ostree upgrade/rollback versus forward-only database schema"))]
              [index (in-naturals 1)])
     (acceptance-case (format "M7-B-~a" (~r index #:min-width 3 #:pad-string "0"))
                      title "B" '("M7-CP7-006") #f
                      '("docs/acceptance/m7/appliance-qualification.md")
                      "Requires actual execution on a disposable booted Fedora Kinoite 44 x86_64 appliance."))
   (for/list ([title (in-list
                      '("Locked startup and masked touchscreen PIN"
                        "Inactivity lock, Alice-to-Bob isolation, and approval ceremony"
                        "PIN-change lock and active-sale recovery"
                        "Display, touch, reconnect, technician VT, and kiosk OS boundary"))]
              [index (in-naturals 1)])
     (acceptance-case (format "M7-C-~a" (~r index #:min-width 3 #:pad-string "0"))
                      title "C" '("M7-CP7-007") #f
                      '("docs/acceptance/m7/reference-hardware.md")
                      "Requires selected physical register hardware."))
   (list
    (acceptance-case "M7-D-001" "Twenty-five-cycle abrupt physical interruption campaign" "D"
                     '("M7-CP7-008") #f
                     '("docs/acceptance/m7/power-interruption-security.md")
                     "Requires controlled interruption of a disposable physical appliance."))))

(define allowed-statuses '("passed" "failed" "blocked" "not_run"))

(define (read-summary path)
  (call-with-input-file path read-json))

(define (index-results entries allowed-ids label)
  (for/fold ([indexed (hash)]) ([entry (in-list entries)])
    (define id (hash-ref entry 'id #f))
    (unless (and (string? id) (member id allowed-ids))
      (raise-user-error 'm7-report "unknown ~a id: ~a" label id))
    (when (hash-has-key? indexed id)
      (raise-user-error 'm7-report "duplicate ~a id: ~a" label id))
    (unless (member (hash-ref entry 'status #f) allowed-statuses)
      (raise-user-error 'm7-report "invalid status for ~a" id))
    (when (and (string=? label "external case")
               (string=? (hash-ref entry 'status) "passed"))
      (for ([field '(timestamp environment evidence_log command)])
        (unless (and (string? (hash-ref entry field #f))
                     (non-empty-string? (string-trim (hash-ref entry field))))
          (raise-user-error 'm7-report
                            "external pass for ~a lacks ~a evidence" id field))))
    (hash-set indexed id entry)))

(define (case->json item sources external)
  (define source
    (if (acceptance-case-group item)
        (hash-ref sources (acceptance-case-group item) #f)
        (hash-ref external (acceptance-case-id item) #f)))
  (define status (if source (hash-ref source 'status) "not_run"))
  (hasheq
   'id (acceptance-case-id item)
   'title (acceptance-case-title item)
   'tier (acceptance-case-tier item)
   'requirements (acceptance-case-requirements item)
   'status status
   'execution_timestamp (if source (hash-ref source 'timestamp 'null) 'null)
   'environment_description (if source (hash-ref source 'environment "") "Not supplied")
   'command (if source (hash-ref source 'command 'null) 'null)
   'evidence_references
   (append (acceptance-case-evidence item)
           (if (and source (hash-ref source 'evidence_log #f))
               (list (hash-ref source 'evidence_log)) '()))
   'notes (acceptance-case-note item)
   'blocking_issue (if (string=? status "passed") 'null
                       (if source (hash-ref source 'blocking_issue "Evidence did not pass")
                           "Mandatory evidence has not been executed"))))

(define (overall-status results)
  (cond
    [(ormap (lambda (item) (string=? (hash-ref item 'status) "failed")) results) "failing"]
    [(andmap (lambda (item) (string=? (hash-ref item 'status) "passed")) results) "passing"]
    [else "conditional"]))

(define (generate-report summary-path output-path)
  (define summary (read-summary summary-path))
  (define groups (filter-map acceptance-case-group cases))
  (define external-ids
    (for/list ([item (in-list cases)] #:unless (acceptance-case-group item))
      (acceptance-case-id item)))
  (define sources (index-results (hash-ref summary 'groups '()) groups "group"))
  (define external
    (index-results (hash-ref summary 'external_cases '()) external-ids "external case"))
  (define results (for/list ([item (in-list cases)]) (case->json item sources external)))
  (define document
    (hasheq
     'schema_version 1
     'milestone 7
     'generated_at (hash-ref summary 'generated_at)
     'reference_commit (hash-ref summary 'reference_commit)
     'tested_worktree_state (hash-ref summary 'tested_worktree_state)
     'repository_tier_a_environment (hash-ref summary 'environment)
     'overall_status (overall-status results)
     'test_groups results))
  (make-parent-directory* output-path)
  (call-with-output-file output-path
    (lambda (output) (write-json document output #:indent 2) (newline output))
    #:exists 'truncate/replace))

(module+ main
  (define arguments (vector->list (current-command-line-arguments)))
  (unless (= (length arguments) 2)
    (raise-user-error 'm7-report "expected SUMMARY.json OUTPUT.json"))
  (generate-report (first arguments) (second arguments)))
