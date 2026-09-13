#!/usr/bin/env bash

set -euo pipefail

fail() {
  printf 'rpm-build-isolation-test-failed: %s\n' "$*" >&2
  exit 1
}

if [[ $# -ne 1 ]]; then
  fail 'usage: rpm-build-isolation-test.sh REPOSITORY-ROOT'
fi

repository_root="$1"
common_build="$repository_root/packaging/fedora/rpm-build-common.sh"

[[ -f "$common_build" ]] || fail 'shared RPM build policy is missing'

# shellcheck source=/dev/null
source "$common_build"

test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
rpm_topdir="$test_root/rpmbuild"
captured_arguments=()
captured_home=''
captured_xdg_config_home=''
captured_tmpdir=''
captured_source_date_epoch=''

rpmbuild() {
  captured_arguments=("$@")
  captured_home="${HOME-}"
  captured_xdg_config_home="${XDG_CONFIG_HOME-}"
  captured_tmpdir="${TMPDIR-}"
  captured_source_date_epoch="${SOURCE_DATE_EPOCH-}"
}

run_hermetic_rpmbuild "$rpm_topdir" \
  --define '_package_specific_setting value' \
  "$repository_root/packaging/fedora/grocery-pos-core.spec"

[[ "$captured_home" == "$rpm_topdir/HOME" ]] ||
  fail 'rpmbuild HOME is not private to the RPM work tree'
[[ "$captured_xdg_config_home" == "$rpm_topdir/XDG_CONFIG_HOME" ]] ||
  fail 'rpmbuild XDG_CONFIG_HOME is not private to the RPM work tree'
[[ "$captured_tmpdir" == "$rpm_topdir/TMP" ]] ||
  fail 'rpmbuild TMPDIR is not private to the RPM work tree'
[[ "$captured_source_date_epoch" == '1' ]] ||
  fail 'deterministic SOURCE_DATE_EPOCH was not preserved'

for private_directory in HOME XDG_CONFIG_HOME TMP; do
  [[ -d "$rpm_topdir/$private_directory" ]] ||
    fail "private RPM directory was not created: $private_directory"
done

has_argument() {
  local expected="$1"
  local actual
  for actual in "${captured_arguments[@]}"; do
    [[ "$actual" == "$expected" ]] && return 0
  done
  return 1
}

has_argument_pair() {
  local expected_first="$1"
  local expected_second="$2"
  local index
  for ((index = 0; index + 1 < ${#captured_arguments[@]}; index++)); do
    if [[ "${captured_arguments[index]}" == "$expected_first" &&
          "${captured_arguments[index + 1]}" == "$expected_second" ]]; then
      return 0
    fi
  done
  return 1
}

has_argument '-bb' || fail 'binary RPM build mode is missing'
has_argument '--nodeps' ||
  fail 'host RPM build-dependency verification was not disabled'
has_argument_pair '--define' "_topdir $rpm_topdir" ||
  fail 'private _topdir is missing'
has_argument_pair '--define' "_sourcedir $rpm_topdir/SOURCES" ||
  fail 'private _sourcedir is missing'
has_argument_pair '--define' "_rpmdir $rpm_topdir/RPMS" ||
  fail 'private _rpmdir is missing'
has_argument_pair '--define' "_tmppath $rpm_topdir/TMP" ||
  fail 'private _tmppath is missing'
has_argument_pair '--define' '_buildhost grocery-pos-build' ||
  fail 'deterministic build host is missing'
has_argument_pair '--define' '_build_id_links none' ||
  fail 'deterministic build-ID policy is missing'
has_argument_pair '--define' 'use_source_date_epoch_as_buildtime 1' ||
  fail 'deterministic build-time policy is missing'
has_argument_pair '--define' 'build_mtime_policy clamp_to_source_date_epoch' ||
  fail 'deterministic mtime policy is missing'
has_argument_pair '--define' '_package_specific_setting value' ||
  fail 'package-specific rpmbuild arguments were not preserved'

for build_script in build-rpm.sh build-appliance-rpm.sh; do
  script_path="$repository_root/packaging/fedora/$build_script"
  grep -Fq 'source "$repository_root/packaging/fedora/rpm-build-common.sh"' \
    "$script_path" || fail "$build_script does not load the shared policy"
  grep -Fq 'run_hermetic_rpmbuild "$rpm_topdir"' "$script_path" ||
    fail "$build_script does not use the shared policy"
  if grep -Eq '(^|[[:space:]])rpmbuild[[:space:]]+-bb' "$script_path"; then
    fail "$build_script bypasses the shared policy"
  fi
done

for spec in grocery-pos-core.spec grocery-pos-appliance.spec; do
  if grep -Eq '^[[:space:]]*BuildRequires[[:space:]]*:' \
    "$repository_root/packaging/fedora/$spec"; then
    fail "$spec gained a static BuildRequires entry"
  fi
done

printf 'Both RPM builders use private RPM state and skip host dependency checks.\n'
