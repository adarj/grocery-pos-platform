#!/usr/bin/env bash

set -euo pipefail

fail() {
  printf 'terminal-flatpak-contract-failed: %s\n' "$*" >&2
  exit 1
}

if [[ $# -ne 2 ]]; then
  fail 'usage: check-terminal-flatpak.sh FLATPAK-OR-DIRECTORY REPOSITORY-ROOT'
fi

input="$1"
repository_root="$2"
if [[ -d "$input" ]]; then
  mapfile -t candidates < <(find "$input" -maxdepth 1 -type f -name '*.flatpak' -print)
  [[ ${#candidates[@]} -eq 1 ]] || fail "expected one Flatpak bundle under $input"
  bundle="${candidates[0]}"
else
  bundle="$input"
fi
[[ -s "$bundle" ]] || fail 'terminal Flatpak bundle is missing or empty'

work_root="$(mktemp -d)"
trap 'rm -rf -- "$work_root"' EXIT
repo="$work_root/repo"
ostree init --repo="$repo" --mode=archive
flatpak build-import-bundle "$repo" "$bundle" >/dev/null
mapfile -t refs < <(ostree refs --repo="$repo")
[[ ${#refs[@]} -eq 1 ]] || fail 'expected one application ref in the bundle'
ref="${refs[0]}"
[[ "$ref" == 'app/com.grocerypos.pos_terminal/x86_64/stable' ]] ||
  fail "unexpected application ref: $ref"
checkout="$work_root/checkout"
ostree --repo="$repo" checkout --user-mode "$ref" "$checkout"
metadata="$(<"$checkout/metadata")"
grep -Fqx 'runtime=runtime/org.fedoraproject.Platform/x86_64/f44' <<<"$metadata" ||
  fail 'Fedora 44 runtime is not pinned'
grep -Fqx 'sdk=runtime/org.fedoraproject.Sdk/x86_64/f44' <<<"$metadata" ||
  fail 'Fedora 44 SDK is not pinned'
grep -Fqx 'command=pos_terminal' <<<"$metadata" || fail 'terminal command is missing'
grep -Fqx 'shared=network;' <<<"$metadata" || fail 'loopback network access is not explicit'
grep -Fqx 'sockets=wayland;' <<<"$metadata" || fail 'Wayland access is missing'
grep -Fqx 'devices=dri;' <<<"$metadata" || fail 'DRI access is missing'
if grep -Eq 'filesystems=|host|home|devices=.*all|x11|system-talks|session-bus' <<<"$metadata"; then
  fail 'Flatpak has an unsupported filesystem/device/X11/D-Bus permission'
fi

for required in \
  files/bin/pos_terminal \
  files/lib/grocery-pos-terminal/pos_terminal \
  files/lib/grocery-pos-terminal/lib/libflutter_linux_gtk.so \
  files/lib/grocery-pos-terminal/lib/libapp.so \
  files/share/applications/com.grocerypos.pos_terminal.desktop \
  files/share/metainfo/com.grocerypos.pos_terminal.metainfo.xml \
  export/share/applications/com.grocerypos.pos_terminal.desktop \
  export/share/metainfo/com.grocerypos.pos_terminal.metainfo.xml \
  export/share/icons/hicolor/128x128/apps/com.grocerypos.pos_terminal.png; do
  [[ -e "$checkout/$required" ]] || fail "Flatpak payload is missing $required"
done
terminal="$checkout/files/lib/grocery-pos-terminal/pos_terminal"
[[ "$(patchelf --print-interpreter "$terminal")" == \
   '/lib64/ld-linux-x86-64.so.2' ]] ||
  fail 'terminal ELF interpreter is not the Fedora runtime loader'
while IFS= read -r -d '' executable; do
  if patchelf --print-rpath "$executable" >/dev/null 2>&1; then
    ! patchelf --print-rpath "$executable" | grep -Fq '/nix/store/' ||
      fail "ELF RPATH retains Nix: $executable"
  fi
done < <(find "$checkout/files" -type f -perm /111 -print0)
while IFS= read -r -d '' payload_file; do
  if patchelf --print-rpath "$payload_file" >/dev/null 2>&1; then
    ! patchelf --print-rpath "$payload_file" | grep -Fq '/nix/store/' ||
      fail "Flatpak ELF retains a Nix runtime path: $payload_file"
  elif [[ "$payload_file" != */data/flutter_assets/kernel_blob.bin ]] &&
       grep -a -Fq '/nix/store/' "$payload_file"; then
    fail "Flatpak data retains a Nix runtime path: $payload_file"
  fi
done < <(find "$checkout/files" -type f -print0)
if find "$checkout" -type f \( -name flutter -o -name dart \) -print -quit |
  grep -q .; then
  fail 'Flutter/Dart SDK executable was packaged with the application'
fi

diff -u \
  <(yq -S . "$repository_root/flutter/apps/pos_terminal/pubspec.lock") \
  <(jq -S . "$repository_root/packaging/flatpak/pubspec.lock.json") >/dev/null ||
  fail 'Nix dependency lock copy differs from pubspec.lock'
contract="$repository_root/packaging/flatpak/terminal-flatpak.json"
jq -e '
  .schema_version == 1 and
  .application_id == "com.grocerypos.pos_terminal" and
  .branch == "stable" and
  .runtime == "org.fedoraproject.Platform" and
  .runtime_version == "f44" and
  .sdk == "org.fedoraproject.Sdk" and
  .sdk_version == "f44" and
  .flutter_version == "3.41.9"
' "$contract" >/dev/null || fail 'Flatpak source/build contract is invalid'

printf 'Grocery POS Terminal Flatpak contract passed: %s\n' "$bundle"
