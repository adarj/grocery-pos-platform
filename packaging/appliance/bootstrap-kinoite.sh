#!/usr/bin/env bash

set -euo pipefail

bootstrap_grep='/usr/bin/grep'
bootstrap_head='/usr/bin/head'
bootstrap_wc='/usr/bin/wc'
bootstrap_find='/usr/bin/find'
bootstrap_sha256sum='/usr/bin/sha256sum'
if [[ "${GROCERY_POS_BOOTSTRAP_LIBRARY:-0}" == '1' ]]; then
  bootstrap_grep='grep'
  bootstrap_head='head'
  bootstrap_wc='wc'
  bootstrap_find='find'
  bootstrap_sha256sum='sha256sum'
fi

bootstrap_error() {
  printf 'grocery-pos-bootstrap-failed: %s\n' "$*" >&2
  return 1
}

os_release_value() {
  local file="$1"
  local key="$2"
  local line
  line="$($bootstrap_grep -E "^${key}=" "$file" | $bootstrap_head -n 1)" || true
  [[ -n "$line" ]] || return 1
  line="${line#*=}"
  if [[ "$line" == \"*\" && ${#line} -ge 2 ]]; then
    line="${line:1:${#line}-2}"
  fi
  printf '%s\n' "$line"
}

validate_reference_host() {
  local os_release="$1"
  local architecture="$2"
  local ostree_marker="$3"

  [[ -f "$os_release" ]] || { bootstrap_error 'os-release is unavailable'; return 1; }
  [[ "$(os_release_value "$os_release" ID)" == 'fedora' ]] ||
    { bootstrap_error 'host is not Fedora'; return 1; }
  [[ "$(os_release_value "$os_release" VERSION_ID)" == '44' ]] ||
    { bootstrap_error 'host is not Fedora 44'; return 1; }
  [[ "$(os_release_value "$os_release" VARIANT_ID)" == 'kinoite' ]] ||
    { bootstrap_error 'host is not Fedora Kinoite'; return 1; }
  [[ "$architecture" == 'x86_64' ]] ||
    { bootstrap_error 'host architecture is not x86_64'; return 1; }
  [[ -e "$ostree_marker" || -L "$ostree_marker" ]] ||
    { bootstrap_error 'host is not booted through ostree'; return 1; }
}

verify_bundle() {
  local bundle_directory="$1"
  local manifest="$bundle_directory/manifest.json"
  local checksums="$bundle_directory/SHA256SUMS"
  local expected_files=(
    bootstrap-kinoite.sh
    grocery-pos-appliance.rpm
    grocery-pos-core.rpm
    grocery-pos-terminal.flatpak
    manifest.json
  )

  [[ -f "$manifest" && ! -L "$manifest" ]] ||
    { bootstrap_error 'bundle manifest is missing or unsafe'; return 1; }
  [[ -f "$checksums" && ! -L "$checksums" ]] ||
    { bootstrap_error 'bundle checksums are missing or unsafe'; return 1; }
  $bootstrap_grep -Eq '"schema_version"[[:space:]]*:[[:space:]]*1' "$manifest" ||
    { bootstrap_error 'unsupported bundle manifest schema'; return 1; }
  $bootstrap_grep -Eq '"architecture"[[:space:]]*:[[:space:]]*"x86_64"' "$manifest" ||
    { bootstrap_error 'bundle architecture is unsupported'; return 1; }
  $bootstrap_grep -Eq '"fedora_version"[[:space:]]*:[[:space:]]*"44"' "$manifest" ||
    { bootstrap_error 'bundle Fedora release is unsupported'; return 1; }
  $bootstrap_grep -Eq '"variant_id"[[:space:]]*:[[:space:]]*"kinoite"' "$manifest" ||
    { bootstrap_error 'bundle Fedora variant is unsupported'; return 1; }
  [[ "$($bootstrap_find "$bundle_directory" -mindepth 1 -maxdepth 1 -type f | $bootstrap_wc -l)" -eq 6 ]] ||
    { bootstrap_error 'bundle contains unexpected members'; return 1; }
  [[ "$($bootstrap_find "$bundle_directory" -mindepth 1 -maxdepth 1 ! -type f | $bootstrap_wc -l)" -eq 0 ]] ||
    { bootstrap_error 'bundle contains unsupported member types'; return 1; }

  local expected
  for expected in "${expected_files[@]}"; do
    [[ -f "$bundle_directory/$expected" && ! -L "$bundle_directory/$expected" ]] ||
      { bootstrap_error "required bundle artifact is missing or unsafe: $expected"; return 1; }
    $bootstrap_grep -Eq "^[0-9a-f]{64}  ${expected//./\\.}$" "$checksums" ||
      { bootstrap_error "checksum entry is missing: $expected"; return 1; }
  done
  [[ "$($bootstrap_wc -l <"$checksums")" -eq "${#expected_files[@]}" ]] ||
    { bootstrap_error 'checksum manifest contains unexpected entries'; return 1; }
  (cd "$bundle_directory" && $bootstrap_sha256sum --check --strict SHA256SUMS)
}

prepare_rpm_ostree_deployment() {
  local bundle_directory="$1"
  local rpm_ostree="$2"
  local status

  set +e
  "$rpm_ostree" status --pending-exit-77 >/dev/null 2>&1
  status=$?
  set -e
  if [[ $status -eq 77 ]]; then
    bootstrap_error 'an existing pending deployment must be resolved first'
    return 1
  fi
  [[ $status -eq 0 ]] || { bootstrap_error 'rpm-ostree status failed'; return 1; }

  "$rpm_ostree" install \
    "$bundle_directory/grocery-pos-core.rpm" \
    "$bundle_directory/grocery-pos-appliance.rpm"
}

bootstrap_main() {
  if [[ "$(/usr/bin/id -u)" -ne 0 ]]; then
    bootstrap_error 'bootstrap requires root'
    return 1
  fi
  local bundle_directory
  bundle_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  validate_reference_host /etc/os-release "$(/usr/bin/uname -m)" /run/ostree-booted
  verify_bundle "$bundle_directory"
  prepare_rpm_ostree_deployment "$bundle_directory" /usr/bin/rpm-ostree
  printf '%s\n' '{"ok":true,"operation":"bootstrap","reboot_required":true}'
}

if [[ "${GROCERY_POS_BOOTSTRAP_LIBRARY:-0}" != '1' ]]; then
  bootstrap_main "$@"
fi
