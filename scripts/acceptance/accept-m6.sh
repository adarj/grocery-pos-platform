#!/usr/bin/env bash
set -uo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
artifact_directory="$repository_root/.local/acceptance/m6"
results_jsonl="$artifact_directory/tier-a-groups.jsonl"
summary="$artifact_directory/run-summary.json"
report="$repository_root/docs/acceptance/m6/acceptance-results.json"

mkdir -p "$artifact_directory"
: >"$results_jsonl"

source /etc/os-release
environment="${ID:-unknown} ${VERSION_ID:-unknown}; $(uname -m); kernel $(uname -r)"
reference_commit="$(git -C "$repository_root" rev-parse HEAD)"
mandatory_failure=0

run_group() {
  local id="$1"
  shift
  local log="$artifact_directory/$id.log"
  local timestamp command_display exit_code status blocking_issue
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf -v command_display '%q ' "$@"
  command_display="${command_display% }"

  printf '\n== M6 Tier A: %s ==\n' "$id"
  set +e
  (cd "$repository_root" && "$@") 2>&1 | tee "$log"
  exit_code="${PIPESTATUS[0]}"
  set -e

  case "$exit_code" in
    0)
      status=passed
      blocking_issue=''
      ;;
    77)
      status=blocked
      blocking_issue='The deterministic test declared its isolated host capability unavailable.'
      mandatory_failure=1
      ;;
    *)
      status=failed
      blocking_issue="The command exited with status $exit_code."
      mandatory_failure=1
      ;;
  esac

  jq -nc \
    --arg id "$id" \
    --arg status "$status" \
    --arg timestamp "$timestamp" \
    --arg environment "$environment" \
    --arg evidence_log ".local/acceptance/m6/$id.log" \
    --arg command "$command_display" \
    --arg blocking_issue "$blocking_issue" \
    '{id: $id, status: $status, timestamp: $timestamp,
      environment: $environment, evidence_log: $evidence_log,
      command: $command, blocking_issue: $blocking_issue}' \
    >>"$results_jsonl"
}

set -e
"$repository_root/scripts/acceptance/m6-report-test.sh"

run_group racket just test-racket
run_group flutter just test-flutter
run_group integration just test-pos-integration
run_group soak racket scripts/acceptance/m6-soak.rkt 100
run_group enospc scripts/acceptance/m6-enospc.sh
run_group static scripts/acceptance/check-m6-static.sh
run_group nix-source scripts/acceptance/check-nix-source-filter.sh
run_group nix-native nix flake check path:. --print-build-logs
run_group nix-x86 nix build --no-link --print-build-logs \
  --extra-platforms x86_64-linux \
  path:.#checks.x86_64-linux.pos-terminal-flatpak \
  path:.#checks.x86_64-linux.appliance-bundle

generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
jq -s \
  --arg reference_commit "$reference_commit" \
  --arg generated_at "$generated_at" \
  --arg environment "$environment" \
  '{reference_commit: $reference_commit, generated_at: $generated_at,
    environment: $environment, groups: .}' \
  "$results_jsonl" >"$summary"

racket "$repository_root/scripts/acceptance/m6-report.rkt" "$summary" "$report"

if (( mandatory_failure != 0 )); then
  printf '\n%s\n' 'M6 Tier A acceptance failed or was blocked. See the result ledger and local logs.' >&2
  exit 1
fi

printf '\n%s\n' \
  'M6 Tier A acceptance passed. Overall status remains conditional until required Tier B/C/D evidence passes.'
