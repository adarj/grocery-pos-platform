#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 3 ]]; then
  printf '%s\n' \
    'usage: build-terminal-flatpak.sh ASSET-DIRECTORY FLUTTER-OUTPUT OUTPUT' >&2
  exit 2
fi

asset_root="$1"
flutter_output="$2"
output="$3"
application_id='com.grocerypos.pos_terminal'
branch='stable'
work_root="$(mktemp -d)"
trap 'rm -rf -- "$work_root"' EXIT
build_directory="$work_root/build"
repository="$work_root/repository"
application_root="$build_directory/files/lib/grocery-pos-terminal"

mkdir -p \
  "$application_root" \
  "$build_directory/files/bin" \
  "$build_directory/files/share/applications" \
  "$build_directory/files/share/metainfo" \
  "$build_directory/files/share/icons/hicolor/128x128/apps" \
  "$(dirname "$output")"

cp -a "$flutter_output/app/pos-terminal/." "$application_root/"
# Nix store outputs are read-only. Only the private Flatpak staging copy is
# made writable so its loader paths can be detached from the build toolchain.
chmod -R u+w "$application_root"
ln -s ../lib/grocery-pos-terminal/pos_terminal \
  "$build_directory/files/bin/pos_terminal"
install -m 0644 \
  "$asset_root/$application_id.desktop" \
  "$build_directory/files/share/applications/$application_id.desktop"
install -m 0644 \
  "$asset_root/$application_id.metainfo.xml" \
  "$build_directory/files/share/metainfo/$application_id.metainfo.xml"
rsvg-convert --width 128 --height 128 \
  --output "$build_directory/files/share/icons/hicolor/128x128/apps/$application_id.png" \
  "$asset_root/$application_id.svg"
chmod 0644 \
  "$build_directory/files/share/icons/hicolor/128x128/apps/$application_id.png"

# Nix supplies pinned build tools, but the deployed Flatpak must resolve its
# GTK/runtime libraries inside the Fedora runtime rather than through Nix.
while IFS= read -r -d '' executable; do
  if patchelf --print-rpath "$executable" >/dev/null 2>&1; then
    patchelf --remove-rpath "$executable"
  fi
done < <(find "$application_root" -type f -perm /111 -print0)
patchelf --set-interpreter /lib64/ld-linux-x86-64.so.2 \
  --set-rpath '$ORIGIN/lib' "$application_root/pos_terminal"

install -m 0644 \
  "$asset_root/$application_id.metadata" \
  "$build_directory/metadata"

# Flutter's release asset kernel retains inert source-file URIs for framework
# diagnostics. They are not loaded as filesystem paths. Every executable,
# library, launcher, and other deployed file must be free of a Nix store path.
while IFS= read -r -d '' payload_file; do
  if patchelf --print-rpath "$payload_file" >/dev/null 2>&1; then
    if patchelf --print-rpath "$payload_file" | grep -Fq '/nix/store/'; then
      printf 'Flatpak ELF retains a Nix RPATH: %s\n' "$payload_file" >&2
      exit 1
    fi
  elif [[ "$payload_file" != */data/flutter_assets/kernel_blob.bin ]] &&
       grep -a -Fq '/nix/store/' "$payload_file"; then
    printf 'Flatpak data retains a Nix path: %s\n' "$payload_file" >&2
    exit 1
  fi
done < <(find "$build_directory/files" -type f -print0)

flatpak build-finish --no-inherit-permissions "$build_directory"
# Flatpak normally nests its icon validator in Bubblewrap. Nix already
# isolates this build and does not permit that nested user namespace, so run
# only the icon validator outside Bubblewrap while retaining all validation.
flatpak build-export --disable-sandbox --arch=x86_64 \
  "$repository" "$build_directory" "$branch"
flatpak build-bundle --arch=x86_64 \
  "$repository" "$output" "$application_id" "$branch"
