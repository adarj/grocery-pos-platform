#!/usr/bin/env bash

set -euo pipefail

repository_root="$1"
export GROCERY_POS_BOOTSTRAP_LIBRARY=1
source "$repository_root/packaging/appliance/bootstrap-kinoite.sh"

work_root="$(mktemp -d)"
trap 'rm -rf -- "$work_root"' EXIT
marker="$work_root/ostree-booted"
touch "$marker"

write_release() {
  local destination="$1"
  local version="$2"
  local variant="$3"
  printf 'ID=fedora\nVERSION_ID=%s\nVARIANT_ID=%s\n' \
    "$version" "$variant" >"$destination"
}

release="$work_root/os-release"
write_release "$release" 44 kinoite
validate_reference_host "$release" x86_64 "$marker"

write_release "$release" 45 kinoite
if validate_reference_host "$release" x86_64 "$marker" 2>/dev/null; then
  printf '%s\n' 'Fedora 45 was unexpectedly accepted' >&2
  exit 1
fi
write_release "$release" 44 silverblue
if validate_reference_host "$release" x86_64 "$marker" 2>/dev/null; then
  printf '%s\n' 'Silverblue was unexpectedly accepted' >&2
  exit 1
fi
write_release "$release" 44 kde
if validate_reference_host "$release" x86_64 "$marker" 2>/dev/null; then
  printf '%s\n' 'traditional Fedora KDE was unexpectedly accepted' >&2
  exit 1
fi
write_release "$release" 44 kinoite
if validate_reference_host "$release" aarch64 "$marker" 2>/dev/null; then
  printf '%s\n' 'wrong architecture was unexpectedly accepted' >&2
  exit 1
fi

bundle="$work_root/bundle"
mkdir -p "$bundle"
install -m 0755 "$repository_root/packaging/appliance/bootstrap-kinoite.sh" \
  "$bundle/bootstrap-kinoite.sh"
printf core >"$bundle/grocery-pos-core.rpm"
printf appliance >"$bundle/grocery-pos-appliance.rpm"
printf flatpak >"$bundle/grocery-pos-terminal.flatpak"
printf '%s\n' \
  '{"schema_version":1,"fedora_version":"44","variant_id":"kinoite","architecture":"x86_64"}' \
  >"$bundle/manifest.json"
(
  cd "$bundle"
  sha256sum bootstrap-kinoite.sh grocery-pos-appliance.rpm \
    grocery-pos-core.rpm grocery-pos-terminal.flatpak manifest.json >SHA256SUMS
)
verify_bundle "$bundle" >/dev/null

printf unexpected >"$bundle/unexpected-artifact"
if verify_bundle "$bundle" >/dev/null 2>&1; then
  printf '%s\n' 'unexpected bundle member was accepted' >&2
  exit 1
fi
rm "$bundle/unexpected-artifact"

printf corrupt >>"$bundle/grocery-pos-core.rpm"
if verify_bundle "$bundle" >/dev/null 2>&1; then
  printf '%s\n' 'bundle hash mismatch was unexpectedly accepted' >&2
  exit 1
fi

# The mutation boundary first asks rpm-ostree for machine-readable pending
# state and never discards an unrelated deployment.
printf core >"$bundle/grocery-pos-core.rpm"
(
  cd "$bundle"
  sha256sum bootstrap-kinoite.sh grocery-pos-appliance.rpm \
    grocery-pos-core.rpm grocery-pos-terminal.flatpak manifest.json >SHA256SUMS
)
fake_rpm_ostree="$work_root/fake-rpm-ostree"
printf '%s\n' \
  '#!/bin/sh' \
  'printf "%s\n" "$*" >>"$FAKE_RPM_OSTREE_LOG"' \
  'if [ "$1" = status ] && [ "${FAKE_PENDING:-0}" = 1 ]; then exit 77; fi' \
  'exit 0' >"$fake_rpm_ostree"
chmod 0755 "$fake_rpm_ostree"
export FAKE_RPM_OSTREE_LOG="$work_root/rpm-ostree.log"
: >"$FAKE_RPM_OSTREE_LOG"
FAKE_PENDING=1
export FAKE_PENDING
if prepare_rpm_ostree_deployment "$bundle" "$fake_rpm_ostree" 2>/dev/null; then
  printf '%s\n' 'pending rpm-ostree deployment was unexpectedly accepted' >&2
  exit 1
fi
[[ "$(wc -l <"$FAKE_RPM_OSTREE_LOG")" -eq 1 ]]

: >"$FAKE_RPM_OSTREE_LOG"
FAKE_PENDING=0
export FAKE_PENDING
prepare_rpm_ostree_deployment "$bundle" "$fake_rpm_ostree"
grep -Fqx 'status --pending-exit-77' "$FAKE_RPM_OSTREE_LOG"
grep -Fqx \
  "install $bundle/grocery-pos-core.rpm $bundle/grocery-pos-appliance.rpm" \
  "$FAKE_RPM_OSTREE_LOG"

printf '%s\n' 'Fedora Kinoite bootstrap preflight tests passed.'
