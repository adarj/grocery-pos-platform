#!/usr/bin/env bash
set -euo pipefail
# Isolated runner control-flow tests. No real repository campaign or ledger.
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
scratch="$(mktemp -d /tmp/m8-2-runner-test.XXXXXX)"
runner_pid=''
cleanup() {
  if [[ -n "$runner_pid" ]]; then kill -TERM "$runner_pid" 2>/dev/null || true; wait "$runner_pid" 2>/dev/null || true; fi
  rm -rf -- "$scratch"
}
trap cleanup EXIT
fixture="$scratch/repository"
mkdir -p "$fixture/scripts/acceptance" "$fixture/docs/acceptance/m8.2" "$scratch/bin"
cp "$repository_root/scripts/acceptance/"{accept-m8-2.sh,m8-2-report.rkt} "$fixture/scripts/acceptance/"
real_report="$repository_root/docs/acceptance/m8.2/acceptance-results.json"
if [[ -f "$real_report" ]]; then original_report="$(sha256sum "$real_report")"; else original_report=absent; fi
original_index="$(git -C "$repository_root" diff --cached --binary | sha256sum)"
export M82_REAL_RACKET="$(command -v racket)" M82_REAL_JQ="$(command -v jq)"
export M82_TEST_STATE="$scratch/state"
mkdir -p "$M82_TEST_STATE"
cat >"$scratch/mock" <<'MOCK'
#!/usr/bin/bash
set -eu
failure="${M82_TEST_FAILURE:-}"
case "${0##*/}" in
  git)
    case "$*" in
      *status*)
        [[ "$*" == *--untracked-files=all* ]] || exit 19
        [[ "$failure" != status-error ]] || exit 12
        [[ "$failure" != final-status-error || ! -e "$M82_TEST_STATE/started" ]] || exit 12
        case "$failure" in
          dirty|tracked) printf '%s\n' ' M source';;
          staged) printf '%s\n' 'M  source';;
          untracked) printf '%s\n' '?? new.rs';;
          deleted) printf '%s\n' ' D source';;
          renamed) printf '%s\n' 'R  old -> new';;
        esac
        if [[ -e "$M82_TEST_STATE/source-changed" ]]; then cat "$M82_TEST_STATE/source-changed"; fi ;;
      *rev-parse*)
        [[ "$failure" != head-error ]] || exit 13
        [[ "$failure" != final-head-error || ! -e "$M82_TEST_STATE/started" ]] || exit 13
        if [[ -e "$M82_TEST_STATE/head-changed" ]]; then printf '%040d\n' 2; else printf '%040d\n' 1; fi ;;
      *) exit 19 ;;
    esac ;;
  bash|timeout)
    [[ "$*" != *m8-2-report-test.sh* ]] || exit 0
    printf '%s\n' "$*" >>"$M82_TEST_STATE/commands"
    touch "$M82_TEST_STATE/started"
    if [[ "$*" == *check-rust* ]]; then
      case "$failure" in
        command) exit 9 ;;
        blocked) exit 77 ;;
        source-mid) printf '%s\n' ' M source' >"$M82_TEST_STATE/source-changed" ;;
        untracked-mid) printf '%s\n' '?? new.rs' >"$M82_TEST_STATE/source-changed" ;;
        staged-mid) printf '%s\n' 'M  source' >"$M82_TEST_STATE/source-changed" ;;
        head-mid) touch "$M82_TEST_STATE/head-changed" ;;
        signal)
          exec /usr/bin/timeout --kill-after=1s 30s /usr/bin/bash -c 'echo $$ > "$M82_TEST_STATE/child.pid"; exec sleep 30' ;;
      esac
    fi
    exit 0 ;;
  racket)
    [[ "${1:-}" != --version ]] || { printf '%s\n' 'Racket mock'; exit 0; }
    [[ "$failure" != report ]] || exit 1
    [[ "$failure" != source-after-guard ]] || printf '%s\n' ' M source' >"$M82_TEST_STATE/source-changed"
    [[ "$failure" != head-after-guard ]] || touch "$M82_TEST_STATE/head-changed"
    exec "$M82_REAL_RACKET" "$@" ;;
  jq)
    [[ "$failure" != append || "$*" != *"--arg id "* ]] || exit 1
    [[ "$failure" != summary || "${1:-}" != -s ]] || exit 1
    if [[ "$failure" == corrupt-append && "$*" == *"--arg id "* ]]; then printf '%s\n' '{broken'; exit 0; fi
    if [[ "$failure" == source-at-summary && "${1:-}" == -s ]]; then printf '%s\n' '?? new.rs' >"$M82_TEST_STATE/source-changed"; fi
    exec "$M82_REAL_JQ" "$@" ;;
  mv)
    [[ "$failure" != publish ]] || exit 1
    [[ "$failure" != publish-report || "${!#}" != */acceptance-results.json ]] || exit 1
    exec /usr/bin/mv "$@" ;;
  rustc) printf '%s\n' 'rustc mock' ;;
esac
MOCK
chmod +x "$scratch/mock"
for name in git bash timeout racket jq mv rustc; do cp "$scratch/mock" "$scratch/bin/$name"; done
run_runner() { PATH="$scratch/bin:$PATH" M82_TEST_FAILURE="$1" /usr/bin/bash "$fixture/scripts/acceptance/accept-m8-2.sh"; }
# A previous valid synthetic ledger must survive all infrastructure failures.
run_runner '' >"$scratch/baseline.log" 2>&1
cp "$fixture/docs/acceptance/m8.2/acceptance-results.json" "$scratch/previous.json"
failures=(dirty tracked staged untracked deleted renamed status-error head-error final-status-error final-head-error
          source-mid untracked-mid staged-mid head-mid source-at-summary source-after-guard head-after-guard
          command blocked append corrupt-append log-open summary report publish publish-report locked)
if (( $# )); then
  for requested in "$@"; do [[ " ${failures[*]} " == *" $requested "* ]] || { echo 'unknown isolated runner case' >&2; exit 2; }; done
  failures=("$@")
fi
for failure in "${failures[@]}"; do
  rm -rf -- "$fixture/.local" "$M82_TEST_STATE"
  mkdir -p "$fixture/.local/acceptance/m8-2" "$M82_TEST_STATE"
  cp "$scratch/previous.json" "$fixture/docs/acceptance/m8.2/acceptance-results.json"
  # Old partial/development evidence cannot satisfy this invocation.
  printf '%s\n' '{"id":"M8.2-A-999","status":"passed"}' >"$fixture/.local/acceptance/m8-2/tier-a-groups.jsonl"
  printf '%s\n' 'stale summary' >"$fixture/.local/acceptance/m8-2/run-summary.json"
  [[ "$failure" != log-open ]] || mkdir "$fixture/.local/acceptance/m8-2/M8.2-A-001.log"
  [[ "$failure" != locked ]] || mkdir "$fixture/.local/acceptance/m8-2/run.lock"
  if run_runner "$failure" >"$scratch/$failure.log" 2>&1; then
    printf 'm8-2-runner-test failed: %s returned success\n' "$failure" >&2; exit 1
  fi
  if [[ "$failure" == blocked ]]; then
    "$M82_REAL_JQ" -e '.overall_status=="conditional" and .test_groups[0].status=="blocked" and .test_groups[13].status=="passed" and (.test_groups|length)==14' "$fixture/docs/acceptance/m8.2/acceptance-results.json" >/dev/null
  elif [[ "$failure" == command ]]; then
    "$M82_REAL_JQ" -e '.overall_status=="failing" and (.test_groups|length)==14 and .test_groups[0].exit_code==9 and .test_groups[13].status=="passed"' "$fixture/docs/acceptance/m8.2/acceptance-results.json" >/dev/null
  else
    cmp "$scratch/previous.json" "$fixture/docs/acceptance/m8.2/acceptance-results.json"
  fi
  case "$failure" in
    dirty|tracked|staged|untracked|deleted|renamed|status-error|head-error|locked)
      [[ ! -e "$M82_TEST_STATE/commands" ]] || { echo 'campaign ran before provenance/lock guard' >&2; exit 1; } ;;
  esac
  printf 'm8-2-runner-test passed: %s\n' "$failure"
done
rm -rf -- "$fixture/.local" "$M82_TEST_STATE"
mkdir -p "$M82_TEST_STATE"
run_runner '' >"$scratch/success.log" 2>&1
"$M82_REAL_JQ" -e '.overall_status=="passing" and (.test_groups|length)==14' "$fixture/docs/acceptance/m8.2/acceptance-results.json" >/dev/null
# Interrupt an owned, genuinely supervised child. A second runner cannot steal
# its logs/summary; cancellation cannot publish or leave the child alive.
cp "$fixture/docs/acceptance/m8.2/acceptance-results.json" "$scratch/before-signal.json"
PATH="$scratch/bin:$PATH" M82_TEST_FAILURE=signal /usr/bin/bash "$fixture/scripts/acceptance/accept-m8-2.sh" >"$scratch/signal.log" 2>&1 &
runner_pid=$!
for _ in {1..200}; do [[ -s "$M82_TEST_STATE/child.pid" ]] && break; sleep .01; done
[[ -s "$M82_TEST_STATE/child.pid" ]] || { kill "$runner_pid"; wait "$runner_pid" || true; exit 1; }
if run_runner '' >"$scratch/concurrent.log" 2>&1; then echo 'concurrent runner accepted' >&2; kill "$runner_pid"; wait "$runner_pid" || true; exit 1; fi
kill -TERM "$runner_pid"
if wait "$runner_pid"; then echo 'interrupted runner returned success' >&2; exit 1; fi
runner_pid=''
child_pid="$(cat "$M82_TEST_STATE/child.pid")"
for _ in {1..200}; do if ! kill -0 "$child_pid" 2>/dev/null; then break; fi; sleep .01; done
if kill -0 "$child_pid" 2>/dev/null; then kill -KILL "$child_pid"; echo 'interrupted child survived' >&2; exit 1; fi
cmp "$scratch/before-signal.json" "$fixture/docs/acceptance/m8.2/acceptance-results.json"
[[ ! -e "$fixture/.local/acceptance/m8-2/run.lock" ]]
if [[ "$original_report" == absent ]]; then [[ ! -f "$real_report" ]]; else [[ "$(sha256sum "$real_report")" == "$original_report" ]]; fi
[[ "$(git -C "$repository_root" diff --cached --binary | sha256sum)" == "$original_index" ]]
printf '%s\n' 'm8-2-runner-test passed: isolated mocks, stale evidence reset, prior ledger preserved, cancellation/concurrent exclusion'
