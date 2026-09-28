set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

default:
    @just --list

doctor:
    ./scripts/dev/doctor.sh

# Optional, offline and sanitized checks for the qualified agent setup.
agent-doctor:
    ./scripts/dev/agent-doctor.sh

test:
    just test-racket
    just test-flutter

check:
    just analyze-flutter
    just test
    just test-pos-integration

run-racket:
    cd pos-backend-racket && racket main.rkt

test-racket:
    cd pos-backend-racket && raco test tests

run-pos:
    cd flutter/apps/pos_terminal && nix run --impure github:nix-community/nixGL#nixGLIntel -- flutter run -d linux

run-pos-plain:
    cd flutter/apps/pos_terminal && flutter run -d linux

test-flutter:
    cd flutter/apps/pos_terminal && flutter test

test-pos-integration:
    cd flutter/apps/pos_terminal && flutter test --concurrency=1 --timeout=2m integration/real_pos_core_test.dart

analyze-flutter:
    cd flutter/apps/pos_terminal && flutter analyze

# Builds the internal noarch Fedora POS Core RPM without installing it.
build-pos-core-rpm:
    nix build path:.#pos-core-rpm

# Builds, extracts, inspects, and lifecycle-tests the Fedora POS Core package.
check-pos-core-package:
    nix flake check path:. --print-build-logs

# Builds the noarch Fedora host-integration package for the register appliance.
build-pos-appliance-rpm:
    nix build path:.#pos-appliance-rpm

# Builds the source-pinned system Flatpak for the cashier terminal.
build-pos-terminal-flatpak:
    nix build path:.#pos-terminal-flatpak

# Builds the technician-facing RPM/Flatpak/bootstrap artifact bundle.
build-appliance-bundle:
    nix build path:.#appliance-bundle

# Runs rootless RPM, Flatpak, bootstrap, provisioning, and bundle contracts.
check-pos-appliance:
    nix flake check path:. --print-build-logs

# Runs only deterministic/rootless Milestone 6 acceptance and records concise
# evidence. It never mutates rpm-ostree, users, systemd, displays, or power.
accept-m6:
    scripts/acceptance/accept-m6.sh

# Regenerates the committed ledger from the most recent ignored local run.
acceptance-report-m6:
    racket scripts/acceptance/m6-report.rkt .local/acceptance/m6/run-summary.json docs/acceptance/m6/acceptance-results.json

# Optional bounded extended workload; the ordinary Tier A run uses 100 cycles.
soak-m6 ITERATIONS="1000":
    racket scripts/acceptance/m6-soak.rkt {{quote(ITERATIONS)}}

# Optional extended real-process crash campaign; Tier A runs three iterations.
crash-m6 ITERATIONS="100":
    cd flutter/apps/pos_terminal && M6_CRASH_ITERATIONS={{quote(ITERATIONS)}} flutter test --concurrency=1 --timeout=2m integration/real_pos_core_test.dart --plain-name "repeated accepted commands survive abrupt POS Core process death"

# Read-only qualification observations for an already booted reference host.
qualify-m6-kinoite:
    packaging/acceptance/qualify-kinoite.sh

# Deterministic M7 security acceptance; external appliance/hardware evidence
# remains separately recorded and cannot be inferred from this runner.
accept-m7:
    bash scripts/acceptance/accept-m7.sh

acceptance-report-m7:
    racket scripts/acceptance/m7-report.rkt .local/acceptance/m7/run-summary.json docs/acceptance/m7/acceptance-results.json

stress-m7 EVENTS="10000":
    racket scripts/acceptance/m7-security-stress.rkt {{quote(EVENTS)}}

qualify-m7-kinoite:
    bash packaging/acceptance/qualify-m7-kinoite.sh

catalog-validate FILE:
    racket pos-backend-racket/scripts/catalog.rkt validate {{quote(FILE)}}

# Replaces the complete current catalog in the explicitly selected database.
catalog-activate FILE DB:
    racket pos-backend-racket/scripts/catalog.rkt activate {{quote(FILE)}} {{quote(DB)}}

register-config-validate FILE:
    racket pos-backend-racket/scripts/register-configuration.rkt validate {{quote(FILE)}}

# Replaces current register/cashier configuration only when no shift is open.
register-config-activate FILE DB:
    racket pos-backend-racket/scripts/register-configuration.rkt activate {{quote(FILE)}} {{quote(DB)}}

# Reports structural SQLite, migration, and WAL/file metadata without mutation.
db-info DB:
    racket pos-backend-racket/scripts/database-maintenance.rkt info {{quote(DB)}}

db-quick-check DB:
    racket pos-backend-racket/scripts/database-maintenance.rkt quick-check {{quote(DB)}}

db-integrity-check DB:
    racket pos-backend-racket/scripts/database-maintenance.rkt integrity-check {{quote(DB)}}

# Publishes OUTPUT only after a live VACUUM INTO snapshot validates read-only.
db-backup DB OUTPUT:
    racket pos-backend-racket/scripts/database-maintenance.rkt backup {{quote(DB)}} {{quote(OUTPUT)}}

db-backup-validate BACKUP:
    racket pos-backend-racket/scripts/database-maintenance.rkt backup-validate {{quote(BACKUP)}}

# Restores a selected backup; the caller must first ensure DB is offline.
db-restore-offline BACKUP DB:
    racket pos-backend-racket/scripts/database-recovery.rkt restore-offline {{quote(BACKUP)}} {{quote(DB)}}

# Creates a local, allowlisted diagnostic archive without stopping POS Core.
support-bundle DB OUTPUT:
    racket pos-backend-racket/scripts/support-diagnostics.rkt collect {{quote(DB)}} {{quote(OUTPUT)}}
