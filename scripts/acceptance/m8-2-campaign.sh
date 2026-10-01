#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
cargo_test() { cargo test --locked --manifest-path rust/edge/Cargo.toml "$@"; }
case "${1:-}" in
  racket) raco test pos-backend-racket/tests/edge-{protocol,client-framing,process,qualification}-test.rkt ;;
  identity) cargo_test -p edge-core --lib actor::tests ;;
  effects) cargo_test -p edge-core --test execution -- --skip lifecycle_events ;;
  binding) cargo_test -p edge-core --test execution lifecycle_events ;;
  transport)
    cargo_test -p edge-protocol
    cargo_test -p edge-server --all-features
    raco test pos-backend-racket/tests/edge-client-framing-test.rkt pos-backend-racket/tests/edge-qualification-test.rkt ;;
  uncertainty) raco test pos-backend-racket/tests/edge-process-test.rkt pos-backend-racket/tests/edge-client-framing-test.rkt ;;
  capacity)
    cargo_test -p edge-core qualification
    cargo_test -p edge-server --all-features qualification
    racket scripts/acceptance/m8-2-process.rkt load 1000 ;;
  dependencies)
    # The devShell realizes the repository-declared fixed sources and mandatory
    # patch application. Then behavior tests execute using those collections.
    nix develop --command bash scripts/acceptance/m8-2-dependencies.sh ;;
  isolation)
    bash scripts/acceptance/check-m8-2-static.sh
    bash scripts/acceptance/check-nix-source-filter.sh ;;
  integrity)
    bash scripts/acceptance/m8-2-report-test.sh
    bash scripts/acceptance/m8-2-runner-test.sh
    raco test scripts/acceptance/m8-2-document-test.rkt scripts/acceptance/m8-2-static-test.rkt ;;
  *) printf '%s\n' 'Expected closed M8.2 campaign name.' >&2; exit 2 ;;
esac
