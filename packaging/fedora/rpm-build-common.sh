#!/usr/bin/env bash

# Shared hermetic state boundary for the two internal source RPM builds.
run_hermetic_rpmbuild() {
  if [[ $# -lt 2 ]]; then
    printf 'usage: run_hermetic_rpmbuild RPM-TOPDIR [RPMBUILD-ARG ...] SPEC\n' >&2
    return 2
  fi

  local rpm_topdir="$1"
  local rpm_home="$rpm_topdir/HOME"
  local rpm_xdg_config_home="$rpm_topdir/XDG_CONFIG_HOME"
  local rpm_tmpdir="$rpm_topdir/TMP"
  shift

  mkdir -p "$rpm_home" "$rpm_xdg_config_home" "$rpm_tmpdir"

  # RPM 4.20 creates per-package build directories and phase scripts itself.
  # Keep that writable state below _topdir. These two internal specs have no
  # BuildRequires, so --nodeps avoids consulting an unrelated host RPM DB.
  HOME="$rpm_home" \
  XDG_CONFIG_HOME="$rpm_xdg_config_home" \
  TMPDIR="$rpm_tmpdir" \
  SOURCE_DATE_EPOCH=1 \
    rpmbuild -bb --nodeps \
      --define "_topdir $rpm_topdir" \
      --define "_sourcedir $rpm_topdir/SOURCES" \
      --define "_rpmdir $rpm_topdir/RPMS" \
      --define "_tmppath $rpm_tmpdir" \
      --define '_buildhost grocery-pos-build' \
      --define '_build_id_links none' \
      --define 'use_source_date_epoch_as_buildtime 1' \
      --define 'build_mtime_policy clamp_to_source_date_epoch' \
      "$@"
}
