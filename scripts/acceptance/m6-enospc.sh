#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [[ "${1:-}" == '--inside-private-mount' ]]; then
  constrained_directory="$2"
  /usr/bin/mount -t tmpfs -o size=512k tmpfs "$constrained_directory"
  exec racket "$repository_root/scripts/acceptance/m6-enospc-test.rkt" \
    "$constrained_directory"
fi

if ! unshare --user --map-root-user --mount true 2>/dev/null; then
  printf '%s\n' \
    'm6-enospc-blocked: unprivileged user/mount namespaces are unavailable' >&2
  exit 77
fi

work_directory="$(mktemp -d /tmp/grocery-pos-m6-enospc.XXXXXX)"
trap 'rmdir -- "$work_directory"' EXIT
unshare --user --map-root-user --mount \
  "$0" --inside-private-mount "$work_directory"
