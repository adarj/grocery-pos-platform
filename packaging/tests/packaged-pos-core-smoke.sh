#!/usr/bin/env bash

set -euo pipefail

fail() {
  printf 'packaged-pos-core-smoke-failed: %s\n' "$*" >&2
  if [[ -n "${core_log:-}" && -f "$core_log" ]]; then
    printf '%s\n' '--- packaged POS Core output ---' >&2
    tail -100 "$core_log" >&2
  fi
  exit 1
}

if [[ $# -ne 2 ]]; then
  fail "usage: packaged-pos-core-smoke.sh EXTRACTION-ROOT REPOSITORY-ROOT"
fi

extract_root="$1"
repository_root="$2"
payload_root="$extract_root/usr/libexec/grocery-pos-core"
export PLTCOLLECTS="$payload_root/vendor/racket/collects:"
work_root="$(mktemp -d)"
database_path="$work_root/pos.db"
backup_path="$work_root/pos-backup.db"
restore_target_path="$work_root/restored-pos.db"
support_bundle_path="$work_root/support.tar.gz"
support_extract_path="$work_root/support-extracted"
core_log="$work_root/pos-core.log"
core_pid=''
base_url=''

cleanup() {
  if [[ -n "$core_pid" ]] && kill -0 "$core_pid" 2>/dev/null; then
    kill -KILL "$core_pid" 2>/dev/null || true
    wait "$core_pid" 2>/dev/null || true
  fi
  rm -rf -- "$work_root"
}
trap cleanup EXIT

run_packaged_script() {
  (
    cd "$work_root"
    racket "$payload_root/scripts/$1" "${@:2}"
  )
}

run_packaged_script catalog.rkt activate \
  "$repository_root/pos-backend-racket/fixtures/development/catalog-snapshot-v2.json" \
  "$database_path" >/dev/null
run_packaged_script register-configuration.rkt activate \
  "$repository_root/fixtures/development/register-configuration-v1.json" \
  "$database_path" >/dev/null

PIN_MODULE="$payload_root/pos/security/operator-pin.rkt" racket -e \
  '(define module-path (string->path (getenv "PIN_MODULE")))
   (define hash-pin (dynamic-require module-path (quote hash-operator-pin)))
   (define verify-pin (dynamic-require module-path (quote verify-operator-pin)))
   (define verifier (hash-pin "80421637"))
   (unless (and (string-prefix? verifier "$argon2id$")
                (verify-pin "80421637" verifier)
                (not (verify-pin "80421638" verifier)))
     (error (quote packaged-auth-smoke) "Argon2id credential round trip failed"))'

allocate_port() {
  racket -e \
    '(begin (require racket/tcp) (define listener (tcp-listen 0 4 #t "127.0.0.1")) (define-values (_address port _remote-address _remote-port) (tcp-addresses listener #t)) (tcp-close listener) (display port))'
}

start_core() {
  local port
  port="$(allocate_port)"
  base_url="http://127.0.0.1:$port"
  : >"$core_log"
  (
    cd "$work_root"
    exec env \
      GROCERY_POS_ENV=package-test \
      RACKET_API_HOST=127.0.0.1 \
      RACKET_API_PORT="$port" \
      SQLITE_DB_PATH="$database_path" \
      racket "$payload_root/main.rkt"
  ) >"$core_log" 2>&1 &
  core_pid=$!

  for _attempt in $(seq 1 300); do
    if ! kill -0 "$core_pid" 2>/dev/null; then
      wait "$core_pid" 2>/dev/null || true
      core_pid=''
      fail "packaged POS Core exited before readiness"
    fi
    if readiness="$(curl --silent --show-error --max-time 1 "$base_url/ready" 2>/dev/null)" &&
      jq -e '.ok == true and .status == "ready" and .database_schema_version == 7' \
        <<<"$readiness" >/dev/null; then
      return
    fi
    sleep 0.1
  done
  fail "packaged POS Core did not become ready within 30 seconds"
}

stop_core_with_sigterm() {
  [[ -n "$core_pid" ]] || fail "no packaged POS Core process to stop"
  kill -TERM "$core_pid"
  for _attempt in $(seq 1 100); do
    if ! kill -0 "$core_pid" 2>/dev/null; then
      wait "$core_pid" 2>/dev/null || true
      core_pid=''
      return
    fi
    if [[ -r "/proc/$core_pid/stat" ]]; then
      read -r _pid _comm process_state _rest <"/proc/$core_pid/stat"
      if [[ "$process_state" == 'Z' ]]; then
        wait "$core_pid" 2>/dev/null || true
        core_pid=''
        return
      fi
    fi
    sleep 0.1
  done
  kill -KILL "$core_pid" 2>/dev/null || true
  wait "$core_pid" 2>/dev/null || true
  core_pid=''
  fail "packaged POS Core did not terminate within 10 seconds of SIGTERM"
}

post_json() {
  curl --silent --show-error --fail-with-body \
    --header 'Content-Type: application/json' \
    --data "$2" \
    "$base_url$1"
}

start_core

health="$(curl --silent --show-error --fail "$base_url/health")"
jq -e '.ok == true and .service == "grocery-pos-core"' <<<"$health" >/dev/null ||
  fail "packaged /health response is invalid"

shift="$(post_json '/shifts/open' '{"cashier_id":"cashier-development-01","opening_cash_minor_units":10000}')"
jq -e '.ok == true and (.shift.shift_id | type == "string")' <<<"$shift" >/dev/null ||
  fail "packaged shift-open API failed"

started="$(post_json '/transaction-commands' '{"schema_version":1,"command_id":"cmd-package-start","transaction_id":"txn-package-restart","expected_version":0,"command_type":"start_transaction","payload":{}}')"
jq -e '.ok == true and .command_result.outcome_kind == "accepted"' <<<"$started" >/dev/null ||
  fail "packaged transaction start failed"

scanned="$(post_json '/transaction-commands' '{"schema_version":1,"command_id":"cmd-package-scan","transaction_id":"txn-package-restart","expected_version":1,"command_type":"scan_barcode","payload":{"barcode":"049000001234"}}')"
jq -e '.ok == true and .command_result.outcome_kind == "accepted"' <<<"$scanned" >/dev/null ||
  fail "packaged transaction scan failed"

stop_core_with_sigterm
start_core

recovered="$(curl --silent --show-error --fail "$base_url/transactions/txn-package-restart")"
jq -e '.ok == true and .transaction.status == "open" and .transaction.version == 2 and (.transaction.line_items | length) == 1 and .transaction.total_minor_units == 219' \
  <<<"$recovered" >/dev/null ||
  fail "durable packaged transaction was not recovered after restart"

stop_core_with_sigterm

info="$(run_packaged_script database-maintenance.rkt info "$database_path")"
jq -e '.ok == true and .migrations.status == "current"' <<<"$info" >/dev/null ||
  fail "packaged database inspection failed"
quick="$(run_packaged_script database-maintenance.rkt quick-check "$database_path")"
jq -e '.ok == true and .healthy == true' <<<"$quick" >/dev/null ||
  fail "packaged quick check failed"
integrity="$(run_packaged_script database-maintenance.rkt integrity-check "$database_path")"
jq -e '.ok == true and .healthy == true and .foreign_key_violation_count == 0' \
  <<<"$integrity" >/dev/null ||
  fail "packaged integrity check failed"
run_packaged_script database-maintenance.rkt backup \
  "$database_path" "$backup_path" >/dev/null
validation="$(run_packaged_script database-maintenance.rkt backup-validate "$backup_path")"
jq -e '.ok == true and .valid == true and .migration_status == "current"' \
  <<<"$validation" >/dev/null ||
  fail "packaged backup validation failed"

# The packaged low-level recovery path operates on temporary state and does
# not pretend to coordinate the host systemd service.
run_packaged_script catalog.rkt activate \
  "$repository_root/pos-backend-racket/fixtures/development/catalog-snapshot-v2.json" \
  "$restore_target_path" >/dev/null
restore_result="$(run_packaged_script database-recovery.rkt restore-offline \
  "$backup_path" "$restore_target_path")"
jq -e '.ok == true and .operation == "restore_offline" and .restored_schema_version == 7' \
  <<<"$restore_result" >/dev/null ||
  fail "packaged offline restore failed"
recovery_directory="$(jq -r '.recovery_evidence_directory' <<<"$restore_result")"
[[ -f "$recovery_directory/restored-pos.db" ]] ||
  fail "packaged offline restore did not preserve displaced state"

database_path="$restore_target_path"
start_core
restored_transaction="$(curl --silent --show-error --fail \
  "$base_url/transactions/txn-package-restart")"
jq -e '.ok == true and .transaction.status == "open" and .transaction.version == 2' \
  <<<"$restored_transaction" >/dev/null ||
  fail "packaged POS Core did not recover restored durable state"
stop_core_with_sigterm

support_result="$(run_packaged_script support-diagnostics.rkt collect \
  "$database_path" "$support_bundle_path")"
jq -e '.ok == true and .support_bundle_schema_version == 1' \
  <<<"$support_result" >/dev/null ||
  fail "packaged support bundle collection failed"
mkdir -p "$support_extract_path"
tar -xzf "$support_bundle_path" -C "$support_extract_path"
mapfile -t support_members < <(find "$support_extract_path" -maxdepth 1 -type f \
  -printf '%f\n' | sort)
expected_support_members=(
  api.json database.json manifest.json package.json platform.json service.json storage.json
)
[[ "${support_members[*]}" == "${expected_support_members[*]}" ]] ||
  fail "packaged support bundle contains an unexpected member set"
if grep -R -a -F 'txn-package-restart' "$support_extract_path" >/dev/null; then
  fail "packaged support bundle leaked authoritative transaction data"
fi
if find "$support_extract_path" -type f \
  \( -name '*.db' -o -name '*.sqlite' -o -name '*-wal' -o -name '*-shm' -o -name '*-journal' \) \
  -print -quit | grep -q .; then
  fail "packaged support bundle contains SQLite state"
fi

printf '%s\n' 'Packaged POS Core startup, restart, maintenance, restore, and privacy checks passed.'
