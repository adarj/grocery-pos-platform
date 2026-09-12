#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 2 ]]; then
  printf 'usage: build-appliance-rpm.sh REPOSITORY-ROOT OUTPUT-DIRECTORY\n' >&2
  exit 2
fi

repository_root="$1"
output_directory="$2"
package_name='grocery-pos-appliance'
package_version='0.0.0'
work_root="$(mktemp -d)"
trap 'rm -rf -- "$work_root"' EXIT

source_tree="$work_root/$package_name-$package_version"
rpm_topdir="$work_root/rpmbuild"
mkdir -p "$source_tree/packaging/fedora" \
  "$rpm_topdir/BUILD" "$rpm_topdir/BUILDROOT" "$rpm_topdir/RPMS" \
  "$rpm_topdir/SOURCES" "$rpm_topdir/SPECS" "$rpm_topdir/SRPMS" \
  "$output_directory"

for file in \
  grocery-pos-appliance configure-kiosk plasmalogin-grocery-pos.conf \
  kscreenlockerrc powerdevilrc grocery-pos-terminal.service; do
  install -m 0644 "$repository_root/packaging/fedora/$file" \
    "$source_tree/packaging/fedora/$file"
done

tar --sort=name --mtime='@1' --owner=0 --group=0 --numeric-owner \
  --use-compress-program='gzip -n' -cf \
  "$rpm_topdir/SOURCES/$package_name-$package_version.tar.gz" \
  -C "$work_root" "$package_name-$package_version"

SOURCE_DATE_EPOCH=1 rpmbuild -bb \
  --define "_topdir $rpm_topdir" \
  --define "_sourcedir $rpm_topdir/SOURCES" \
  --define "_rpmdir $rpm_topdir/RPMS" \
  --define '_buildhost grocery-pos-build' \
  --define '_build_id_links none' \
  --define 'use_source_date_epoch_as_buildtime 1' \
  --define 'build_mtime_policy clamp_to_source_date_epoch' \
  "$repository_root/packaging/fedora/grocery-pos-appliance.spec"

mapfile -t built_rpms < <(find "$rpm_topdir/RPMS" -type f -name '*.rpm' -print)
if [[ ${#built_rpms[@]} -ne 1 ]]; then
  printf 'expected exactly one built RPM, found %s\n' "${#built_rpms[@]}" >&2
  exit 1
fi
install -m 0644 "${built_rpms[0]}" "$output_directory/"
