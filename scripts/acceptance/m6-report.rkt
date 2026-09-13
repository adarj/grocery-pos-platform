#lang racket

(require json
         racket/file
         racket/format
         racket/list
         racket/match)

(struct acceptance-case
  (id title tier requirements source-group evidence notes blocking-issue)
  #:transparent)

(define tier-a-cases
  (list
   (acceptance-case
    "M6-A-001" "Complete Racket suite" "A"
    '("M6-CP1-001" "M6-CP2-001" "M6-CP5-001")
    "racket" '("pos-backend-racket/tests")
    "Includes focused migration, connection, backup, restore, support, concurrency, and cash-accountability tests." #f)
   (acceptance-case
    "M6-A-002" "Complete Flutter suite" "A"
    '("M6-CP6-002" "M6-CP7-002")
    "flutter" '("flutter/apps/pos_terminal/test")
    "Protects endpoint validation and durable cashier recovery state." #f)
   (acceptance-case
    "M6-A-003" "Real Flutter-to-Racket integration" "A"
    '("M6-CP3-001" "M6-CP7-001")
    "integration" '("flutter/apps/pos_terminal/integration/real_pos_core_test.dart")
    "Uses a real Racket process and file-backed SQLite." #f)
   (acceptance-case
    "M6-A-004" "POS Core RPM contract" "A"
    '("M6-CP4-001" "M6-CP4-002")
    "nix-native" '("packaging/tests/check-pos-core-package.sh")
    "Builds, extracts, inspects, and lifecycle-tests the noarch RPM." #f)
   (acceptance-case
    "M6-A-005" "Appliance RPM contract" "A"
    '("M6-CP6-001" "M6-CP6-003")
    "nix-native" '("packaging/tests/check-pos-appliance-package.sh")
    "Checks declarative payload and absence of install-time mutation." #f)
   (acceptance-case
    "M6-A-006" "Terminal Flatpak contract" "A"
    '("M6-CP6-002" "M6-CP6-003")
    "nix-x86" '("packaging/tests/check-terminal-flatpak.sh")
    "Inspects the built x86_64 Flatpak metadata and payload." #f)
   (acceptance-case
    "M6-A-007" "Appliance bundle contract" "A"
    '("M6-CP6-004")
    "nix-x86" '("packaging/tests/check-appliance-bundle.sh")
    "Includes a bundle-tampering rejection test." #f)
   (acceptance-case
    "M6-A-008" "Kinoite bootstrap pure-state tests" "A"
    '("M6-CP6-004")
    "nix-native" '("packaging/tests/bootstrap-kinoite-test.sh")
    "Does not mutate the host rpm-ostree deployment." #f)
   (acceptance-case
    "M6-A-009" "Provisioning pure-state tests" "A"
    '("M6-CP6-005")
    "racket" '("pos-backend-racket/tests/appliance-provisioning-test.rkt")
    "Uses injected operating-system boundaries and real staged SQLite state." #f)
   (acceptance-case
    "M6-A-010" "Transaction process-crash recovery" "A"
    '("M6-CP7-001" "M6-CP1-003")
    "integration" '("flutter/apps/pos_terminal/integration/real_pos_core_test.dart")
    "Three accepted scan/completion boundaries use SIGKILL and exact-ID recovery by default; this is process-death evidence, not power-loss evidence." #f)
   (acceptance-case
    "M6-A-011" "Durable same-ID command idempotency" "A"
    '("M6-CP1-003")
    "racket" '("pos-backend-racket/tests/persistent-transaction-service-restart-test.rkt")
    "Covers same normalized command and incompatible command-ID reuse across restart." #f)
   (acceptance-case
    "M6-A-012" "Optimistic concurrency and command races" "A"
    '("M6-CP1-004")
    "racket" '("pos-backend-racket/tests/persistent-transaction-service-concurrency-test.rkt")
    "Preserves BEGIN IMMEDIATE arbitration without a global mutex." #f)
   (acceptance-case
    "M6-A-013" "Cash-accountability restart invariants" "A"
    '("M6-CP1-005" "M6-CP7-003")
    "soak" '("scripts/acceptance/m6-soak.rkt")
    "Checks expected cash, movement cardinality, durable retries, and immutable reconciliation across connection reconstruction." #f)
   (acceptance-case
    "M6-A-014" "Validated backups under concurrent write load" "A"
    '("M6-CP2-001" "M6-CP7-004")
    "racket" '("pos-backend-racket/tests/m6-reliability-acceptance-test.rkt")
    "Publishes and independently validates multiple snapshots during valid WAL writes." #f)
   (acceptance-case
    "M6-A-015" "Backup interruption and publication safety" "A"
    '("M6-CP2-001" "M6-CP2-002")
    "racket" '("pos-backend-racket/tests/sqlite-maintenance-test.rkt")
    "Deterministic failure seams prove invalid candidates never acquire the final name." #f)
   (acceptance-case
    "M6-A-016" "Backup-to-restore financial round trip" "A"
    '("M6-CP5-001" "M6-CP5-002" "M6-CP7-005")
    "racket" '("pos-backend-racket/tests/m6-reliability-acceptance-test.rkt")
    "Proves an explicitly older recovery point contains sale A, omits later sale B, and preserves displaced A+B state." #f)
   (acceptance-case
    "M6-A-017" "Support-bundle privacy sentinel" "A"
    '("M6-CP5-003")
    "racket" '("pos-backend-racket/tests/support-bundle-test.rkt")
    "Searches archive members for authoritative and secret-looking sentinel data." #f)
   (acceptance-case
    "M6-A-018" "Oversized HTTP body rejection and recovery" "A"
    '("M6-CP3-002")
    "integration" '("flutter/apps/pos_terminal/integration/real_pos_core_test.dart")
    "Uses the real request-reader boundary and verifies a subsequent valid request." #f)
   (acceptance-case
    "M6-A-019" "Missing-database liveness/readiness distinction" "A"
    '("M6-CP3-003")
    "integration" '("flutter/apps/pos_terminal/integration/real_pos_core_test.dart")
    "The process stays live while readiness fails closed after the authoritative path disappears." #f)
   (acceptance-case
    "M6-A-020" "Process-level offline and no-cloud operation" "A"
    '("M6-CP3-004" "M6-CP7-006")
    "integration" '("flutter/apps/pos_terminal/integration/real_pos_core_test.dart")
    "Real local cash-sale integration has no cloud service fixture or dependency." #f)
   (acceptance-case
    "M6-A-021" "Isolated disk-full failure behavior" "A"
    '("M6-CP7-007")
    "enospc" '("scripts/acceptance/m6-enospc.sh")
    "Uses a bounded private tmpfs in an unprivileged mount namespace; never fills the developer filesystem." #f)
   (acceptance-case
    "M6-A-022" "Sensitive diagnostics regression" "A"
    '("M6-CP5-003" "M6-CP7-008")
    "racket" '("pos-backend-racket/tests/support-bundle-test.rkt" "pos-backend-racket/tests/recovery-support-cli-test.rkt")
    "Serializers use explicit allowlists and sanitized failure categories." #f)
   (acceptance-case
    "M6-A-023" "Whole-M6 static boundary audit" "A"
    '("M6-CP7-009")
    "static" '("scripts/acceptance/check-m6-static.sh")
    "Classifies raw SQLite calls and freezes migration, HTTP, service, Flatpak, and RPM boundaries." #f)
   (acceptance-case
    "M6-A-024" "Deployable Nix source isolation" "A"
    '("M6-CP6-002" "M6-CP7-013")
    "nix-source" '("scripts/acceptance/check-nix-source-filter.sh")
    "Proves ignored .local and Flutter-generated state cannot alter RPM or terminal derivations." #f)))

(define (external-case id title tier requirements evidence)
  (acceptance-case
   id title tier requirements #f evidence
   "A specification/checklist exists, but this repository execution is not evidence that the external behavior passed."
   (case tier
     [("B") "Requires a booted Fedora Kinoite 44 x86_64 appliance."]
     [("C") "Requires the selected physical reference register hardware."]
     [else "Requires a disposable physical appliance and controlled abrupt power interruption."])))

(define tier-b-titles
  '("Genuine Fedora Kinoite 44 x86_64 host"
    "Bootstrap and rpm-ostree deployment"
    "Reboot into layered deployment"
    "Installed filesystem ownership and modes"
    "Actual systemd POS Core lifecycle"
    "Missing-database service guard"
    "SELinux-enforcing workflow"
    "System Flatpak installation and execution"
    "Kiosk and backend group separation"
    "Behavioral Flatpak database-access denial"
    "Plasma Login Manager autologin"
    "Terminal user-service restart"
    "Plasma session relogin"
    "Sleep and hibernate policy"
    "Offline no-Internet checkout"
    "Ten reboot cycles"
    "Same-release rpm-ostree update"
    "rpm-ostree rollback with persistent database"
    "Installed support collection"
    "Installed offline restore"))

(define tier-c-titles
  '("Cashier display placement"
    "Portrait secondary display"
    "Extended rather than mirrored topology"
    "Cashier fullscreen placement"
    "Touchscreen mapping"
    "Display layout reboot persistence"
    "Display reconnect recovery"
    "Technician virtual-console path"
    "Idle without suspend or lock"
    "Reference storage identification and qualification"))

(define tier-b-cases
  (for/list ([title (in-list tier-b-titles)] [number (in-naturals 1)])
    (external-case
     (format "M6-B-~a" (~r number #:min-width 3 #:pad-string "0"))
     title "B" '("M6-CP7-010")
     '("packaging/acceptance/qualify-kinoite.sh" "docs/acceptance/m6/test-plan.md"))))

(define tier-c-cases
  (for/list ([title (in-list tier-c-titles)] [number (in-naturals 1)])
    (external-case
     (format "M6-C-~a" (~r number #:min-width 3 #:pad-string "0"))
     title "C" '("M6-CP7-011")
     '("docs/acceptance/m6/reference-hardware.md"))))

(define tier-d-cases
  (list
   (external-case
    "M6-D-001" "Twenty-five-cycle abrupt power-interruption campaign" "D"
    '("M6-CP7-012") '("docs/acceptance/m6/power-interruption.md"))))

(define all-cases (append tier-a-cases tier-b-cases tier-c-cases tier-d-cases))

(define (read-summary path)
  (call-with-input-file path read-json))

(define (source-index summary)
  (for/hash ([group (in-list (hash-ref summary 'groups '()))])
    (values (hash-ref group 'id) group)))

(define (case->json item sources)
  (define source-name (acceptance-case-source-group item))
  (define source (and source-name (hash-ref sources source-name #f)))
  (define ran? (and source #t))
  (hasheq
   'id (acceptance-case-id item)
   'title (acceptance-case-title item)
   'tier (acceptance-case-tier item)
   'requirements (acceptance-case-requirements item)
   'status (if ran? (hash-ref source 'status) "not_run")
   'execution_timestamp (if ran? (hash-ref source 'timestamp) 'null)
   'environment_description
   (if ran? (hash-ref source 'environment) "External qualification environment not supplied")
   'evidence_references
   (append
    (acceptance-case-evidence item)
    (if ran? (list (hash-ref source 'evidence_log)) '()))
   'notes (acceptance-case-notes item)
   'blocking_issue
   (cond
     [(not ran?) (or (acceptance-case-blocking-issue item)
                     "The deterministic acceptance group did not execute.")]
     [(string=? (hash-ref source 'status) "passed") 'null]
     [else (hash-ref source 'blocking_issue "The acceptance command failed; inspect its local evidence log.")])
   'command (if ran? (hash-ref source 'command) 'null)))

(define (overall-status results)
  (cond
    [(for/or ([result (in-list results)])
       (string=? (hash-ref result 'status) "failed"))
     "failing"]
    [(for/or ([result (in-list results)])
       (member (hash-ref result 'status) '("blocked" "not_run")))
     "conditional"]
    [else "passing"]))

(define (generate-report summary-path output-path)
  (define summary (read-summary summary-path))
  (define sources (source-index summary))
  (define results
    (for/list ([item (in-list all-cases)])
      (case->json item sources)))
  (define document
    (hasheq
     'schema_version 1
     'milestone 6
     'reference_commit (hash-ref summary 'reference_commit)
     'generated_at (hash-ref summary 'generated_at)
     'reference_platform
     (hasheq
      'repository_tier_a_environment (hash-ref summary 'environment)
      'booted_appliance "Fedora Kinoite 44 x86_64 (qualification not supplied)"
      'reference_hardware "Not selected/recorded in this repository execution"
      'destructive_test_appliance "Not supplied")
     'test_groups results
     'overall_status (overall-status results)))
  (make-parent-directory* output-path)
  (call-with-output-file output-path
    (lambda (output)
      (write-json document output #:indent 2)
      (newline output))
    #:exists 'truncate/replace))

(module+ main
  (define arguments (vector->list (current-command-line-arguments)))
  (unless (= (length arguments) 2)
    (raise-user-error 'm6-report "expected SUMMARY.json OUTPUT.json"))
  (generate-report (first arguments) (second arguments)))
