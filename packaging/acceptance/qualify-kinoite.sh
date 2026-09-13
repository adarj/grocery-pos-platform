#!/usr/bin/env bash
set -uo pipefail

# Read-only Tier B observations for an already provisioned reference appliance.
# This helper never starts/stops services, changes rpm-ostree state, changes
# users, changes SELinux, or touches the database. Root is required only so the
# behavioral kiosk permission check is meaningful.

if [[ "$(id -u)" -ne 0 ]]; then
  printf '%s\n' \
    'm6-kinoite-qualification-blocked: rerun this read-only helper as root on the disposable reference appliance' >&2
  exit 77
fi

failures=0
passes=0

pass() {
  passes=$((passes + 1))
  printf 'passed: %s\n' "$1"
}

fail() {
  failures=$((failures + 1))
  printf 'failed: %s\n' "$1" >&2
}

observe() {
  local title="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    pass "$title"
  else
    fail "$title"
  fi
}

source /etc/os-release
[[ "${ID:-}" == fedora && "${VERSION_ID:-}" == 44 && \
   "${VARIANT_ID:-}" == kinoite ]] &&
  pass 'Fedora Kinoite 44 identity' || fail 'Fedora Kinoite 44 identity'
[[ "$(uname -m)" == x86_64 ]] &&
  pass 'x86_64 architecture' || fail 'x86_64 architecture'
[[ -e /run/ostree-booted ]] &&
  pass 'booted OSTree deployment' || fail 'booted OSTree deployment'

observe 'grocery-pos-core RPM installed' /usr/bin/rpm -q grocery-pos-core
observe 'grocery-pos-appliance RPM installed' /usr/bin/rpm -q grocery-pos-appliance
observe 'SELinux status tooling available' /usr/sbin/getenforce
if [[ -x /usr/sbin/getenforce && "$(/usr/sbin/getenforce)" == Enforcing ]]; then
  pass 'SELinux mode is Enforcing'
else
  fail 'SELinux mode is Enforcing'
fi

observe 'POS Core enabled' /usr/bin/systemctl is-enabled grocery-pos-core.service
observe 'POS Core active' /usr/bin/systemctl is-active grocery-pos-core.service
observe 'Plasma Login Manager selected' /usr/bin/systemctl is-enabled plasmalogin.service

if /usr/bin/curl --fail --silent --max-time 5 \
    http://127.0.0.1:7340/ready | /usr/bin/grep -Eq '"status"[[:space:]]*:[[:space:]]*"ready"'; then
  pass 'POS Core readiness endpoint'
else
  fail 'POS Core readiness endpoint'
fi

[[ "$(/usr/bin/stat -c '%U:%G:%a' /var/lib/grocery-pos/pos.db 2>/dev/null)" == \
   'grocery-pos:grocery-pos:640' ]] &&
  pass 'canonical database owner/group/mode' ||
  fail 'canonical database owner/group/mode'
[[ "$(/usr/bin/stat -c '%U:%G' /usr/libexec/grocery-pos-core 2>/dev/null)" == \
   'root:root' ]] &&
  pass 'immutable backend payload root ownership' ||
  fail 'immutable backend payload root ownership'
[[ "$(/usr/bin/stat -c '%U:%G' /etc/grocery-pos 2>/dev/null)" == \
   'root:root' ]] &&
  pass 'machine configuration root ownership' ||
  fail 'machine configuration root ownership'

observe 'backend service identity exists' /usr/bin/id grocery-pos
observe 'kiosk graphical identity exists' /usr/bin/id grocery-pos-kiosk
kiosk_groups="$(/usr/bin/id -nG grocery-pos-kiosk 2>/dev/null || true)"
if [[ " $kiosk_groups " != *' wheel '* && \
      " $kiosk_groups " != *' grocery-pos '* ]]; then
  pass 'kiosk lacks wheel and backend group membership'
else
  fail 'kiosk lacks wheel and backend group membership'
fi

if /usr/sbin/runuser -u grocery-pos-kiosk -- \
    /usr/bin/test ! -r /var/lib/grocery-pos/pos.db; then
  pass 'kiosk cannot read the authoritative database'
else
  fail 'kiosk cannot read the authoritative database'
fi
if /usr/sbin/runuser -u grocery-pos-kiosk -- \
    /usr/bin/test ! -w /usr/libexec/grocery-pos-core; then
  pass 'kiosk cannot write backend payload'
else
  fail 'kiosk cannot write backend payload'
fi

flatpak_permissions="$(/usr/bin/flatpak info --system --show-permissions \
  com.grocerypos.pos_terminal 2>/dev/null || true)"
if [[ "$flatpak_permissions" == *'shared=network;'* && \
      "$flatpak_permissions" == *'sockets=wayland;'* && \
      "$flatpak_permissions" == *'devices=dri;'* && \
      "$flatpak_permissions" != *'filesystems='* && \
      "$flatpak_permissions" != *'devices=all'* ]]; then
  pass 'installed Flatpak permission contract'
else
  fail 'installed Flatpak permission contract'
fi

observe 'PLM Grocery POS autologin drop-in' /usr/bin/test -f \
  /etc/plasmalogin.conf.d/90-grocery-pos.conf
observe 'terminal user service enabled in kiosk home' /usr/bin/test -L \
  /var/lib/grocery-pos-kiosk/.config/systemd/user/graphical-session.target.wants/grocery-pos-terminal.service

for target in sleep.target suspend.target hibernate.target hybrid-sleep.target; do
  if [[ "$(/usr/bin/systemctl is-enabled "$target" 2>/dev/null)" == masked ]]; then
    pass "$target masked"
  else
    fail "$target masked"
  fi
done

printf 'qualification-summary: passed=%d failed=%d\n' "$passes" "$failures"
if (( failures != 0 )); then
  exit 1
fi
