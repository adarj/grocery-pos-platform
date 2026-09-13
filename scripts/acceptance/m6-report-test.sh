#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
temporary_directory="$(mktemp -d)"
trap 'rm -rf -- "$temporary_directory"' EXIT

summary="$temporary_directory/summary.json"
report="$temporary_directory/report.json"

jq -n '{
  reference_commit: "test-commit",
  generated_at: "2026-09-12T00:00:00Z",
  environment: "deterministic report test",
  groups: [
    {id: "racket", status: "passed", timestamp: "2026-09-12T00:00:00Z", environment: "test", evidence_log: ".local/test.log", command: "test"},
    {id: "flutter", status: "passed", timestamp: "2026-09-12T00:00:00Z", environment: "test", evidence_log: ".local/test.log", command: "test"},
    {id: "integration", status: "passed", timestamp: "2026-09-12T00:00:00Z", environment: "test", evidence_log: ".local/test.log", command: "test"},
    {id: "nix-native", status: "passed", timestamp: "2026-09-12T00:00:00Z", environment: "test", evidence_log: ".local/test.log", command: "test"},
    {id: "nix-x86", status: "passed", timestamp: "2026-09-12T00:00:00Z", environment: "test", evidence_log: ".local/test.log", command: "test"},
    {id: "soak", status: "passed", timestamp: "2026-09-12T00:00:00Z", environment: "test", evidence_log: ".local/test.log", command: "test"},
    {id: "enospc", status: "passed", timestamp: "2026-09-12T00:00:00Z", environment: "test", evidence_log: ".local/test.log", command: "test"},
    {id: "static", status: "passed", timestamp: "2026-09-12T00:00:00Z", environment: "test", evidence_log: ".local/test.log", command: "test"},
    {id: "nix-source", status: "passed", timestamp: "2026-09-12T00:00:00Z", environment: "test", evidence_log: ".local/test.log", command: "test"}
  ]
}' >"$summary"

racket "$repository_root/scripts/acceptance/m6-report.rkt" "$summary" "$report"
jq -e '
  .schema_version == 1 and
  .milestone == 6 and
  .reference_commit == "test-commit" and
  .overall_status == "conditional" and
  ([.test_groups[] | select(.tier == "A") | .status] | all(. == "passed")) and
  ([.test_groups[] | select(.tier != "A") | .status] | all(. == "not_run"))
' "$report" >/dev/null

jq '(.groups[] | select(.id == "racket") | .status) = "failed"' \
  "$summary" >"$temporary_directory/failing-summary.json"
racket "$repository_root/scripts/acceptance/m6-report.rkt" \
  "$temporary_directory/failing-summary.json" "$report"
jq -e '.overall_status == "failing"' "$report" >/dev/null

printf '%s\n' 'm6-report-test-passed: external not-run evidence stays conditional and deterministic failures stay failing'
