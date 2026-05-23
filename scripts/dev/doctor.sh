#!/usr/bin/env bash
set -euo pipefail

missing=0
warned=0

ok() {
  printf '[ok]      %s\n' "$1"
}

warn() {
  printf '[warn]    %s\n' "$1"
  warned=1
}

fail() {
  printf '[missing] %s\n' "$1"
  missing=1
}

check_cmd() {
  local name="$1"

  if command -v "$name" >/dev/null 2>&1; then
    printf '[ok]      %-18s %s\n' "$name" "$(command -v "$name")"
  else
    printf '[missing] %-18s\n' "$name"
    missing=1
  fi
}

check_file() {
  local path="$1"

  if [ -f "$path" ]; then
    ok "file exists: $path"
  else
    fail "file missing: $path"
  fi
}

check_dir() {
  local path="$1"

  if [ -d "$path" ]; then
    ok "directory exists: $path"
  else
    fail "directory missing: $path"
  fi
}

check_git_config() {
  local key="$1"
  local value

  value="$(git config --global "$key" || true)"

  if [ -n "$value" ]; then
    printf '[ok]      git %-14s %s\n' "$key:" "$value"
  else
    printf '[warn]    git %-14s unset\n' "$key:"
    warned=1
  fi
}

echo "Grocery POS Dev Doctor"
echo

echo "Environment"
echo "-----------"
printf 'user:              %s\n' "$(whoami)"
printf 'shell:             %s\n' "${SHELL:-unknown}"
printf 'pwd:               %s\n' "$(pwd)"
printf 'GROCERY_POS_DEV:   %s\n' "${GROCERY_POS_DEV:-unset}"
printf 'PROJECT_ROOT:      %s\n' "${PROJECT_ROOT:-unset}"
printf 'IN_NIX_SHELL:      %s\n' "${IN_NIX_SHELL:-unset}"
printf 'SQLITE_DB_PATH:    %s\n' "${SQLITE_DB_PATH:-unset}"
printf 'RACKET_API_HOST:   %s\n' "${RACKET_API_HOST:-unset}"
printf 'RACKET_API_PORT:   %s\n' "${RACKET_API_PORT:-unset}"
echo

echo "Core tools"
echo "----------"
check_cmd git
check_cmd nix
check_cmd direnv
check_cmd just
check_cmd jq
check_cmd yq
check_cmd sqlite3
echo

echo "Racket"
echo "------"
check_cmd racket
check_cmd raco
echo

echo "Rust"
echo "----"
check_cmd rustc
check_cmd cargo
check_cmd rust-analyzer
check_cmd cargo-nextest
check_cmd cargo-watch
echo

echo "Infrastructure"
echo "--------------"
check_cmd supabase
check_cmd tofu
check_cmd tflint
check_cmd terraform-docs
echo

echo "Optional / later"
echo "----------------"
if command -v flutter >/dev/null 2>&1; then
  printf '[ok]      %-18s %s\n' "flutter" "$(command -v flutter)"
else
  warn "flutter not found; acceptable until Flutter app work begins"
fi

if command -v dart >/dev/null 2>&1; then
  printf '[ok]      %-18s %s\n' "dart" "$(command -v dart)"
else
  warn "dart not found; acceptable until Flutter app work begins"
fi
echo

echo "Repository scaffold"
echo "-------------------"
check_file README.md
check_file .editorconfig
check_file .env.example
check_file .envrc
check_file .gitignore
check_file flake.nix
check_file flake.lock
check_file justfile
check_file scripts/dev/doctor.sh

check_dir .vscode
check_file .vscode/extensions.json
check_file .vscode/launch.json
check_file .vscode/settings.json
check_file .vscode/tasks.json

check_dir docs
check_dir docs/adr
check_file docs/adr/README.md

check_dir .local
check_dir .local/sqlite
check_dir .local/logs
check_dir .local/receipts
check_dir .local/support-bundles
echo

echo "Git configuration"
echo "-----------------"
check_git_config user.name
check_git_config user.email
check_git_config commit.gpgsign
check_git_config gpg.format
echo

echo "Git ignore checks"
echo "-----------------"
if grep -q '^\.direnv/' .gitignore; then
  ok ".direnv/ is ignored"
else
  fail ".direnv/ is not ignored"
fi

if grep -q '^\.local/' .gitignore; then
  ok ".local/ is ignored"
else
  fail ".local/ is not ignored"
fi
echo

if [ "$missing" -eq 0 ]; then
  if [ "$warned" -eq 0 ]; then
    echo "Dev environment looks good."
  else
    echo "Dev environment passed required checks with warnings."
  fi
else
  echo "One or more required checks failed."
  exit 1
fi
