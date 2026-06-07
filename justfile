set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

default:
    @just --list

doctor:
    ./scripts/dev/doctor.sh

fmt:
    @echo "TODO: format all project code"

test:
    just test-racket
    just test-flutter

check:
    just fmt
    just test

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

supabase-start:
    @echo "TODO: start local Supabase"

tofu-plan ENV:
    @echo "TODO: OpenTofu plan for {{ENV}}"

