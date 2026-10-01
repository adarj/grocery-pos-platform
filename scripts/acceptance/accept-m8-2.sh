#!/usr/bin/env bash
set -euo pipefail
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repository_root"
# No dirty override: component campaigns/self-tests are the Phase-1 interface.
source_state="$(git status --porcelain=v1 --untracked-files=all)"
if [[ -n "$source_state" ]]; then
  printf '%s\n' 'M8.2 authoritative campaign requires a clean committed tree; run constituent harnesses for development.' >&2
  exit 1
fi
reference_commit="$(git rev-parse HEAD)"
artifact_directory="$repository_root/.local/acceptance/m8-2"
mkdir -p "$artifact_directory"
results_jsonl="$artifact_directory/tier-a-groups.jsonl"
summary="$artifact_directory/run-summary.json"
report="$repository_root/docs/acceptance/m8.2/acceptance-results.json"
pending_report="$artifact_directory/acceptance-results.next.json"
# One run owns the fixed logs/summary. A stale lock after SIGKILL requires
# explicit operator inspection; never combine concurrent campaign evidence.
lock="$artifact_directory/run.lock"
if ! mkdir "$lock"; then
  printf '%s\n' 'M8.2 campaign already active or stale run lock; publication refused.' >&2
  exit 1
fi
active_pid=''
cleanup() {
  local result=$?
  trap - EXIT INT TERM
  if [[ -n "$active_pid" ]]; then
    # Every group is supervised by GNU timeout, which owns a process group.
    kill -TERM -- "-$active_pid" 2>/dev/null || true
    kill -TERM -- "$active_pid" 2>/dev/null || true
    wait "$active_pid" 2>/dev/null || true
  fi
  rm -f -- "$summary.next" "$pending_report" || result=1
  rmdir "$lock" || result=1
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Invalidate old final output only by publishing a completed new report. Local
# summary is not reusable until this run reaches its atomic publication below.
rm -f -- "$summary"
: >"$results_jsonl"
source /etc/os-release
environment="${ID:-unknown} ${VERSION_ID:-unknown}; $(uname -m); kernel $(uname -r); $(racket --version); $(rustc --version)"
mandatory_failure=0
run_group() {
  local id="$1"; shift
  local timestamp display exit_code status blocking_issue
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf -v display '%q ' "$@"; display="${display% }"
  printf 'M8.2 Tier A %s running\n' "$id"
  # Opening a log is evidence infrastructure, not an executed test failure.
  local log_fd
  exec {log_fd}>"$artifact_directory/$id.log"
  "$@" >&"$log_fd" 2>&1 &
  active_pid=$!
  exec {log_fd}>&-
  if wait "$active_pid"; then exit_code=0; else exit_code=$?; fi
  active_pid=''
  case "$exit_code" in
    0) status=passed; blocking_issue='' ;;
    77) status=blocked; blocking_issue='Required repository host capability unavailable.'; mandatory_failure=1 ;;
    *) status=failed; blocking_issue="Command exited $exit_code; inspect ignored log."; mandatory_failure=1 ;;
  esac
  jq -nc --arg id "$id" --arg status "$status" --arg timestamp "$timestamp" \
    --arg environment "$environment" --arg command "$display" --argjson exit_code "$exit_code" \
    --arg evidence_log ".local/acceptance/m8-2/$id.log" --arg blocking_issue "$blocking_issue" \
    '{id:$id,status:$status,timestamp:$timestamp,environment:$environment,command:$command,exit_code:$exit_code,evidence_log:$evidence_log,blocking_issue:$blocking_issue}' >>"$results_jsonl"
  printf 'M8.2 Tier A %s %s\n' "$id" "$status"
}
# Instrument self-tests precede qualification and use only temporary summaries.
bash scripts/acceptance/m8-2-report-test.sh
run_group M8.2-A-001 timeout --kill-after=10s 20m just check-rust
run_group M8.2-A-002 timeout --kill-after=10s 5m bash scripts/acceptance/m8-2-campaign.sh racket
run_group M8.2-A-003 timeout --kill-after=10s 30m just check
run_group M8.2-A-004 timeout --kill-after=10s 5m bash scripts/acceptance/check-m8-2-static.sh
run_group M8.2-A-005 timeout --kill-after=10s 5m bash scripts/acceptance/m8-2-campaign.sh identity
run_group M8.2-A-006 timeout --kill-after=10s 5m bash scripts/acceptance/m8-2-campaign.sh effects
run_group M8.2-A-007 timeout --kill-after=10s 5m bash scripts/acceptance/m8-2-campaign.sh binding
run_group M8.2-A-008 timeout --kill-after=10s 5m bash scripts/acceptance/m8-2-campaign.sh transport
run_group M8.2-A-009 timeout --kill-after=10s 5m bash scripts/acceptance/m8-2-campaign.sh uncertainty
run_group M8.2-A-010 timeout --kill-after=10s 10m bash scripts/acceptance/m8-2-campaign.sh capacity
run_group M8.2-A-011 timeout --kill-after=10s 10m racket scripts/acceptance/m8-2-process.rkt death 25
run_group M8.2-A-012 timeout --kill-after=10s 10m bash scripts/acceptance/m8-2-campaign.sh dependencies
run_group M8.2-A-013 timeout --kill-after=10s 10m bash scripts/acceptance/m8-2-campaign.sh isolation
run_group M8.2-A-014 timeout --kill-after=10s 5m bash scripts/acceptance/m8-2-campaign.sh integrity
jq -s --arg reference_commit "$reference_commit" --arg environment "$environment" \
  --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{reference_commit:$reference_commit,tested_worktree_state:"clean",generated_at:$generated_at,environment:$environment,evidence_kind:"authoritative",groups:.}' \
  "$results_jsonl" >"$summary.next"
# Prepare both outputs in ignored storage, then recheck immediately before
# atomic publication. A Git inspection failure also aborts publication.
racket scripts/acceptance/m8-2-report.rkt "$summary.next" "$pending_report"
final_commit="$(git rev-parse HEAD)"
final_state="$(git status --porcelain=v1 --untracked-files=all)"
if [[ "$final_commit" != "$reference_commit" || -n "$final_state" ]]; then
  printf '%s\n' 'Source changed during campaign; authoritative evidence publication refused.' >&2
  exit 1
fi
mv -- "$summary.next" "$summary"
mv -- "$pending_report" "$report"
if (( mandatory_failure )); then
  printf '%s\n' 'M8.2 Tier A failed or blocked; the ledger records the result.' >&2; exit 1
fi
printf '%s\n' 'M8.2 Generic Edge Foundation Tier A passed. Whole-M8 and Tier B/C/D remain separate.'
