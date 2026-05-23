set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

default:
    @just --list

doctor:
    ./scripts/dev/doctor.sh

fmt:
    @echo "TODO: format all project code"

test:
    just test-racket

check:
    just fmt
    just test

run-racket:
    cd pos-backend-racket && racket main.rkt

test-racket:
    cd pos-backend-racket && raco test tests

run-pos:
    @echo "TODO: run Flutter POS terminal"

supabase-start:
    @echo "TODO: start local Supabase"

tofu-plan ENV:
    @echo "TODO: OpenTofu plan for {{ENV}}"

