set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

default:
    @just --list

doctor:
    ./scripts/dev/doctor.sh

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
    cd flutter/apps/pos_terminal && flutter test --concurrency=1 integration/real_pos_core_test.dart

analyze-flutter:
    cd flutter/apps/pos_terminal && flutter analyze

# Builds the internal noarch Fedora POS Core RPM without installing it.
build-pos-core-rpm:
    nix build path:.#pos-core-rpm

# Builds, extracts, inspects, and lifecycle-tests the Fedora POS Core package.
check-pos-core-package:
    nix flake check path:. --print-build-logs

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

supabase-start:
    @echo "TODO: start local Supabase"

tofu-plan ENV:
    @echo "TODO: OpenTofu plan for {{ENV}}"
