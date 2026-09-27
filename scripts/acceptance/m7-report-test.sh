#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf -- "$scratch"' EXIT
summary="$scratch/summary.json"
report="$scratch/report.json"

write_summary() {
  jq -n --argjson groups "$1" '{
    reference_commit: "test-baseline",
    tested_worktree_state: "uncommitted_cp7",
    generated_at: "2026-09-25T00:00:00Z",
    environment: "report self-test",
    groups: $groups
  }' >"$summary"
}

all_groups='["racket","flutter","integration","check","core-package","appliance-package","core-rpm","appliance-rpm","flake","static","stress","source-isolation","crash","enospc","x86-artifacts"]'
passed_groups="$(jq -nc --argjson ids "$all_groups" '[ $ids[] | {id: ., status: "passed", timestamp: "2026-09-25T00:00:00Z", environment: "test", evidence_log: ".local/acceptance/m7/test.log", command: "test", blocking_issue: ""} ]')"

write_summary "$passed_groups"
racket "$repository_root/scripts/acceptance/m7-report.rkt" "$summary" "$report"
jq -e '.overall_status == "conditional" and ([.test_groups[] | select(.tier == "A") | .status] | all(. == "passed")) and ([.test_groups[] | select(.tier != "A") | .status] | all(. == "not_run"))' "$report" >/dev/null

jq '(.groups[] | select(.id == "racket") | .status) = "failed"' "$summary" >"$scratch/failed.json"
racket "$repository_root/scripts/acceptance/m7-report.rkt" "$scratch/failed.json" "$report"
jq -e '.overall_status == "failing"' "$report" >/dev/null

jq --argjson groups "$passed_groups" '. + {groups: $groups, external_cases: [.test_groups[] | select(.tier != "A") | {id, status: "passed", timestamp: "2026-09-25T00:00:00Z", environment: "actual external test", evidence_log: "test", command: "manual", blocking_issue: ""}]}' "$report" >"$scratch/all-pass-summary.json"
# The report is not itself a summary; derive external inventory from it while
# retaining the canonical summary envelope.
jq -n --slurpfile original "$summary" --slurpfile filled "$scratch/all-pass-summary.json" '$original[0] + {external_cases: $filled[0].external_cases}' >"$scratch/all-pass.json"
racket "$repository_root/scripts/acceptance/m7-report.rkt" "$scratch/all-pass.json" "$report"
jq -e '.overall_status == "passing"' "$report" >/dev/null

jq '(.external_cases[] | select(.id == "M7-D-001") | .status) = "blocked"' "$scratch/all-pass.json" >"$scratch/external-blocked.json"
racket "$repository_root/scripts/acceptance/m7-report.rkt" "$scratch/external-blocked.json" "$report"
jq -e '.overall_status == "conditional"' "$report" >/dev/null

jq '(.external_cases[] | select(.id == "M7-B-001") | .evidence_log) = ""' "$scratch/all-pass.json" >"$scratch/unsubstantiated.json"
if racket "$repository_root/scripts/acceptance/m7-report.rkt" "$scratch/unsubstantiated.json" "$report" >/dev/null 2>&1; then
  printf '%s\n' 'm7-report-test-failed: external pass without evidence was accepted' >&2
  exit 1
fi

jq '(.groups[] | select(.id == "x86-artifacts") | .status) = "blocked"' "$summary" >"$scratch/blocked.json"
racket "$repository_root/scripts/acceptance/m7-report.rkt" "$scratch/blocked.json" "$report"
jq -e '.overall_status == "conditional"' "$report" >/dev/null

write_summary '[]'
racket "$repository_root/scripts/acceptance/m7-report.rkt" "$summary" "$report"
jq -e '.overall_status == "conditional" and ([.test_groups[] | select(.tier == "A") | .status] | all(. == "not_run"))' "$report" >/dev/null

write_summary "$passed_groups"
jq '.groups += [{id: "unknown-deterministic-group", status: "passed"}]' "$summary" >"$scratch/unknown.json"
if racket "$repository_root/scripts/acceptance/m7-report.rkt" "$scratch/unknown.json" "$report" >/dev/null 2>&1; then
  printf '%s\n' 'm7-report-test-failed: unknown group was accepted' >&2
  exit 1
fi
jq '.groups += [.groups[0]]' "$summary" >"$scratch/duplicate.json"
if racket "$repository_root/scripts/acceptance/m7-report.rkt" "$scratch/duplicate.json" "$report" >/dev/null 2>&1; then
  printf '%s\n' 'm7-report-test-failed: duplicate group was accepted' >&2
  exit 1
fi

# Explicit external evidence may change disposition, but a failed mandatory
# external case can never be hidden by passing repository tests.
write_summary "$passed_groups"
jq '. + {external_cases: [{id: "M7-B-001", status: "failed", timestamp: "2026-09-25T00:00:00Z", environment: "appliance", evidence_log: "test", command: "manual", blocking_issue: "observed failure"}]}' "$summary" >"$scratch/external-failed.json"
racket "$repository_root/scripts/acceptance/m7-report.rkt" "$scratch/external-failed.json" "$report"
jq -e '.overall_status == "failing"' "$report" >/dev/null

printf '%s\n' 'm7-report-test-passed'
