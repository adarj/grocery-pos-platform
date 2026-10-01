#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
metadata="$(mktemp /tmp/m8-2-static.XXXXXX)"
trap 'rm -f -- "$metadata"' EXIT
cargo metadata --locked --no-deps --format-version 1 --manifest-path rust/edge/Cargo.toml >"$metadata"
racket scripts/acceptance/check-m8-2-static.rkt "$metadata"
