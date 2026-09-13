#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
local_marker_directory="$repository_root/.local/acceptance/m6"
flutter_marker_directory="$repository_root/flutter/apps/pos_terminal/.dart_tool"

mkdir -p "$local_marker_directory" "$flutter_marker_directory"
local_marker="$(mktemp "$local_marker_directory/nix-source-filter.XXXXXX")"
flutter_marker="$(mktemp "$flutter_marker_directory/nix-source-filter.XXXXXX")"

cleanup() {
  rm -f -- "$local_marker" "$flutter_marker"
}
trap cleanup EXIT

rm -f -- "$local_marker" "$flutter_marker"

core_before="$(
  nix eval --raw \
    'path:.#packages.aarch64-linux.pos-core-rpm.drvPath' \
    --option warn-dirty false
)"
terminal_before="$(
  nix eval --raw \
    'path:.#packages.x86_64-linux.pos-terminal-flatpak.drvPath' \
    --option warn-dirty false
)"

printf '%s\n' ignored-local-state >"$local_marker"
printf '%s\n' ignored-flutter-state >"$flutter_marker"

core_after="$(
  nix eval --raw \
    'path:.#packages.aarch64-linux.pos-core-rpm.drvPath' \
    --option warn-dirty false
)"
terminal_after="$(
  nix eval --raw \
    'path:.#packages.x86_64-linux.pos-terminal-flatpak.drvPath' \
    --option warn-dirty false
)"

if [[ "$core_before" != "$core_after" ]]; then
  printf '%s\n' \
    'POS Core RPM derivation changed when ignored .local state changed.' >&2
  exit 1
fi

if [[ "$terminal_before" != "$terminal_after" ]]; then
  printf '%s\n' \
    'Terminal Flatpak derivation changed when ignored .dart_tool state changed.' >&2
  exit 1
fi

printf '%s\n' 'Nix package sources exclude ignored developer-generated state.'
