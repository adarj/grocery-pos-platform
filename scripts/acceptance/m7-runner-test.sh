#!/usr/bin/env bash
set -euo pipefail

# These are runner control-flow tests, NEVER qualification evidence. Every
# expensive command is replaced in an isolated fake repository.
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
scratch="$(mktemp -d /tmp/grocery-pos-m7-runner-test.XXXXXX)"
trap 'rm -rf -- "$scratch"' EXIT
fixture="$scratch/repository"
mkdir -p "$fixture/scripts/acceptance" "$scratch/bin"
cp "$repository_root/scripts/acceptance/"{accept-m7.sh,m7-report.rkt,m7-report-test.sh} \
  "$fixture/scripts/acceptance/"
export M7_TEST_REAL_RACKET="$(command -v racket)"
export M7_TEST_REAL_JQ="$(command -v jq)"

printf '%s\n' '#!/usr/bin/bash' 'set -eu' \
  'case "${0##*/}" in' \
  '  just|nix) exit 0 ;;' \
  '  git) case "$*" in *rev-parse*) printf "%s\n" fixture-baseline ;; esac; exit 0 ;;' \
  '  bash) case "${1:-}" in *m7-report-test.sh) exec /usr/bin/bash "$@" ;; *) exit 0 ;; esac ;;' \
  '  racket)' \
  '    case "${1:-}" in' \
  '      *m7-report.rkt)' \
  '        if [[ "${M7_TEST_FAILURE:-}" == report && "${3:-}" == */docs/acceptance/m7/acceptance-results.json ]]; then exit 1; fi' \
  '        exec "$M7_TEST_REAL_RACKET" "$@" ;;' \
  '      *) exit 0 ;;' \
  '    esac ;;' \
  '  jq)' \
  '    if [[ "${M7_TEST_FAILURE:-}" == summary && "${1:-}" == -s ]]; then exit 1; fi' \
  '    if [[ "${M7_TEST_FAILURE:-}" == record && "$*" == *"--arg id "* ]]; then exit 1; fi' \
  '    exec "$M7_TEST_REAL_JQ" "$@" ;;' \
  'esac' >"$scratch/mock"
chmod +x "$scratch/mock"
for name in just nix git bash racket jq; do cp "$scratch/mock" "$scratch/bin/$name"; done

for failure in summary report record; do
  if PATH="$scratch/bin:$PATH" M7_TEST_FAILURE="$failure" \
     /usr/bin/bash "$fixture/scripts/acceptance/accept-m7.sh" >"$scratch/$failure.log" 2>&1; then
    printf 'm7-runner-test-failed: %s publication failure reported success\n' "$failure" >&2
    exit 1
  fi
done

PATH="$scratch/bin:$PATH" M7_TEST_FAILURE='' \
  /usr/bin/bash "$fixture/scripts/acceptance/accept-m7.sh" >"$scratch/success.log" 2>&1
"$M7_TEST_REAL_JQ" -e '.overall_status == "conditional" and ([.test_groups[] | select(.tier == "A") | .status] | all(. == "passed"))' \
  "$fixture/docs/acceptance/m7/acceptance-results.json" >/dev/null
printf '%s\n' 'm7-runner-test-passed: isolated mocks, not qualification evidence'
