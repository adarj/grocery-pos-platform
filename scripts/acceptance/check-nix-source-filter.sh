#!/usr/bin/env bash
set -euo pipefail
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
raco test "$repository_root/scripts/acceptance/m8-2-source-test.rkt"
scratch="$(mktemp -d /tmp/grocery-pos-source-filter.XXXXXX)"
trap 'rm -rf -- "$scratch"' EXIT
racket "$repository_root/scripts/acceptance/nix-source-snapshot.rkt" "$repository_root" "$scratch/source"
# These are intentionally synthetic regular markers, never real databases/logs.
source_root="$scratch/source"
evaluate() {
  (cd "$source_root" && nix eval --raw "$1" --option warn-dirty false)
}
core_before="$(evaluate 'path:.#packages.aarch64-linux.pos-core-rpm.drvPath')"
terminal_before="$(evaluate 'path:.#packages.x86_64-linux.pos-terminal-flatpak.drvPath')"
mkdir -p "$source_root/.local/acceptance/m8-2" "$source_root/flutter/apps/pos_terminal/.dart_tool"
printf '%s\n' ignored-local-log >"$source_root/.local/acceptance/m8-2/test.log"
printf '%s\n' synthetic-not-a-database >"$source_root/.local/acceptance/m8-2/test.db"
printf '%s\n' ignored-flutter-state >"$source_root/flutter/apps/pos_terminal/.dart_tool/source-filter-marker"
core_after="$(evaluate 'path:.#packages.aarch64-linux.pos-core-rpm.drvPath')"
terminal_after="$(evaluate 'path:.#packages.x86_64-linux.pos-terminal-flatpak.drvPath')"
[[ "$core_before" == "$core_after" ]] || { echo 'POS Core derivation included ignored local state.' >&2; exit 1; }
[[ "$terminal_before" == "$terminal_after" ]] || { echo 'Terminal derivation included ignored local state.' >&2; exit 1; }
# Test source selection with a real ignored UDS while preserving all unrelated
# local daemon sockets. No pathname cleanup outside this owned directory.
cd "$repository_root"
racket scripts/acceptance/m8-2-source-socket.rkt "$scratch/socket-source"
printf '%s\n' 'Nix sources exclude ignored local log/database/Flutter state; Git snapshot excludes live sockets and includes unstaged source without staging.'
