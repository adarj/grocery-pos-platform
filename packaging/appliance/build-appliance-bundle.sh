#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 5 ]]; then
  printf '%s\n' \
    'usage: build-appliance-bundle.sh ROOT CORE-RPM APPLIANCE-RPM FLATPAK OUTPUT' >&2
  exit 2
fi

repository_root="$1"
core_rpm="$2"
appliance_rpm="$3"
terminal_flatpak="$4"
output="$5"
work_root="$(mktemp -d)"
trap 'rm -rf -- "$work_root"' EXIT
bundle_root="$work_root/grocery-pos-appliance-0.0.0-x86_64"
mkdir -p "$bundle_root" "$(dirname "$output")"

install -m 0644 "$core_rpm" "$bundle_root/grocery-pos-core.rpm"
install -m 0644 "$appliance_rpm" "$bundle_root/grocery-pos-appliance.rpm"
install -m 0644 "$terminal_flatpak" "$bundle_root/grocery-pos-terminal.flatpak"
install -m 0755 "$repository_root/packaging/appliance/bootstrap-kinoite.sh" \
  "$bundle_root/bootstrap-kinoite.sh"

core_hash="$(sha256sum "$bundle_root/grocery-pos-core.rpm" | cut -d ' ' -f 1)"
appliance_hash="$(sha256sum "$bundle_root/grocery-pos-appliance.rpm" | cut -d ' ' -f 1)"
terminal_hash="$(sha256sum "$bundle_root/grocery-pos-terminal.flatpak" | cut -d ' ' -f 1)"

printf '%s\n' \
  '{' \
  '  "schema_version": 1,' \
  '  "product": "grocery-pos-appliance",' \
  '  "version": "0.0.0-dev",' \
  '  "fedora_version": "44",' \
  '  "variant_id": "kinoite",' \
  '  "architecture": "x86_64",' \
  '  "artifacts": [' \
  "    {\"role\":\"pos_core_rpm\",\"file\":\"grocery-pos-core.rpm\",\"sha256\":\"$core_hash\"}," \
  "    {\"role\":\"appliance_rpm\",\"file\":\"grocery-pos-appliance.rpm\",\"sha256\":\"$appliance_hash\"}," \
  "    {\"role\":\"terminal_flatpak\",\"file\":\"grocery-pos-terminal.flatpak\",\"sha256\":\"$terminal_hash\"}" \
  '  ]' \
  '}' >"$bundle_root/manifest.json"

(
  cd "$bundle_root"
  sha256sum \
    bootstrap-kinoite.sh grocery-pos-appliance.rpm grocery-pos-core.rpm \
    grocery-pos-terminal.flatpak manifest.json >SHA256SUMS
)

tar --sort=name --mtime='@1' --owner=0 --group=0 --numeric-owner \
  --zstd -cf "$output" -C "$work_root" "$(basename "$bundle_root")"
