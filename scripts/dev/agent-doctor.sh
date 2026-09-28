#!/usr/bin/env bash
set -euo pipefail

# Offline structural checks only. Never echo raw command/config/auth output.
failed=0
ok() { printf '[ok] %s\n' "$1"; }
warn() { printf '[warn] %s\n' "$1"; }
fail() { printf '[fail] %s\n' "$1"; failed=1; }

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
for dependency in timeout jq git stat python3; do
  if ! command -v "$dependency" >/dev/null 2>&1; then
    fail "diagnostic prerequisite unavailable: $dependency"
  fi
done
if (( failed )); then exit 1; fi

run_bounded() {
  local deadline="$1"
  shift
  timeout --kill-after=2s "$deadline" "$@"
}

version_check() {
  local label="$1" expected="$2" pattern="$3" command="$4" output version
  if ! command -v "$command" >/dev/null 2>&1; then
    fail "$label unavailable"
    return
  fi
  if ! output="$(run_bounded 20 "$command" --version 2>&1)"; then
    fail "$label version check failed or timed out"
  elif [[ "$output" =~ $pattern ]]; then
    version="${BASH_REMATCH[1]}"
    if [[ "$version" == "$expected" ]]; then
      ok "$label $version"
    else
      warn "$label $version: requalification recommended (qualified $expected)"
    fi
  else
    fail "$label version output unrecognized"
  fi
}

printf 'Grocery POS Agent Doctor (offline structural checks)\n'
version_check 'Codex CLI' '0.157.1' 'codex-cli ([0-9]+\.[0-9]+\.[0-9]+)' codex
version_check 'Flutter' '3.41.9' 'Flutter ([0-9]+\.[0-9]+\.[0-9]+)' flutter
version_check 'Dart' '3.11.5' 'Dart SDK version: ([0-9]+\.[0-9]+\.[0-9]+)' dart
version_check 'DCM' '1.39.2' 'DCM version: ([0-9]+\.[0-9]+\.[0-9]+)' dcm
version_check 'codebase-memory' '0.11.0' 'codebase-memory-mcp ([0-9]+\.[0-9]+\.[0-9]+)' codebase-memory-mcp
if run_bounded 20 dart mcp-server --help >/dev/null 2>&1; then
  ok 'Dart MCP SDK command available; protocol version not probed offline'
else
  fail 'Dart MCP SDK command unavailable'
fi
if run_bounded 20 codex login status >/dev/null 2>&1; then
  ok 'Codex login present (status only; store contents not inspected)'
else
  fail 'Codex login absent or status unavailable'
fi

dart_tools='["add_roots","remove_roots","analyze_files","resolve_workspace_symbol","hover","signature_help","read_package_uris"]'
dcm_tools='["add_roots","remove_roots","dcm_analyze","dcm_init_metrics_preview"]'
cbm_tools='["search_graph","query_graph","trace_path","get_graph_schema","get_architecture","index_status","check_index_coverage","detect_changes"]'
context_tools='["resolve-library-id","query-docs"]'

for profile in base work learn; do
  args=(codex)
  if [[ "$profile" != base ]]; then args+=(--profile "$profile"); fi
  # Projection removes transport/CWD/env/header fields before any persistence/output.
  if ! inventory="$(run_bounded 20 "${args[@]}" mcp list --json 2>/dev/null | jq -sce '
    if length != 1 then error("invalid inventory")
    elif (.[0] | type) != "array" then error("invalid inventory") else
      .[0] | map({name, enabled, enabled_tools, disabled_tools, required, auth_status})
    end' 2>/dev/null)"; then
    fail "$profile MCP inventory unavailable or invalid"
    continue
  fi
  if [[ "$profile" != work ]]; then
    if [[ "$inventory" == '[]' ]]; then ok "$profile profile MCP-free";
    else fail "$profile profile contains unexpected MCP configuration"; fi
    continue
  fi
  if ! jq -e 'map(.name) | sort == ["codebase_memory","context7","dart","dcm"]' <<<"$inventory" >/dev/null 2>&1; then
    fail 'work profile must contain exactly four expected MCPs'
    continue
  fi
  if ! jq -e 'all(.[]; .enabled == true and .required != true)' <<<"$inventory" >/dev/null 2>&1; then
    fail 'work specialist disabled or unexpectedly required'
  fi
  # 0.157.1 list omits allowlists; get exposes them without a server handshake.
  allowlists_ok=1
  for server in dart dcm codebase_memory context7; do
    case "$server" in
      dart) expected="$dart_tools" ;;
      dcm) expected="$dcm_tools" ;;
      codebase_memory) expected="$cbm_tools" ;;
      context7) expected="$context_tools" ;;
    esac
    if ! details="$(run_bounded 20 codex --profile work mcp get "$server" --json 2>/dev/null | jq -sce '
      if length != 1 then error("invalid server")
      elif (.[0] | type) != "object" then error("invalid server") else
        .[0] | {name, enabled_tools, disabled_tools}
      end' 2>/dev/null)" || ! jq -e --arg name "$server" --argjson expected "$expected" '
      .name == $name and (.enabled_tools | type == "array") and
      ((.enabled_tools | sort) == ($expected | sort)) and
      (((.disabled_tools // []) - $expected) == (.disabled_tools // []))
      ' <<<"$details" >/dev/null 2>&1; then
      allowlists_ok=0
    fi
  done
  if (( allowlists_ok )); then
    ok 'configured work MCP allowlists match qualified 7/4/8/2 surface'
  else
    fail 'work MCP allowlist missing, broadened, or qualified tool disabled'
  fi
  if jq -e 'any(.[]; .name == "context7" and (.auth_status == "o_auth" or .auth_status == "oauth"))' <<<"$inventory" >/dev/null 2>&1; then
    ok 'Context7 OAuth configured; remote connectivity not tested'
  else
    warn 'Context7 authentication not confirmed by offline status; verify privately if needed'
  fi
done

printf '[info] Live active-session catalog is not verified by this offline diagnostic\n'

# The installed MCP CLI omits `required`; inspect only non-secret policy flags
# in user config, never credential stores or arbitrary configuration output.
if ! run_bounded 10 python3 - <<'PY'
import os, pathlib, sys, tomllib
try:
    state = pathlib.Path(os.environ.get('CODEX_HOME', str(pathlib.Path.home()/'.codex')))
    servers = {}
    for name in ['config.toml', 'work.config.toml']:
        path = state/name
        if path.exists():
            for key, value in tomllib.loads(path.read_text()).get('mcp_servers', {}).items():
                servers.setdefault(key, {}).update(value)
    sys.exit(1 if any(value.get('required', False) for value in servers.values()) else 0)
except Exception:
    sys.exit(1)
PY
then
  fail 'required-server policy unsafe or user configuration unreadable'
else
  ok 'specialists remain optional in user configuration'
fi
if [[ -e "$root/.codex/config.toml" ]]; then
  fail 'unexpected repository Codex configuration; review profile precedence'
fi

if git -C "$root" check-ignore -q .local/codex/pub-cache 2>/dev/null; then
  ok '.local derived state ignored'
else
  fail '.local derived state not ignored'
fi
if [[ -d "$root/.local/codex/pub-cache" && -w "$root/.local/codex/pub-cache" ]]; then
  ok 'project-local pub cache exists and is writable'
else
  fail 'project-local pub cache missing or not writable'
fi
if [[ -d "$root/.local/codex/codebase-memory" ]]; then
  ok 'codebase-memory derived-state directory exists; freshness not inferred'
else
  warn 'codebase-memory state missing; explicit index setup needed before graph use'
fi

state="${CODEX_HOME:-${HOME}/.codex}"
for credential in auth.json .credentials.json; do
  if [[ -L "$state/$credential" ]]; then
    fail 'credential storage path is a symlink; manual security review required'
  elif [[ -e "$state/$credential" ]]; then
    if [[ -f "$state/$credential" ]] &&
      metadata="$(stat -c '%u %a' -- "$state/$credential" 2>/dev/null)" &&
      [[ "$metadata" == "${UID} 600" ]] &&
      parent="$(stat -c '%u %a' -- "$state" 2>/dev/null)" &&
      [[ "${parent%% *}" == "$UID" ]] && (( (8#${parent##* } & 0022) == 0 )); then
      ok 'credential file mode: protected (owner-only; contents not inspected)'
    else
      fail 'credential file or parent permissions unsafe'
    fi
  else
    warn 'credential file absent; storage class needs private manual verification'
  fi
done

if (( failed )); then
  printf '[fail] Agent setup needs attention; no repairs performed\n'
  exit 1
fi
printf '[ok] Agent setup structurally healthy; no network retrieval or repairs performed\n'
