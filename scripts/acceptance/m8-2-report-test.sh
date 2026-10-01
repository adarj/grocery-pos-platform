#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
raco test scripts/acceptance/m8-2-report.rkt
