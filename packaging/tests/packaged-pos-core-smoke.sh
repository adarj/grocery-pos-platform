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
access_token=''
test_operator_id='cashier-development-01'
test_operator_pin='80421637'

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

# Enroll the already configured cashier through the packaged production
# operator service. The PIN is sent over stdin and is never placed in argv.
TEST_DB_PATH="$database_path" TEST_PAYLOAD_ROOT="$payload_root" racket -e \
  '(require db)
   (define payload (string->path (getenv "TEST_PAYLOAD_ROOT")))
   (define operator-module (build-path payload "pos/application/operator-service.rkt"))
   (define sqlite-module (build-path payload "pos/persistence/sqlite-connection.rkt"))
   (define migration-module (build-path payload "pos/persistence/pos-database-migrations.rkt"))
   (define open-pos (dynamic-require sqlite-module (quote open-pos-sqlite-connection)))
   (define validate (dynamic-require migration-module (quote validate-pos-database-schema!)))
   (define make-service (dynamic-require operator-module (quote make-operator-service)))
   (define create (dynamic-require operator-module (quote operator-service-create)))
   (define enroll (dynamic-require operator-module (quote operator-service-enroll-pin)))
   (define succeeded? (dynamic-require operator-module (quote operator-pin-enrollment-succeeded?)))
   (define pin (read-line))
   (define connection (open-pos (getenv "TEST_DB_PATH") (quote read/write)))
   (dynamic-wind
     void
     (lambda ()
       (validate connection #:require-current? #t)
       (define service (make-service connection))
       (unless (succeeded? (enroll service "cashier-development-01" pin))
         (error (quote packaged-auth-smoke) "cashier credential enrollment failed"))
       (create service "package-supervisor" "Package Supervisor" (quote supervisor))
       (unless (succeeded? (enroll service "package-supervisor" pin))
         (error (quote packaged-auth-smoke) "supervisor credential enrollment failed")))
     (lambda () (disconnect connection)))' <<<"$test_operator_pin"

PIN_MODULE="$payload_root/pos/security/operator-pin.rkt" racket -e \
  '(define module-path (string->path (getenv "PIN_MODULE")))
   (define hash-pin (dynamic-require module-path (quote hash-operator-pin)))
   (define verify-pin (dynamic-require module-path (quote verify-operator-pin)))
   (define pin (read-line))
   (define verifier (hash-pin pin))
   (define wrong-pin
     (string-append (substring pin 0 (sub1 (string-length pin)))
                    (if (char=? (string-ref pin (sub1 (string-length pin))) #\0)
                        "1" "0")))
   (unless (and (string-prefix? verifier "$argon2id$")
                (verify-pin pin verifier)
                (not (verify-pin wrong-pin verifier)))
     (error (quote packaged-auth-smoke) "Argon2id credential round trip failed"))' \
  <<<"$test_operator_pin"

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
      jq -e '.ok == true and .status == "ready" and .database_schema_version == 12' \
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

auth_curl() {
  local token="$1"
  shift
  curl --config <(printf 'header = "Authorization: Bearer %s"\n' "$token") "$@"
}

post_json() {
  auth_curl "$access_token" --silent --show-error --fail-with-body \
    --header 'Content-Type: application/json' \
    --data-binary @- \
    "$base_url$1" <<<"$2"
}

login_core() {
  local login
  login="$(curl --silent --show-error --fail-with-body \
    --header 'Content-Type: application/json' \
    --data-binary @- \
    "$base_url/auth/login" \
    <<<"$(printf '{\"operator_id\":\"%s\",\"pin\":\"%s\"}' \
           "$test_operator_id" "$test_operator_pin")")"
  jq -e '.ok == true and .token_type == "Bearer" and
    .session.operator_id == "cashier-development-01"' \
    <<<"$login" >/dev/null || fail "packaged authentication failed"
  access_token="$(jq -r '.access_token' <<<"$login")"
}

start_core

health="$(curl --silent --show-error --fail "$base_url/health")"
jq -e '.ok == true and .service == "grocery-pos-core"' <<<"$health" >/dev/null ||
  fail "packaged /health response is invalid"

anonymous_status="$(curl --silent --output /dev/null --write-out '%{http_code}' \
  "$base_url/register-context")"
[[ "$anonymous_status" == '401' ]] ||
  fail "packaged business API accepted an anonymous request"
login_core

shift="$(post_json '/shifts/open' '{"opening_cash_minor_units":10000}')"
jq -e '.ok == true and (.shift.shift_id | type == "string")' <<<"$shift" >/dev/null ||
  fail "packaged shift-open API failed"

started="$(post_json '/transaction-commands' '{"schema_version":1,"command_id":"cmd-package-start","transaction_id":"txn-package-restart","expected_version":0,"command_type":"start_transaction","payload":{}}')"
jq -e '.ok == true and .command_result.outcome_kind == "accepted"' <<<"$started" >/dev/null ||
  fail "packaged transaction start failed"

scanned="$(post_json '/transaction-commands' '{"schema_version":1,"command_id":"cmd-package-scan","transaction_id":"txn-package-restart","expected_version":1,"command_type":"scan_barcode","payload":{"barcode":"049000001234"}}')"
jq -e '.ok == true and .command_result.outcome_kind == "accepted"' <<<"$scanned" >/dev/null ||
  fail "packaged transaction scan failed"

stop_core_with_sigterm
old_access_token="$access_token"
start_core

stale_response="$work_root/stale-session.json"
stale_status="$(auth_curl "$old_access_token" --silent --output "$stale_response" --write-out '%{http_code}' \
  "$base_url/transactions/txn-package-restart")"
[[ "$stale_status" == '401' ]] &&
  jq -e '.ok == false and .error.code == "authentication_required"' \
    "$stale_response" >/dev/null ||
  fail "packaged POS Core restart did not invalidate the old session"
login_core

recovered="$(auth_curl "$access_token" --silent --show-error --fail \
  "$base_url/transactions/txn-package-restart")"
jq -e '.ok == true and .transaction.status == "open" and .transaction.version == 2 and (.transaction.line_items | length) == 1 and .transaction.total_minor_units == 219' \
  <<<"$recovered" >/dev/null ||
  fail "durable packaged transaction was not recovered after restart"

tendered="$(post_json '/transaction-commands' '{"schema_version":1,"command_id":"cmd-package-tender","transaction_id":"txn-package-restart","expected_version":2,"command_type":"tender_cash","payload":{"amount_minor_units":500}}')"
jq -e '.ok == true and .command_result.outcome_kind == "accepted"' <<<"$tendered" >/dev/null ||
  fail "packaged cash tender failed"
completed="$(post_json '/transaction-commands' '{"schema_version":1,"command_id":"cmd-package-complete","transaction_id":"txn-package-restart","expected_version":3,"command_type":"complete_transaction","payload":{}}')"
jq -e '.ok == true and .command_result.outcome_kind == "accepted"' <<<"$completed" >/dev/null ||
  fail "packaged sale completion failed"

void_start="$(post_json '/transaction-commands' '{"schema_version":1,"command_id":"cmd-package-void-start","transaction_id":"txn-package-void","expected_version":0,"command_type":"start_transaction","payload":{}}')"
jq -e '.ok == true and .command_result.outcome_kind == "accepted"' <<<"$void_start" >/dev/null ||
  fail "packaged void-sale start failed"
void_scan="$(post_json '/transaction-commands' '{"schema_version":1,"command_id":"cmd-package-void-scan","transaction_id":"txn-package-void","expected_version":1,"command_type":"scan_barcode","payload":{"barcode":"049000001234"}}')"
jq -e '.ok == true and .command_result.outcome_kind == "accepted"' <<<"$void_scan" >/dev/null ||
  fail "packaged void-sale scan failed"
void_command='{"schema_version":1,"command_id":"cmd-package-void","transaction_id":"txn-package-void","expected_version":2,"command_type":"void_transaction","payload":{}}'
approval="$(post_json '/approvals/transaction-void' \
  "$(printf '{\"command\":%s,\"approver_operator_id\":\"package-supervisor\",\"approver_pin\":\"%s\"}' \
           "$void_command" "$test_operator_pin")")"
jq -e '.ok == true and .approval.approver_operator_id == "package-supervisor" and (.approval.approval_token | startswith("gpos_a1_"))' \
  <<<"$approval" >/dev/null || fail "packaged scoped approval failed"
approval_token="$(jq -r '.approval.approval_token' <<<"$approval")"
unset approval
approved_void="$(curl --silent --show-error --fail-with-body \
  --config <(printf 'header = "Authorization: Bearer %s"\nheader = "X-Grocery-POS-Approval: %s"\n' \
                    "$access_token" "$approval_token") \
  --header 'Content-Type: application/json' \
  --data-binary "$void_command" "$base_url/transaction-commands")"
unset approval_token
jq -e '.ok == true and .command_result.outcome_kind == "accepted"' \
  <<<"$approved_void" >/dev/null || fail "packaged approved void failed"
void_retry="$(post_json '/transaction-commands' "$void_command")"
jq -e '.ok == true and .command_result.outcome_kind == "accepted"' \
  <<<"$void_retry" >/dev/null || fail "packaged exact void retry required new approval"

stop_core_with_sigterm

audit_verify="$(TEST_DB_PATH="$database_path" TEST_PAYLOAD_ROOT="$payload_root" racket -e \
  '(define script (build-path (string->path (getenv "TEST_PAYLOAD_ROOT"))
                              "scripts/security-audit.rkt"))
   (define run-audit (dynamic-require script (quote run-security-audit-cli)))
   (unless (zero? (run-audit (vector "verify")
                             #:database-path (getenv "TEST_DB_PATH")
                             #:effective-user-id (lambda () 0)))
     (exit 1))')"
jq -e '.ok == true and .status == "valid" and .event_count >= 4' \
  <<<"$audit_verify" >/dev/null ||
  fail "packaged root audit verification failed"

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
jq -e '.ok == true and .operation == "restore_offline" and .restored_schema_version == 12' \
  <<<"$restore_result" >/dev/null ||
  fail "packaged offline restore failed"
recovery_directory="$(jq -r '.recovery_evidence_directory' <<<"$restore_result")"
[[ -f "$recovery_directory/restored-pos.db" ]] ||
  fail "packaged offline restore did not preserve displaced state"

database_path="$restore_target_path"
start_core
login_core
restored_transaction="$(auth_curl "$access_token" --silent --show-error --fail \
  "$base_url/transactions/txn-package-restart")"
jq -e '.ok == true and .transaction.status == "completed" and .transaction.version == 4' \
  <<<"$restored_transaction" >/dev/null ||
  fail "packaged POS Core did not recover restored durable state"
stop_core_with_sigterm

auth_status="$(TEST_DB_PATH="$database_path" TEST_PAYLOAD_ROOT="$payload_root" racket -e \
  '(define script (build-path (string->path (getenv "TEST_PAYLOAD_ROOT"))
                              "scripts/operator-auth.rkt"))
   (define run-auth (dynamic-require script (quote run-operator-auth-cli)))
   (unless (zero? (run-auth (vector "status")
                            #:database-path (getenv "TEST_DB_PATH")
                            #:effective-user-id (lambda () 0)))
     (exit 1))')"
jq -e '.ok == true and .schema_version == 12 and
  .register_operator_ready_count >= 1 and .audit_event_count >= 1' \
  <<<"$auth_status" >/dev/null ||
  fail "packaged root authentication status failed"

reset_result="$(TEST_DB_PATH="$database_path" TEST_PAYLOAD_ROOT="$payload_root" racket -e \
  '(define script (build-path (string->path (getenv "TEST_PAYLOAD_ROOT"))
                              "scripts/operator-auth.rkt"))
   (define run-auth (dynamic-require script (quote run-operator-auth-cli)))
   (unless (zero? (run-auth (vector "operator" "reset-pin" "cashier-development-01")
                            #:database-path (getenv "TEST_DB_PATH")
                            #:effective-user-id (lambda () 0)))
     (exit 1))' <<<"48295173")"
jq -e '.ok == true and .operation == "operator_reset_pin" and
  .credential_revision == 2' <<<"$reset_result" >/dev/null ||
  fail "packaged root PIN reset failed"

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
