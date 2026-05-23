set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

default:
    @just --list

doctor:
    ./scripts/dev/doctor.sh

fmt:
    @echo "TODO: format all project code"

test:
    @echo "TODO: run all tests"

check:
    just fmt
    just test

run-racket:
    @echo "TODO: run Racket POS backend"

run-pos:
    @echo "TODO: run Flutter POS terminal"

supabase-start:
    @echo "TODO: start local Supabase"

tofu-plan ENV:
    @echo "TODO: OpenTofu plan for {{ENV}}"
