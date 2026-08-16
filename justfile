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

analyze-flutter:
    cd flutter/apps/pos_terminal && flutter analyze

supabase-start:
    @echo "TODO: start local Supabase"

tofu-plan ENV:
    @echo "TODO: OpenTofu plan for {{ENV}}"
