#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ "${1:-}" == --inside-private-mount ]]; then
  constrained_directory="$2"
  /usr/bin/mount -t tmpfs -o size=2m tmpfs "$constrained_directory"
  exec racket "$repository_root/scripts/acceptance/m7-enospc-test.rkt" "$constrained_directory"
fi
if ! unshare --user --map-root-user --mount true 2>/dev/null; then
  printf '%s\n' 'm7-enospc-blocked: unprivileged user/mount namespaces unavailable' >&2
  exit 77
fi
scratch="$(mktemp -d /tmp/grocery-pos-m7-enospc.XXXXXX)"
trap 'rmdir -- "$scratch"' EXIT
unshare --user --map-root-user --mount bash "$0" --inside-private-mount "$scratch"
