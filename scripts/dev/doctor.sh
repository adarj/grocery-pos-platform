#!/usr/bin/env bash
set -euo pipefail

check() {
  if command -v "$1" >/dev/null 2>&1; then
    echo "[ok] $1: $(command -v "$1")"
  else
    echo "[missing] $1"
  fi
}

echo "Grocery POS Dev Doctor"
echo

check git
check nix
check direnv
check just
check racket
check raco
check rustc
check cargo
check flutter
check dart
check sqlite3
check supabase
check tofu

echo
echo "Git identity:"
git config --global user.name || true
git config --global user.email || true
