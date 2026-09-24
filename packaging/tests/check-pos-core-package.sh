#!/usr/bin/env bash

set -euo pipefail

fail() {
  printf 'package-contract-failed: %s\n' "$*" >&2
  exit 1
}

if [[ $# -ne 2 ]]; then
  fail "usage: check-pos-core-package.sh RPM-OR-DIRECTORY REPOSITORY-ROOT"
fi

rpm_input="$1"
repository_root="$2"

[[ -e "$rpm_input" ]] || fail "RPM artifact does not exist: $rpm_input"
rpm_input="$(realpath -- "$rpm_input")"

if [[ -d "$rpm_input" ]]; then
  mapfile -t rpm_candidates < <(find "$rpm_input" -maxdepth 1 -type f -name '*.rpm' -print | sort)
  [[ ${#rpm_candidates[@]} -eq 1 ]] ||
    fail "expected exactly one RPM artifact under $rpm_input"
  rpm_path="${rpm_candidates[0]}"
elif [[ -f "$rpm_input" ]]; then
  rpm_path="$rpm_input"
else
  fail "RPM input is neither a file nor a directory: $rpm_input"
fi

[[ "$(rpm -qp --queryformat '%{NAME}' "$rpm_path")" == "grocery-pos-core" ]] ||
  fail "unexpected RPM package name"
[[ "$(rpm -qp --queryformat '%{VERSION}' "$rpm_path")" == "0.0.0" ]] ||
  fail "unexpected internal RPM version"
[[ "$(rpm -qp --queryformat '%{RELEASE}' "$rpm_path")" == "0.8.dev" ]] ||
  fail "unexpected internal RPM release"
[[ "$(rpm -qp --queryformat '%{ARCH}' "$rpm_path")" == "noarch" ]] ||
  fail "RPM architecture is not noarch"
[[ "$(rpm -qp --queryformat '%{LICENSE}' "$rpm_path")" == "LicenseRef-Project-Undecided" ]] ||
  fail "RPM license metadata does not preserve the undecided project status"

rpm_requires="$(rpm -qp --requires "$rpm_path")"
grep -Eq '^racket([[:space:]]|$)' <<<"$rpm_requires" ||
  fail "RPM does not require Fedora's racket package"
grep -Eq '^racket-pkgs([[:space:]]|$)' <<<"$rpm_requires" ||
  fail "RPM does not require Fedora's standard Racket collections"
grep -Eq '^libargon2([[:space:]]|$)' <<<"$rpm_requires" ||
  fail "RPM does not require Fedora's Argon2 runtime library"
grep -Eq '^coreutils([[:space:]]|$)' <<<"$rpm_requires" ||
  fail "RPM does not require the file utilities used by recovery diagnostics"
grep -Eq '^systemd([[:space:]]|$)' <<<"$rpm_requires" ||
  fail "RPM does not require the service manager used by appliance recovery"
if grep -Eqi '(^|[[:space:]])(nix|nix-daemon)([[:space:]]|$)|/nix/store' <<<"$rpm_requires"; then
  fail "RPM has a Nix runtime dependency"
fi

rpm_provides="$(rpm -qp --provides "$rpm_path")"
grep -Eq '^user\(grocery-pos\)([[:space:]]|$)' <<<"$rpm_provides" ||
  fail "RPM does not declare the grocery-pos system user"
grep -Eq '^group\(grocery-pos\)([[:space:]]|$)' <<<"$rpm_provides" ||
  fail "RPM does not declare the grocery-pos system group"

rpm_sysusers="$(rpm -qp --queryformat '[%{SYSUSERS}\n]' "$rpm_path")"
grep -Fqx 'g grocery-pos - -' <<<"$rpm_sysusers" ||
  fail "RPM does not encode the grocery-pos sysusers group"
grep -Fqx 'u grocery-pos - "Grocery POS Core service" /var/lib/grocery-pos /usr/sbin/nologin' \
  <<<"$rpm_sysusers" ||
  fail "RPM does not encode the grocery-pos sysusers user"

extract_root="$(mktemp -d)"
trap 'rm -rf -- "$extract_root"' EXIT
rpm2cpio "$rpm_path" | (cd "$extract_root" && cpio -idm --quiet)

payload_root="$extract_root/usr/libexec/grocery-pos-core"
unit="$extract_root/usr/lib/systemd/system/grocery-pos-core.service"
sysusers="$extract_root/usr/lib/sysusers.d/grocery-pos.conf"
environment_file="$extract_root/etc/grocery-pos/pos-core.env"

required_files=(
  "$payload_root/main.rkt"
  "$payload_root/pos/runtime.rkt"
  "$payload_root/pos/api/server.rkt"
  "$payload_root/pos/api/auth-http.rkt"
  "$payload_root/pos/api/approval-http.rkt"
  "$payload_root/pos/application/authentication-service.rkt"
  "$payload_root/pos/application/transaction-void-approval-service.rkt"
  "$payload_root/pos/application/security-audit-service.rkt"
  "$payload_root/pos/domain/security-audit-event.rkt"
  "$payload_root/pos/persistence/security-audit-event-codec.rkt"
  "$payload_root/pos/persistence/security-audit-store.rkt"
  "$payload_root/pos/persistence/sqlite-connection.rkt"
  "$payload_root/pos/persistence/sqlite-maintenance.rkt"
  "$payload_root/pos/persistence/atomic-file.rkt"
  "$payload_root/pos/persistence/sqlite-restore.rkt"
  "$payload_root/pos/persistence/sqlite-operators.rkt"
  "$payload_root/pos/persistence/sqlite-authentication.rkt"
  "$payload_root/pos/persistence/sqlite-auth-throttle.rkt"
  "$payload_root/pos/domain/operator-identity.rkt"
  "$payload_root/pos/security/operator-pin.rkt"
  "$payload_root/pos/security/operator-session.rkt"
  "$payload_root/pos/security/authorization-policy.rkt"
  "$payload_root/pos/security/transaction-void-approval.rkt"
  "$payload_root/pos/domain/transaction-command-actor-attribution.rkt"
  "$payload_root/pos/domain/transaction-void-approval.rkt"
  "$payload_root/pos/persistence/transaction-command-actor-attribution-store.rkt"
  "$payload_root/pos/persistence/transaction-void-approval-store.rkt"
  "$payload_root/pos/application/operator-service.rkt"
  "$payload_root/pos/support/appliance-recovery.rkt"
  "$payload_root/pos/support/support-bundle.rkt"
  "$payload_root/pos/support/appliance-provisioning.rkt"
  "$payload_root/scripts/database-maintenance.rkt"
  "$payload_root/scripts/database-recovery.rkt"
  "$payload_root/scripts/support-diagnostics.rkt"
  "$payload_root/scripts/appliance.rkt"
  "$payload_root/scripts/operator-auth.rkt"
  "$payload_root/scripts/security-audit.rkt"
  "$payload_root/scripts/catalog.rkt"
  "$payload_root/scripts/register-configuration.rkt"
  "$payload_root/run-pos-core"
  "$unit"
  "$sysusers"
  "$environment_file"
  "$extract_root/usr/bin/grocery-pos-db"
  "$extract_root/usr/bin/grocery-pos-catalog"
  "$extract_root/usr/bin/grocery-pos-register-config"
  "$extract_root/usr/bin/grocery-pos-recovery"
  "$extract_root/usr/bin/grocery-pos-support"
  "$extract_root/usr/bin/grocery-pos-auth"
  "$extract_root/usr/bin/grocery-pos-audit"
  "$payload_root/vendor/racket/collects/crypto/main.rkt"
  "$payload_root/vendor/racket/collects/crypto/argon2.rkt"
  "$payload_root/vendor/racket/collects/asn1/main.rkt"
  "$payload_root/vendor/racket/collects/hash-view/main.rkt"
  "$payload_root/vendor/racket/collects/base64/main.rkt"
  "$payload_root/vendor/racket/collects/binaryio/main.rkt"
  "$payload_root/vendor/racket/collects/gmp/main.rkt"
  "$payload_root/vendor/racket/collects/scramble/struct-info.rkt"
  "$payload_root/vendor/racket/crypto-sources.json"
)
for path in "${required_files[@]}"; do
  [[ -f "$path" ]] || fail "required packaged file is missing: $path"
done

crypto_sources="$payload_root/vendor/racket/crypto-sources.json"
jq -e '
  .schema_version == 1 and
  (.collections | length) == 7 and
  ([.collections[].name] | sort) ==
    (["asn1-lib", "base64-lib", "binaryio-lib", "crypto-lib",
      "gmp-lib", "hash-view-lib", "scramble-lib"] | sort) and
  ([.collections[] | select(
      (.revision | test("^[0-9a-f]{40}$") | not) or
      (.sha256 | startswith("sha256-") | not) or
      (.license | length) == 0)] | length) == 0
' "$crypto_sources" >/dev/null ||
  fail "packaged Racket crypto provenance is incomplete"
while IFS=$'\t' read -r revision sha256; do
  grep -Fq "$revision" "$repository_root/flake.nix" ||
    fail "packaged crypto revision is not pinned by the flake: $revision"
  grep -Fq "$sha256" "$repository_root/flake.nix" ||
    fail "packaged crypto hash is not pinned by the flake: $sha256"
done < <(jq -r '.collections[] | [.revision, .sha256] | @tsv' "$crypto_sources")

[[ ! -e "$payload_root/tests" ]] || fail "Racket tests were packaged"
[[ ! -e "$payload_root/fixtures" ]] || fail "development fixtures were packaged"
[[ ! -e "$payload_root/pos/domain/fake-catalog.rkt" ]] ||
  fail "test-only fake catalog was packaged"
[[ ! -e "$extract_root/.git" ]] || fail "source-control metadata was packaged"
[[ ! -e "$extract_root/.local" ]] || fail "development local state was packaged"
if find "$payload_root/pos" "$payload_root/scripts" \
  -type f ! -name '*.rkt' -print -quit | grep -q .; then
  fail "non-source development artifact was packaged with Racket modules"
fi

rpm_files="$(rpm -qpl "$rpm_path")"
if rpm -qp --dump "$rpm_path" |
  awk '$1 ~ "^/(etc/grocery-pos|usr/bin/grocery-pos-|usr/libexec/grocery-pos-core|usr/lib/systemd/system/grocery-pos-core.service|usr/lib/sysusers.d/grocery-pos.conf)" && ($6 != "root" || $7 != "root") { exit 1 }'; then
  :
else
  fail "immutable application/configuration payload is not root-owned"
fi
if grep -Eq '^/var/lib/grocery-pos(/|$)|^/run/grocery-pos(/|$)|^/var/log/grocery-pos(/|$)' <<<"$rpm_files"; then
  fail "RPM payload creates mutable runtime, state, or log content"
fi
if grep -R -a -F -l '/nix/store/' "$extract_root" >/dev/null; then
  fail "installed payload contains a /nix/store reference"
fi
if grep -R -a -E -l 'GROCERY_POS_DISABLE_AUTH|GROCERY_POS_AUTH_BYPASS' \
  "$payload_root" >/dev/null; then
  fail "installed payload contains an authentication bypass switch"
fi
if grep -R -a -E -l 'CREATE TABLE[^;]*(bearer|operator)_sessions' \
  "$payload_root/pos" >/dev/null; then
  fail "installed payload persists bearer sessions in SQLite"
fi
if grep -E -- '--pin([=[:space:]]|$)' \
  "$extract_root/usr/bin/grocery-pos-auth" \
  "$payload_root/scripts/operator-auth.rkt" >/dev/null; then
  fail "installed operator administration accepts a PIN through argv"
fi

require_unit_line() {
  grep -Fqx "$1" "$unit" || fail "systemd unit is missing: $1"
}

unit_lines=(
  'After=local-fs.target'
  'StartLimitIntervalSec=60s'
  'StartLimitBurst=3'
  'AssertFileNotEmpty=/var/lib/grocery-pos/pos.db'
  'Type=exec'
  'User=grocery-pos'
  'Group=grocery-pos'
  'WorkingDirectory=/var/lib/grocery-pos'
  'EnvironmentFile=/etc/grocery-pos/pos-core.env'
  'ExecStart=/usr/libexec/grocery-pos-core/run-pos-core'
  'StateDirectory=grocery-pos'
  'StateDirectoryMode=0750'
  'RuntimeDirectory=grocery-pos'
  'RuntimeDirectoryMode=0750'
  'UMask=0027'
  'Restart=on-failure'
  'RestartSec=5s'
  'TimeoutStopSec=30s'
  'KillSignal=SIGTERM'
  'StandardOutput=journal'
  'StandardError=journal'
  'SyslogIdentifier=grocery-pos-core'
  'NoNewPrivileges=yes'
  'PrivateTmp=yes'
  'PrivateDevices=yes'
  'ProtectSystem=strict'
  'ProtectHome=yes'
  'ProtectControlGroups=yes'
  'ProtectKernelTunables=yes'
  'ProtectKernelModules=yes'
  'ProtectKernelLogs=yes'
  'ProtectClock=yes'
  'ProtectHostname=yes'
  'RestrictSUIDSGID=yes'
  'RestrictRealtime=yes'
  'LockPersonality=yes'
  'CapabilityBoundingSet='
  'AmbientCapabilities='
  'RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6'
  'SystemCallArchitectures=native'
  'WantedBy=multi-user.target'
)
for line in "${unit_lines[@]}"; do
  require_unit_line "$line"
done

grep -Fqx 'PrivateNetwork=yes' "$unit" &&
  fail "PrivateNetwork=yes would break the loopback client topology"
grep -Fqx 'MemoryDenyWriteExecute=yes' "$unit" &&
  fail "MemoryDenyWriteExecute was enabled without Racket qualification"
grep -Eq '^ReadWritePaths=/$' "$unit" &&
  fail "service was granted broad writable filesystem access"

grep -Fqx 'GROCERY_POS_ENV=production' "$environment_file" ||
  fail "production environment is not configured"
grep -Fqx 'RACKET_API_HOST=127.0.0.1' "$environment_file" ||
  fail "service API does not default to IPv4 loopback"
grep -Fqx 'RACKET_API_PORT=7340' "$environment_file" ||
  fail "service API port is not configured"
if grep -Eq '^SQLITE_DB_PATH=' "$environment_file"; then
  fail "editable environment file may redirect the authoritative database"
fi

grep -Fqx 'SQLITE_DB_PATH=/var/lib/grocery-pos/pos.db' "$payload_root/run-pos-core" ||
  fail "service launcher does not force the canonical database path"
grep -Fqx 'export SQLITE_DB_PATH' "$payload_root/run-pos-core" ||
  fail "service launcher does not export the canonical database path"
grep -Fqx 'PLTCOLLECTS=/usr/libexec/grocery-pos-core/vendor/racket/collects:' \
  "$payload_root/run-pos-core" ||
  fail "service launcher does not use the packaged Racket crypto collections"
grep -Fqx 'exec /usr/bin/racket /usr/libexec/grocery-pos-core/main.rkt "$@"' "$payload_root/run-pos-core" ||
  fail "service launcher does not execute the packaged entry point"

grep -Fqx 'g grocery-pos - -' "$sysusers" ||
  fail "matching grocery-pos system group is not declared"
grep -Fqx 'u grocery-pos - "Grocery POS Core service" /var/lib/grocery-pos /usr/sbin/nologin' "$sysusers" ||
  fail "grocery-pos system user is not declared without a fixed UID"

[[ "$(stat -c '%a' "$environment_file")" == "644" ]] ||
  fail "machine environment file mode is not 0644"
[[ "$(stat -c '%a' "$payload_root/main.rkt")" == "644" ]] ||
  fail "application source mode is not 0644"
for launcher in \
  "$payload_root/run-pos-core" \
  "$extract_root/usr/bin/grocery-pos-db" \
  "$extract_root/usr/bin/grocery-pos-catalog" \
  "$extract_root/usr/bin/grocery-pos-register-config"; do
  [[ "$(stat -c '%a' "$launcher")" == "755" ]] ||
    fail "launcher mode is not 0755: $launcher"
done

auth_launcher="$extract_root/usr/bin/grocery-pos-auth"
[[ "$(stat -c '%a' "$auth_launcher")" == "755" ]] ||
  fail "auth launcher mode is not 0755"
grep -Fq '/usr/libexec/grocery-pos-core/scripts/operator-auth.rkt' \
  "$auth_launcher" ||
  fail "auth launcher does not use packaged Racket administration code"
grep -Fq '/var/lib/grocery-pos/pos.db' \
  "$payload_root/scripts/operator-auth.rkt" ||
  fail "auth administration code does not fix the appliance database path"
grep -Fq '$(/usr/bin/id -u)' "$auth_launcher" ||
  fail "auth launcher does not enforce the root boundary"
grep -Fq '/usr/bin/stty -echo' "$auth_launcher" ||
  fail "auth launcher does not disable terminal echo for PIN entry"
if grep -Eq -- '--pin|SQLITE_DB_PATH|[[:space:]]PIN([[:space:]]|=)' "$auth_launcher"; then
  fail "auth launcher exposes a PIN argv or database override surface"
fi
audit_launcher="$extract_root/usr/bin/grocery-pos-audit"
[[ "$(stat -c '%a' "$audit_launcher")" == "755" ]] ||
  fail "audit launcher mode is not 0755"
grep -Fq '/usr/libexec/grocery-pos-core/scripts/security-audit.rkt' \
  "$audit_launcher" ||
  fail "audit launcher does not use packaged Racket inspection code"
grep -Fq '$(/usr/bin/id -u)' "$audit_launcher" ||
  fail "audit launcher does not enforce the root boundary"
grep -Fq '/var/lib/grocery-pos/pos.db' \
  "$payload_root/scripts/security-audit.rkt" ||
  fail "audit inspection code does not fix the appliance database path"
if grep -Eq 'SQLITE_DB_PATH|--database' "$audit_launcher"; then
  fail "audit launcher exposes a database override surface"
fi
if grep -R -a -E '\$argon2id\$v=[0-9]+\$m=' \
  "$payload_root/pos" "$payload_root/scripts" >/dev/null; then
  fail "application payload contains a pre-enrolled Argon2id credential"
fi

for launcher in \
  "$extract_root/usr/bin/grocery-pos-recovery" \
  "$extract_root/usr/bin/grocery-pos-support"; do
  [[ "$(stat -c '%a' "$launcher")" == "755" ]] ||
    fail "recovery/support launcher mode is not 0755: $launcher"
done

grep -Fq '/usr/libexec/grocery-pos-core/scripts/database-recovery.rkt' \
  "$extract_root/usr/bin/grocery-pos-recovery" ||
  fail "recovery launcher does not use packaged Racket recovery code"
grep -Fq 'restore-offline' "$extract_root/usr/bin/grocery-pos-recovery" &&
  fail "privileged appliance recovery launcher exposes an arbitrary target"
grep -Fq '/usr/libexec/grocery-pos-core/scripts/support-diagnostics.rkt' \
  "$extract_root/usr/bin/grocery-pos-support" ||
  fail "support launcher does not use packaged Racket diagnostic code"

rpm_scripts="$(rpm -qp --scripts "$rpm_path")"
if grep -Eqi 'systemctl|preset|enable|start|migrate|sqlite' <<<"$rpm_scripts"; then
  fail "RPM scriptlets enable/start the service or mutate the database"
fi

bash "$repository_root/packaging/tests/packaged-pos-core-smoke.sh" \
  "$extract_root" "$repository_root"

printf 'POS Core RPM package contract and lifecycle smoke test passed: %s\n' "$rpm_path"
