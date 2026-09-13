#!/usr/bin/env bash

set -euo pipefail

fail() {
  printf 'appliance-bundle-contract-failed: %s\n' "$*" >&2
  exit 1
}

if [[ $# -ne 2 ]]; then
  fail 'usage: check-appliance-bundle.sh BUNDLE-OR-DIRECTORY REPOSITORY-ROOT'
fi

input="$1"
repository_root="$2"
if [[ -d "$input" ]]; then
  mapfile -t candidates < <(find "$input" -maxdepth 1 -type f -name '*.tar.zst' -print)
  [[ ${#candidates[@]} -eq 1 ]] || fail "expected one appliance bundle under $input"
  bundle="${candidates[0]}"
else
  bundle="$input"
fi
[[ -s "$bundle" ]] || fail 'appliance bundle is missing or empty'

work_root="$(mktemp -d)"
trap 'rm -rf -- "$work_root"' EXIT
tar --zstd -xf "$bundle" -C "$work_root"
mapfile -t roots < <(find "$work_root" -mindepth 1 -maxdepth 1 -type d -print)
[[ ${#roots[@]} -eq 1 ]] || fail 'bundle does not contain one top-level directory'
root="${roots[0]}"

expected=(
  SHA256SUMS
  bootstrap-kinoite.sh
  grocery-pos-appliance.rpm
  grocery-pos-core.rpm
  grocery-pos-terminal.flatpak
  manifest.json
)
mapfile -t actual < <(find "$root" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)
[[ "${actual[*]}" == "${expected[*]}" ]] || fail 'bundle member set is not allowlisted'
if find "$root" -type l -print -quit | grep -q .; then
  fail 'bundle contains a symlink'
fi
if find "$root" -type f \
  \( -name '*.db' -o -name '*.sqlite' -o -name '*-wal' -o -name '*-shm' \
     -o -name '*-journal' -o -name '*catalog*' -o -name '*register-config*' \
     -o -name '*password*' -o -name '*secret*' -o -name '*key*' \) \
  -print -quit | grep -q .; then
  fail 'bundle contains store data, database state, or secret-like material'
fi

jq -e '
  .schema_version == 1 and
  .product == "grocery-pos-appliance" and
  .fedora_version == "44" and
  .variant_id == "kinoite" and
  .architecture == "x86_64" and
  ([.artifacts[].role] | sort) ==
    ["appliance_rpm", "pos_core_rpm", "terminal_flatpak"]
' "$root/manifest.json" >/dev/null || fail 'bundle manifest contract is invalid'

export GROCERY_POS_BOOTSTRAP_LIBRARY=1
source "$root/bootstrap-kinoite.sh"
verify_bundle "$root" >/dev/null || fail 'bootstrap rejected the untampered bundle'

tampered="$work_root/tampered"
cp -a "$root" "$tampered"
printf corrupt >>"$tampered/grocery-pos-terminal.flatpak"
if verify_bundle "$tampered" >/dev/null 2>&1; then
  fail 'bootstrap accepted a corrupted terminal artifact'
fi

printf 'Grocery POS appliance bundle contract passed: %s\n' "$bundle"
