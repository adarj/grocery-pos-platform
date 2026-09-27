#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repository_root"

fail() { printf 'm7-static-audit-failed: %s\n' "$*" >&2; exit 1; }
require_literal() { rg -Fq -- "$2" "$1" || fail "$1 lacks required contract: $2"; }
reject() {
  local pattern="$1"; shift
  if rg -n -- "$pattern" "$@"; then fail "forbidden production pattern: $pattern"; fi
}

migrations=pos-backend-racket/pos/persistence/pos-database-migrations.rkt
mapfile -t versions < <(sed -nE 's/^[[:space:]]*\(pos-database-migration ([0-9]+)$/\1/p' "$migrations")
[[ "${versions[*]}" == '1 2 3 4 5 6 7 8 9 10 11 12' ]] ||
  fail "expected exact v1-v12 migration lineage; found ${versions[*]}"
reject 'migration-13-name|pos-database-migration 13' "$migrations"

mapfile -t sqlite_files < <(rg -l 'sqlite3-connect' pos-backend-racket/pos --glob '*.rkt' | sort)
expected=(pos-backend-racket/pos/persistence/sqlite-connection.rkt pos-backend-racket/pos/persistence/sqlite-maintenance.rkt)
[[ "${sqlite_files[*]}" == "${expected[*]}" ]] || fail 'raw SQLite connection locations changed; classify before accepting'
connection=pos-backend-racket/pos/persistence/sqlite-connection.rkt
for literal in '"PRAGMA journal_mode = WAL"' '"PRAGMA synchronous = FULL"' '"PRAGMA foreign_keys = ON"' '(define pos-sqlite-busy-retry-limit 10)'; do
  require_literal "$connection" "$literal"
done
reject 'busy_timeout|RACKET_API_ALLOW_REMOTE' pos-backend-racket/pos
require_literal pos-backend-racket/pos/runtime-config.rkt '(string=? value "127.0.0.1")'
require_literal pos-backend-racket/pos/runtime-config.rkt '(string=? value "::1")'

require_literal pos-backend-racket/pos/security/authorization-policy.rkt 'approval.transaction_void'
require_literal pos-backend-racket/pos/security/authorization-policy.rkt 'transaction.operate.own'
require_literal pos-backend-racket/pos/persistence/security-audit-store.rkt 'verify-security-audit-ledger'
reject 'DELETE FROM security_audit_events|UPDATE security_audit_events|DROP TABLE security_audit_events' \
  pos-backend-racket/pos
require_literal pos-backend-racket/pos/api/server.rkt "(equal? path '(\"auth\" \"change-pin\"))"
require_literal pos-backend-racket/pos/api/server.rkt "(equal? path '(\"approvals\" \"transaction-void\"))"
reject 'equal\? path.*("audit"|"security-events"|"logs")' pos-backend-racket/pos/api
for wrapper in packaging/fedora/grocery-pos-auth packaging/fedora/grocery-pos-audit; do
  [[ -f "$wrapper" ]] || fail "missing root-only wrapper $wrapper"
  require_literal "$wrapper" 'id -u'
done
require_literal packaging/fedora/grocery-pos-auth 'if [ ! -t 0 ]; then'
require_literal packaging/fedora/grocery-pos-auth '/usr/bin/stty -echo'
reject '\-\-pin|PIN=' packaging/fedora/grocery-pos-auth

flatpak=packaging/flatpak/com.grocerypos.pos_terminal.metadata
for literal in 'shared=network;' 'sockets=wayland;' 'devices=dri;'; do require_literal "$flatpak" "$literal"; done
reject 'filesystems=|devices=all|sockets=.*x11|system-talks' "$flatpak"
reject 'sqlite3|pos\.db|/var/lib/grocery-pos' flutter/apps/pos_terminal/lib
reject 'access_token|approval_token|password_hash|credential_revision' \
  flutter/apps/pos_terminal/lib/features/cashier/file_cashier_session_store.dart \
  flutter/apps/pos_terminal/lib/features/cashier/cashier_session_store.dart
reject 'approval|credential_revision|access_token' \
  pos-backend-racket/pos/application/transaction-command.rkt \
  pos-backend-racket/pos/persistence/transaction-command-codec.rkt
reject 'jwt|JWT|master.?pin|default.?pin|hidden.?recovery|delete.operator|delete.pin' \
  pos-backend-racket/pos flutter/apps/pos_terminal/lib packaging/fedora

# Security state is server-owned. Dart may decode server permission identifiers
# for presentation, but must not map local role names to authorization grants.
if rg -n 'role[[:space:]]*==[[:space:]]*["\x27](cashier|supervisor|manager)|switch[[:space:]]*\([^)]*role' flutter/apps/pos_terminal/lib; then
  fail 'Flutter production role-to-permission decision requires review'
fi

require_literal packaging/fedora/grocery-pos-core.service 'User=grocery-pos'
require_literal packaging/fedora/grocery-pos-core.service 'ProtectSystem=strict'
reject '^%(pre|post|preun|postun|posttrans)([[:space:]]|$)' \
  packaging/fedora/grocery-pos-core.spec packaging/fedora/grocery-pos-appliance.spec

# The target observation helper must reject broadened installed permissions,
# not just find the three expected substrings inside a larger permission set.
source packaging/acceptance/qualify-m7-kinoite.sh
narrow_permissions=$'shared=network;\nsockets=wayland;\ndevices=dri;'
m7_flatpak_permissions_valid "$narrow_permissions" || fail 'narrow installed Flatpak fixture rejected'
for extra in 'filesystems=host;' 'sockets=wayland;x11;' 'devices=all;' 'system-talks=org.example;' '[Session Bus Policy]'; do
  if m7_flatpak_permissions_valid "$narrow_permissions"$'\n'"$extra"; then
    fail 'target helper accepted broadened installed Flatpak permissions'
  fi
done

bash scripts/acceptance/m7-runner-test.sh

printf '%s\n' 'm7-static-audit-passed: exact v12 lineage and classified production security boundaries'
