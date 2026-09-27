#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
artifact_directory="$repository_root/.local/acceptance/m7"
results_jsonl="$artifact_directory/tier-a-groups.jsonl"
summary="$artifact_directory/run-summary.json"
report="$repository_root/docs/acceptance/m7/acceptance-results.json"
mkdir -p "$artifact_directory"
: >"$results_jsonl"

source /etc/os-release
environment="${ID:-unknown} ${VERSION_ID:-unknown}; $(uname -m); kernel $(uname -r)"
reference_commit="$(git -C "$repository_root" rev-parse HEAD)"
if [[ -z "$(git -C "$repository_root" status --porcelain=v1)" ]]; then
  worktree_state=clean
else
  worktree_state=uncommitted_cp7
fi
mandatory_failure=0

run_group() {
  local id="$1"; shift
  local log="$artifact_directory/$id.log"
  local timestamp display exit_code status blocking_issue
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf -v display '%q ' "$@"
  display="${display% }"
  printf 'M7 Tier A %-18s running\n' "$id"
  # A qualification command may fail: record that result and continue. Failure
  # to record/publish evidence is different and must stop the runner.
  if (cd "$repository_root" && "$@") >"$log" 2>&1; then
    exit_code=0
  else
    exit_code=$?
  fi
  case "$exit_code" in
    0) status=passed; blocking_issue='' ;;
    77) status=blocked; blocking_issue='Required isolated host capability unavailable.'; mandatory_failure=1 ;;
    *) status=failed; blocking_issue="Command exited with status $exit_code; inspect ignored local log."; mandatory_failure=1 ;;
  esac
  if [[ "$id" == x86-artifacts && "$exit_code" -ne 0 ]]; then
    if rg -qi 'required system or feature not available|not supported on.*system|no available builder|a .x86_64-linux. .*is required|cannot execute binary file|Exec format error|unsupported host mount|/etc/resolv.conf.*mount' "$log"; then
      status=blocked
      blocking_issue='Target builder/emulation or host sandbox capability unavailable; derivations were not qualified.'
    fi
  fi
  printf 'M7 Tier A %-18s %s\n' "$id" "$status"
  jq -nc --arg id "$id" --arg status "$status" \
    --arg timestamp "$timestamp" --arg environment "$environment" \
    --arg evidence_log ".local/acceptance/m7/$id.log" \
    --arg command "$display" --arg blocking_issue "$blocking_issue" \
    '{id:$id,status:$status,timestamp:$timestamp,environment:$environment,evidence_log:$evidence_log,command:$command,blocking_issue:$blocking_issue}' \
    >>"$results_jsonl"
}

if ! bash "$repository_root/scripts/acceptance/m7-report-test.sh"; then
  printf '%s\n' 'M7 report-generator self-test failed; no acceptance run started.' >&2
  exit 1
fi

run_group racket just test-racket
run_group flutter just test-flutter
run_group integration just test-pos-integration
run_group check just check
run_group core-package just check-pos-core-package
run_group appliance-package just check-pos-appliance
run_group core-rpm nix build --no-link path:.#pos-core-rpm
run_group appliance-rpm nix build --no-link path:.#pos-appliance-rpm
run_group flake nix flake check path:. --print-build-logs
run_group static bash scripts/acceptance/check-m7-static.sh
run_group stress racket scripts/acceptance/m7-security-stress.rkt 10000
run_group source-isolation bash scripts/acceptance/check-nix-source-filter.sh
run_group crash env M6_CRASH_ITERATIONS=25 bash -c \
  'cd flutter/apps/pos_terminal && flutter test --concurrency=1 --timeout=10m integration/real_pos_core_test.dart --plain-name "repeated accepted commands survive abrupt POS Core process death"'
run_group enospc bash -c \
  'bash scripts/acceptance/m6-enospc.sh && bash scripts/acceptance/m7-enospc.sh'
run_group x86-artifacts nix build --no-link --print-build-logs \
  --extra-platforms x86_64-linux \
  path:.#checks.x86_64-linux.pos-terminal-flatpak \
  path:.#checks.x86_64-linux.appliance-bundle

generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
jq -s --arg reference_commit "$reference_commit" \
  --arg tested_worktree_state "$worktree_state" \
  --arg generated_at "$generated_at" --arg environment "$environment" \
  '{reference_commit:$reference_commit,tested_worktree_state:$tested_worktree_state,generated_at:$generated_at,environment:$environment,groups:.}' \
  "$results_jsonl" >"$summary"
racket "$repository_root/scripts/acceptance/m7-report.rkt" "$summary" "$report"

if (( mandatory_failure )); then
  printf '%s\n' 'M7 Tier A failed or was blocked. See the ledger and ignored local logs.' >&2
  exit 1
fi
printf '%s\n' 'M7 Tier A passed; external Tier B/C/D evidence is still required for overall passing.'
