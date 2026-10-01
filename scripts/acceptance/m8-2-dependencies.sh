#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
# Executed inside the pinned devShell by A-012. No global package install.
racket scripts/acceptance/m8-2-dependencies.rkt
sha256sum rust/edge/Cargo.lock flake.lock nix/racket-http-client-bounds.patch
raco test pos-backend-racket/tests/edge-client-framing-test.rkt pos-backend-racket/tests/edge-qualification-test.rkt
