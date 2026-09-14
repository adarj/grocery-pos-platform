#!/usr/bin/env bash

set -euo pipefail

fail() {
  printf 'appliance-package-contract-failed: %s\n' "$*" >&2
  exit 1
}

if [[ $# -ne 3 ]]; then
  fail 'usage: check-pos-appliance-package.sh APPLIANCE-RPM CORE-RPM REPOSITORY-ROOT'
fi

resolve_rpm() {
  local input="$1"
  if [[ -d "$input" ]]; then
    mapfile -t candidates < <(find "$input" -maxdepth 1 -type f -name '*.rpm' -print)
    [[ ${#candidates[@]} -eq 1 ]] || fail "expected one RPM under $input"
    printf '%s\n' "${candidates[0]}"
  else
    [[ -f "$input" ]] || fail "RPM does not exist: $input"
    printf '%s\n' "$input"
  fi
}

appliance_rpm="$(resolve_rpm "$1")"
core_rpm="$(resolve_rpm "$2")"
repository_root="$3"

[[ "$(rpm -qp --queryformat '%{NAME}' "$appliance_rpm")" == 'grocery-pos-appliance' ]] ||
  fail 'unexpected appliance package name'
[[ "$(rpm -qp --queryformat '%{ARCH}' "$appliance_rpm")" == 'noarch' ]] ||
  fail 'appliance package is not noarch'
[[ "$(rpm -qp --queryformat '%{RELEASE}' "$appliance_rpm")" == '0.1.dev' ]] ||
  fail 'unexpected appliance package release'
[[ "$(rpm -qp --queryformat '%{LICENSE}' "$appliance_rpm")" == 'LicenseRef-Project-Undecided' ]] ||
  fail 'appliance package license metadata changed'

requires="$(rpm -qp --requires "$appliance_rpm")"
grep -Eq '^grocery-pos-core >= 0\.0\.0-0\.4\.dev$' <<<"$requires" ||
  fail 'appliance package does not require the M7-capable POS Core release'
for dependency in grocery-pos-core flatpak ostree plasma-login-manager rpm-ostree shadow-utils systemd; do
  grep -Eq "^${dependency}([[:space:]]|$)" <<<"$requires" ||
    fail "appliance package does not require $dependency"
done
if grep -Eqi '(^|[[:space:]])(nix|nix-daemon)([[:space:]]|$)|/nix/store' <<<"$requires"; then
  fail 'appliance package has a Nix runtime dependency'
fi

extract_root="$(mktemp -d)"
core_root="$(mktemp -d)"
trap 'rm -rf -- "$extract_root" "$core_root"' EXIT
rpm2cpio "$appliance_rpm" | (cd "$extract_root" && cpio -idm --quiet)
rpm2cpio "$core_rpm" | (cd "$core_root" && cpio -idm --quiet)

required=(
  usr/bin/grocery-pos-appliance
  usr/libexec/grocery-pos-appliance/configure-kiosk
  usr/libexec/grocery-pos-appliance/plasmalogin-grocery-pos.conf
  usr/libexec/grocery-pos-appliance/kscreenlockerrc
  usr/libexec/grocery-pos-appliance/powerdevilrc
  usr/lib/systemd/user/grocery-pos-terminal.service
)
for relative in "${required[@]}"; do
  [[ -f "$extract_root/$relative" ]] || fail "missing appliance payload: /$relative"
done

powerdevil="$extract_root/usr/libexec/grocery-pos-appliance/powerdevilrc"
for line in \
  'DimDisplayWhenIdle=false' \
  'TurnOffDisplayWhenIdle=false' \
  'AutoSuspendAction=0'; do
  grep -Fqx "$line" "$powerdevil" ||
    fail "PowerDevil kiosk policy is missing: $line"
done
[[ -f "$core_root/usr/libexec/grocery-pos-core/scripts/appliance.rkt" ]] ||
  fail 'POS Core package omitted the appliance CLI implementation'
[[ -f "$core_root/usr/libexec/grocery-pos-core/pos/support/appliance-provisioning.rkt" ]] ||
  fail 'POS Core package omitted provisioning primitives'
appliance_script="$core_root/usr/libexec/grocery-pos-core/scripts/appliance.rkt"
for contract in \
  'canonical-database (string->path "/var/lib/grocery-pos/pos.db")' \
  'run-command "/usr/bin/ostree" "init"' \
  'command-output "/usr/bin/ostree"' \
  '"-o" "grocery-pos" "-g" "grocery-pos"' \
  '"0750"' \
  '"--home-dir" "/var/lib/grocery-pos-kiosk"' \
  '"--user-group"' \
  '"--lock" "grocery-pos-kiosk"' \
  '(member "wheel" groups)' \
  '(member "grocery-pos" groups)'; do
  grep -Fq "$contract" "$appliance_script" ||
    fail "appliance implementation is missing account/state contract: $contract"
done

files="$(rpm -qpl "$appliance_rpm")"
if grep -Eq '^/(var|etc)/' <<<"$files"; then
  fail 'appliance RPM packages mutable /var or /etc state'
fi
if grep -R -a -F -l '/nix/store/' "$extract_root" >/dev/null; then
  fail 'appliance payload contains a /nix/store reference'
fi
if find "$extract_root" -type f \
  \( -name '*.db' -o -name '*.sqlite' -o -name '*catalog*.json' -o -name '*register*.json' \) \
  -print -quit | grep -q .; then
  fail 'appliance package contains database or store-specific inputs'
fi

unit="$extract_root/usr/lib/systemd/user/grocery-pos-terminal.service"
for line in \
  'PartOf=graphical-session.target' \
  'After=graphical-session.target' \
  'Environment=GROCERY_POS_KIOSK=1' \
  'Environment=GROCERY_POS_CORE_BASE_URI=http://127.0.0.1:7340' \
  'ExecStart=/usr/bin/flatpak run --system com.grocerypos.pos_terminal' \
  'Restart=always' 'RestartSec=2s' 'WantedBy=graphical-session.target'; do
  grep -Fqx "$line" "$unit" || fail "terminal user unit is missing: $line"
done

plm="$extract_root/usr/libexec/grocery-pos-appliance/plasmalogin-grocery-pos.conf"
grep -Fqx 'User=grocery-pos-kiosk' "$plm" || fail 'PLM kiosk user is wrong'
grep -Fqx 'Session=plasma.desktop' "$plm" || fail 'PLM session is not Plasma Wayland'
grep -Fqx 'Relogin=true' "$plm" || fail 'PLM relogin is not enabled'

configure="$extract_root/usr/libexec/grocery-pos-appliance/configure-kiosk"
grep -Fq 'systemctl enable --force plasmalogin.service' "$configure" ||
  fail 'PLM is not selected through the display-manager alias'
grep -Fq 'systemctl disable sddm.service' "$configure" ||
  fail 'historical SDDM activation is not disabled'
for target in sleep.target suspend.target hibernate.target hybrid-sleep.target; do
  grep -Fq "$target" "$configure" || fail "sleep target is not masked: $target"
done
if grep -Eq 'setenforce|permissive|PrivateNetwork|mirror|wheel.*grocery-pos-kiosk' "$configure"; then
  fail 'appliance configuration weakens a preserved security/topology boundary'
fi

scripts="$(rpm -qp --scripts "$appliance_rpm")"
if grep -Eqi 'systemctl|useradd|flatpak|rpm-ostree|sqlite|pos\.db' <<<"$scripts"; then
  fail 'RPM scriptlets mutate appliance/user/database/service state'
fi

c++ -std=c++14 -Wall -Werror \
  -I"$repository_root/flutter/apps/pos_terminal/linux/runner" \
  "$repository_root/flutter/apps/pos_terminal/linux/runner/kiosk_mode_test.cc" \
  "$repository_root/flutter/apps/pos_terminal/linux/runner/kiosk_mode.cc" \
  -o "$extract_root/kiosk-mode-test"
"$extract_root/kiosk-mode-test"

export PLTUSERHOME="$extract_root/plt-user"
mkdir -p "$PLTUSERHOME"
(
  cd "$core_root/usr/libexec/grocery-pos-core"
  racket -e '(dynamic-require "scripts/appliance.rkt" #f)'
)

printf 'Grocery POS appliance RPM contract passed: %s\n' "$appliance_rpm"
