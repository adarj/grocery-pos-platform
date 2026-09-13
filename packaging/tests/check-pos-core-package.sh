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
[[ "$(rpm -qp --queryformat '%{RELEASE}' "$rpm_path")" == "0.3.dev" ]] ||
  fail "unexpected internal RPM release"
[[ "$(rpm -qp --queryformat '%{ARCH}' "$rpm_path")" == "noarch" ]] ||
  fail "RPM architecture is not noarch"
[[ "$(rpm -qp --queryformat '%{LICENSE}' "$rpm_path")" == "LicenseRef-Project-Undecided" ]] ||
  fail "RPM license metadata does not preserve the undecided project status"

rpm_requires="$(rpm -qp --requires "$rpm_path")"
grep -Eq '^racket([[:space:]]|$)' <<<"$rpm_requires" ||
  fail "RPM does not require Fedora's racket package"
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
  "$payload_root/pos/persistence/sqlite-connection.rkt"
  "$payload_root/pos/persistence/sqlite-maintenance.rkt"
  "$payload_root/pos/persistence/atomic-file.rkt"
  "$payload_root/pos/persistence/sqlite-restore.rkt"
  "$payload_root/pos/support/appliance-recovery.rkt"
  "$payload_root/pos/support/support-bundle.rkt"
  "$payload_root/pos/support/appliance-provisioning.rkt"
  "$payload_root/scripts/database-maintenance.rkt"
  "$payload_root/scripts/database-recovery.rkt"
  "$payload_root/scripts/support-diagnostics.rkt"
  "$payload_root/scripts/appliance.rkt"
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
)
for path in "${required_files[@]}"; do
  [[ -f "$path" ]] || fail "required packaged file is missing: $path"
done

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
