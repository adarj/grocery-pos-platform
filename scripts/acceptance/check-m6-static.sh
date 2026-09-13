#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repository_root"

fail() {
  printf 'm6-static-audit-failed: %s\n' "$*" >&2
  exit 1
}

require_literal() {
  local file="$1"
  local literal="$2"
  rg -Fq -- "$literal" "$file" ||
    fail "$file is missing required contract: $literal"
}

reject_pattern() {
  local pattern="$1"
  shift
  if rg -n --glob '!tests/**' --glob '!integration/**' \
      --glob '!docs/**' --glob '!scripts/acceptance/check-m6-static.sh' \
      "$pattern" "$@" >/dev/null; then
    fail "forbidden production pattern '$pattern' found under $*"
  fi
}

# Every production sqlite3-connect call must be either the centralized
# production policy boundary or the dedicated read-only inspection boundary.
mapfile -t raw_sqlite_files < <(
  rg -l 'sqlite3-connect' pos-backend-racket/pos --glob '*.rkt' | sort
)
expected_sqlite_files=(
  pos-backend-racket/pos/persistence/sqlite-connection.rkt
  pos-backend-racket/pos/persistence/sqlite-maintenance.rkt
)
if [[ "${raw_sqlite_files[*]}" != "${expected_sqlite_files[*]}" ]]; then
  printf 'observed raw SQLite files:\n' >&2
  printf '  %s\n' "${raw_sqlite_files[@]}" >&2
  fail 'production raw SQLite connection classification changed'
fi

reject_pattern 'PRAGMA[[:space:]]+busy_timeout|busy_timeout' \
  pos-backend-racket/pos
reject_pattern 'RACKET_API_ALLOW_REMOTE' .

connection=pos-backend-racket/pos/persistence/sqlite-connection.rkt
require_literal "$connection" '"PRAGMA journal_mode = WAL"'
require_literal "$connection" '"PRAGMA synchronous = FULL"'
require_literal "$connection" '"PRAGMA foreign_keys = ON"'
require_literal "$connection" '(define pos-sqlite-wal-autocheckpoint-pages 1000)'
require_literal "$connection" '(define pos-sqlite-busy-retry-limit 10)'
require_literal "$connection" '(define pos-sqlite-busy-retry-delay 0.1)'

runtime_config=pos-backend-racket/pos/runtime-config.rkt
require_literal "$runtime_config" '(string=? value "127.0.0.1")'
require_literal "$runtime_config" '(string=? value "::1")'

http_safety=pos-backend-racket/pos/api/http-safety.rkt
require_literal "$http_safety" '(define pos-http-max-concurrent 64)'
require_literal "$http_safety" '(define pos-http-max-waiting 64)'
require_literal "$http_safety" '(define pos-http-request-read-timeout-seconds 10)'
require_literal "$http_safety" '(define pos-http-max-request-body-bytes (* 64 1024))'
require_literal "$http_safety" '(define pos-http-response-timeout-seconds 30)'
require_literal "$http_safety" '(define pos-http-response-send-timeout-seconds 10)'
require_literal pos-backend-racket/pos/api/server.rkt \
  '#:safety-limits pos-http-safety-limits'

migrations=pos-backend-racket/pos/persistence/pos-database-migrations.rkt
mapfile -t migration_versions < <(
  sed -nE 's/^[[:space:]]*\(pos-database-migration ([0-9]+)$/\1/p' \
    "$migrations"
)
[[ "${migration_versions[*]}" == '1 2 3 4 5 6' ]] ||
  fail "migration history is not exactly v1-v6: ${migration_versions[*]}"

service=packaging/fedora/grocery-pos-core.service
for contract in \
  'AssertFileNotEmpty=/var/lib/grocery-pos/pos.db' \
  'User=grocery-pos' \
  'Group=grocery-pos' \
  'StateDirectory=grocery-pos' \
  'RuntimeDirectory=grocery-pos' \
  'Restart=on-failure' \
  'ProtectSystem=strict'; do
  require_literal "$service" "$contract"
done
if rg -Fq 'PrivateNetwork=yes' "$service"; then
  fail 'POS Core service would isolate the host loopback API'
fi
if rg -Fq 'MemoryDenyWriteExecute=yes' "$service"; then
  fail 'unqualified Racket JIT hardening was enabled'
fi

flatpak_metadata=packaging/flatpak/com.grocerypos.pos_terminal.metadata
require_literal "$flatpak_metadata" 'shared=network;'
require_literal "$flatpak_metadata" 'sockets=wayland;'
require_literal "$flatpak_metadata" 'devices=dri;'
if rg -qi 'filesystems=|host|home|devices=.*all|sockets=.*x11|system-talks|session-bus' \
    "$flatpak_metadata"; then
  fail 'cashier Flatpak gained a broad filesystem/device/X11/D-Bus permission'
fi

if rg -n 'sqlite3|pos\.db|/var/lib/grocery-pos' \
    flutter/apps/pos_terminal/lib >/dev/null; then
  fail 'Flutter production code references authoritative SQLite state directly'
fi

support=pos-backend-racket/pos/support/support-bundle.rkt
if rg -n 'quick-check-pos|integrity-check-pos|PRAGMA[[:space:]]+(quick_check|integrity_check)' \
    "$support" >/dev/null; then
  fail 'ordinary support collection gained an integrity scan'
fi

for spec in packaging/fedora/grocery-pos-core.spec \
            packaging/fedora/grocery-pos-appliance.spec; do
  if rg -n '^%(pre|post|preun|postun|posttrans)([[:space:]]|$)' "$spec" >/dev/null; then
    fail "$spec gained an RPM mutation scriptlet"
  fi
done

printf '%s\n' \
  'm6-static-audit-passed: production SQLite, migrations, HTTP, service, Flatpak, and package boundaries match the frozen M6 contract'
