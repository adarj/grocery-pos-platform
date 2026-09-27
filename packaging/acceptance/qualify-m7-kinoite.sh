#!/usr/bin/env bash
set -uo pipefail

# Pure contract check also sourced by the deterministic static regression.
m7_flatpak_permissions_valid() {
  local metadata="$1"
  rg -Fqx 'shared=network;' <<<"$metadata" &&
    rg -Fqx 'sockets=wayland;' <<<"$metadata" &&
    rg -Fqx 'devices=dri;' <<<"$metadata" &&
    ! rg -qi 'filesystems=|devices=.*all|x11|system-talks|session-bus|\[(System|Session) Bus Policy\]' <<<"$metadata"
}
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then return 0; fi

# Safe observations only. In particular grocery-pos-audit verify is NOT run:
# its successful access appends audit.accessed and is a separate explicit
# state-changing Tier B step.
if [[ "$(id -u)" -ne 0 ]]; then
  printf '%s\n' 'm7-kinoite-qualification-blocked: root required on disposable reference appliance' >&2
  exit 77
fi
source /etc/os-release
if [[ "${ID:-}" != fedora || "${VERSION_ID:-}" != 44 ||
      "${VARIANT_ID:-}" != kinoite || "$(uname -m)" != x86_64 ||
      ! -e /run/ostree-booted ]]; then
  printf '%s\n' 'm7-kinoite-qualification-blocked: requires booted Fedora Kinoite 44 x86_64 OSTree host' >&2
  exit 77
fi

passed=0
failed=0
check() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf 'passed: %s\n' "$label"
    passed=$((passed + 1))
  else
    printf 'failed: %s\n' "$label" >&2
    failed=$((failed + 1))
  fi
}

check 'Core RPM installed' rpm -q grocery-pos-core
check 'appliance RPM installed' rpm -q grocery-pos-appliance
check 'SELinux enforcing' bash -c '[[ "$(getenforce)" == Enforcing ]]'
check 'Core enabled' systemctl is-enabled grocery-pos-core.service
check 'Core active' systemctl is-active grocery-pos-core.service
check 'Core ready on literal loopback' bash -c \
  'curl --fail --silent --max-time 5 http://127.0.0.1:7340/ready | jq -e ".status == \"ready\""'
check 'canonical database mode' bash -c \
  '[[ "$(stat -c "%U:%G:%a" /var/lib/grocery-pos/pos.db)" == grocery-pos:grocery-pos:640 ]]'
check 'schema v12 and current validation' bash -c \
  'grocery-pos-db backup-validate /var/lib/grocery-pos/pos.db | jq -e ".valid == true and .migration_status == \"current\" and ([.migration_history[].version] == [1,2,3,4,5,6,7,8,9,10,11,12])"'
check 'backend identity exists' id grocery-pos
check 'kiosk identity exists' id grocery-pos-kiosk
check 'kiosk lacks backend/wheel groups' bash -c \
  'groups=" $(id -nG grocery-pos-kiosk) "; [[ "$groups" != *" wheel "* && "$groups" != *" grocery-pos "* ]]'
check 'kiosk cannot read authoritative DB' runuser -u grocery-pos-kiosk -- test ! -r /var/lib/grocery-pos/pos.db
if runuser -u grocery-pos-kiosk -- grocery-pos-auth status >/dev/null 2>&1; then
  printf '%s\n' 'failed: kiosk unexpectedly invoked root auth tooling' >&2
  failed=$((failed + 1))
else
  printf '%s\n' 'passed: kiosk cannot invoke root auth tooling'
  passed=$((passed + 1))
fi
check 'root auth status available' grocery-pos-auth status
check 'root audit wrapper installed' test -x /usr/bin/grocery-pos-audit
check 'root appliance status available' grocery-pos-appliance status
check 'PLM autologin configuration' test -f /etc/plasmalogin.conf.d/90-grocery-pos.conf

permissions="$(flatpak info --system --show-permissions com.grocerypos.pos_terminal 2>/dev/null || true)"
if m7_flatpak_permissions_valid "$permissions"; then
  printf '%s\n' 'passed: installed Flatpak permission contract'; passed=$((passed + 1))
else
  printf '%s\n' 'failed: installed Flatpak permission contract' >&2; failed=$((failed + 1))
fi
for target in sleep.target suspend.target hibernate.target hybrid-sleep.target; do
  check "$target masked" bash -c "[[ \"\$(systemctl is-enabled '$target' 2>/dev/null)\" == masked ]]"
done

printf 'm7-kinoite-observations: passed=%d failed=%d\n' "$passed" "$failed"
printf '%s\n' 'audit verify/list and all business scenarios are separate explicit Tier B actions because they append state.'
(( failed == 0 ))
