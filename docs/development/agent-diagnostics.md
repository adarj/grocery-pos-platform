# Agent diagnostics and configuration hygiene

`just agent-doctor` checks the optional, machine-owned agent setup. It is separate
from `just doctor`, which checks the ordinary development environment and may
print local identity/path/environment values. Ordinary development does not
require Codex or any MCP. See the [routing policy](codex-workflow.md) before
choosing a specialist; these tools are alternatives, not a pipeline.

## Offline diagnostic contract

The [script](../../scripts/dev/agent-doctor.sh), exposed through the
[justfile](../../justfile), checks:

- Installed CLI/SDK versions, SDK MCP command availability, and login status.
- Exactly `dart`, `dcm`, `codebase_memory`, and `context7` in work; none in base
  or learn in configured profiles. It checks enabled status, exact allowlists,
  and optional-server policy on disk, not the active thread's live tool catalog.
- Ignored/writable project pub cache and existence of derived graph state.
- Regular owner-matching credential files with mode 0600 and a protected parent,
  when present. It never reads their contents or retrieves keyring entries.

Output uses fixed status messages and extracted version numbers, not raw command
output, config JSON, transport URLs, environment values, account names, personal
paths, or credentials. Unexpected/malformed output is a diagnostic failure, not
something echoed for debugging. Commands are bounded; no `eval` or execution of
configuration values is used. Prerequisites include Bash, timeout, jq, Git, stat,
and Python 3 with `tomllib`.

Default operation starts no MCP servers and performs no analysis, license check,
index refresh, GUI launch, product test, update, or Context7 documentation query.
It uses local CLI status/configuration interfaces, not remote health retrieval.
It performs no repairs or intentional configuration/source/index writes. A
fresh-session smoke is separate qualification, not a doctor side effect.

### Configured policy versus live session

A passing `just agent-doctor` proves configured topology/allowlists, not that an
already-running Codex thread has refreshed its live catalog after config changes.
Verify available tools in the active session separately (for example, the active
tool registry or the TUI `/mcp` surface). `mcp list`/`get` establish configured
policy; do not derive live counts from them. When reload behavior is uncertain,
start a fresh Codex session; a VM restart is not normally required. Current
[official MCP guidance](https://learn.chatgpt.com/docs/extend/mcp) distinguishes
configured servers from the TUI's active servers; the
[App Server documentation](https://learn.chatgpt.com/docs/app-server) describes a
supported reload surface, whose availability must be verified for the client in
use. The offline doctor does not attach to it or acquire a new dependency.

CP8R independently observed 7/4/8/2 = 21 tools in the restarted active registry.
The initial evaluation's 58-tool live catalog, despite 21 configured tools, was
a session/configuration-lifecycle mismatch; the failed attempt remains evidence.

Exit 0 means structurally healthy, possibly with nonblocking warnings. Missing
tools/login, invalid diagnostics/configuration, wrong profile topology, missing
or broadened allowlists, disabled required capabilities, unexpectedly required
servers, or unsafe credential permissions return nonzero. Version drift warns
for deliberate requalification, never automatic updating. Missing graph state
warns; directory existence does not prove an index exists or is current. Staleness
requires the task-driven coverage procedure, not hidden indexing in this script.

Offline Context7 status may be `unknown` in restricted execution even when OAuth
works. That warns, not fails. Approved status inspection reported `o_auth` in
Codex 0.157.1; the diagnostic recognizes that spelling. Neither status proves
fresh remote retrieval. Credential-store class remains a manual metadata audit
rather than a brittle inference from file presence alone.

## Qualified versions and ownership

CP7.5.7 used baseline `2e1b12de99b3cceeb57a1fdb51e730431b98b3c5` on Linux
aarch64. All installed versions matched their qualified versions:

| Component | Qualified version / ownership |
| --- | --- |
| Codex CLI | 0.157.1, user tooling |
| Flutter / Dart | 3.41.9 stable / 3.11.5 stable, project Nix SDK |
| Dart MCP | 0.1.2+1, SDK-shipped; explicit protocol probe, not an offline-doctor version assertion |
| DCM / MCP | 1.39.2 Free / 0.2.0, user tooling |
| codebase-memory | 0.11.0, versioned user tooling |
| Context7 | Hosted OAuth documentation service; no client binary/version pin |

Do not upgrade automatically. SDK changes require Dart MCP requalification;
DCM/CBM/Codex drift requires the relevant version, metadata, roots, and read smoke
before relying on changed behavior. Original qualification details remain in
[Dart/DCM tooling](dart-flutter-agent-tooling.md) and
[repository-context tooling](repository-context-agent-tooling.md). The following
CP7 allowlists supersede their earlier full Dart/DCM exposure, not their evidence.

## Work-only MCP surface

Only MCP policy in the user `work.config.toml` changed. Base and learn stayed
byte-identical and MCP-free. All non-MCP work settings stayed unchanged, including
model/reasoning, approvals, permission/network policy, environment and credentials.
No repository `.codex/config.toml`, plugin, skill, hook, or fifth MCP was added.

| Server | Advertised | Previously exposed | CP7 exposed |
| --- | ---: | ---: | ---: |
| Dart | 27 | 27 | 7 |
| DCM with qualified roots fallback | 21 | 21 | 4 |
| codebase-memory analysis profile | 13 | 8 | 8 |
| Context7 | 2 (CP5 catalog; not raw-reenumerated in CP7) | 2 | 2 |
| Total | 63 including the CP5 remote count | 58 | 21 |

Local advertised counts came from new direct handshakes. The fresh work session
also exposed Context7's two allowed documentation tools, without consuming a
documentation call. No claim is made about unexposed remote catalog changes.

Routine allowlists are:

- Dart: `add_roots`, `remove_roots`, `analyze_files`,
  `resolve_workspace_symbol`, `hover`, `signature_help`, `read_package_uris`.
- DCM: `add_roots`, `remove_roots`, `dcm_analyze`, `dcm_init_metrics_preview`.
- CBM: unchanged eight structural/freshness reads documented in its tooling guide.
- Context7: unchanged `resolve-library-id` and `query-docs`.

Root registration changes MCP session scope, not repository source. Dart excludes
test execution, fix/format/project creation/pub/search, app control and runtime
tools by default. DCM excludes fix/format/baseline and paid/unqualified operations.
Explicit later work may deliberately qualify/enable another tool; availability
does not authorize mutation or replace the project `just` validation interface.

`default_tools_approval_mode = "writes"` was qualified and added for the three
local servers. Per-tool `auto` exceptions cover Dart/DCM root add/remove and Dart
package-URI reads: these qualified source reads/session operations lack read-only
annotations or are marked non-read-only. Other enabled local reads advertise
read-only hints. Context7's existing two-tool policy was retained without adding
an unqualified approval override. Annotations are hints, not proof: some excluded
Dart runtime-driving tools actually advertise read-only hints.

The [official MCP guide](https://learn.chatgpt.com/docs/extend/mcp) describes
`writes` as prompting for tools not marked read-only. Installed one-off overrides
and fresh reads qualified the adopted settings. The
[configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference)
and [environment guidance](https://learn.chatgpt.com/docs/config-file/config-advanced)
were checked against installed parsing. Invalid approval values were rejected.
`--strict-config` is not supported by this installed MCP management command;
`--profile` is not accepted by its app-server command. `mcp list --json` omits
allowlists and `required`, so the doctor uses `mcp get --json` for allowlists and
a bounded non-secret user-TOML policy check for `required`.

## Credential and environment decisions

| Area | CP7 evidence / disposition |
| --- | --- |
| Primary Codex login | ChatGPT status present; file-backed storage observed. Regular owner-matching mode-0600 file and non-group/world-writable parent. No migration or content inspection |
| Context7 OAuth | Automatic storage still uses a regular owner-matching mode-0600 file with protected parent. No owned or activatable Secret Service on the session bus; keyring unavailable here (classification B). Retain working storage; no relogin or secret-file surgery |
| File-store residual risk | Owner-only file-backed storage is not an OS keyring or an encrypted-at-rest assurance. Installed `secret-tool` alone does not establish a usable provider |
| Shell inheritance | Retain `all` with `ignore_default_excludes=false`; compatibility/security compromise, not proof of a secret-free environment |
| `TMPDIR=/tmp` | Retain as a useful defensive override: writable temp root; `/var/tmp` was not writable under the observed sandbox. Prior fallback concern was not disproved |
| Project-local `PUB_CACHE` | Retain as useful sandbox-compatible cache ownership. Approximately 35 MiB, writable and ignored; no cleanup, relocation or upgrade |
| `FLUTTER_SUPPRESS_ANALYTICS=true` | Retain: installed Flutter reporting source recognizes it. It does not establish standalone Dart telemetry settings; no global analytics state changed |

Installed Dart help also supports `--suppress-analytics` for a single invocation,
as distinct from its state-changing `--enable-analytics` / `--disable-analytics`
controls. Their availability is not a reason to alter user telemetry state here.

Names-only inspection found 232 inherited names, including substantial Nix/direnv,
compiler/linker and display/session families and a potentially sensitive name.
Raw names remain ignored local evidence. No variable values were printed or
persisted. No speculative exclusion list, new domain, or filesystem permission
was added. Default KEY/SECRET/TOKEN-name filtering remains enabled; name filtering
alone is not credential isolation, and explicit environment overrides need review.

A one-off `inherit=core` fresh session passed tool-version checks, sanitized
ordinary doctor, and Dart/DCM root plus CBM read initialization. It observed
231 names versus 232 initially, retaining almost all broader toolchain/session
state. This does not establish clean minimal inheritance; the cause of that
retention was not resolved. Flutter Linux linking, nixGL GUI, packaging, and all
native dependency paths were not qualified. Keep `all` rather than generalize
limited version/startup success into broad compatibility. No Context7 call was
needed for that experiment.

## Startup and catalog observations

Three local initialize + `tools/list` samples per server, seconds on this host:

| Server | Minimum | Median | Maximum |
| --- | ---: | ---: | ---: |
| Dart | 0.037 | 0.039 | 0.055 |
| DCM | 0.011 | 0.011 | 0.015 |
| codebase-memory | 2.436 | 2.444 | 2.608 |

These include process launch/protocol work, exclude model latency and shutdown,
and are not cold-system or universal performance guarantees. Context7 was not
repeatedly benchmarked or reauthenticated. No persistent startup failure occurred.

Serialized exposed tool definitions for the three local servers measured
74,885 → 18,544 UTF-8 bytes using compact JSON. This is a schema-size proxy,
not actual model token accounting; it excludes Context7 and Codex normalization,
tool discovery, and wrapper overhead. No token-saving estimate is claimed.

The final registered read-only work smoke succeeded in 52.37 seconds with six
calls: Dart root/analyzer/symbol, DCM root/Free metrics preview, and CBM lookup.
Excluded mutation tools were absent, and repository status was unchanged.
Context7 appeared in the live catalog, approved local status confirmed OAuth,
and CP7 made zero Context7 documentation queries. Total turn time is not isolated
catalog/startup time; no reliable work-profile-only catalog timestamp was obtained
from the inspected CLI diagnostics/protocol surfaces. CP5's 79.83-second smoke
is not reinterpreted as startup cost.

Optional startup grace, per-server startup timeouts, and `required` remained
unchanged. No specialist became required. No millisecond tuning, watcher,
auto-index, updater, or new shell polling wrapper was introduced.

## Troubleshooting and validation

1. Run `just agent-doctor`; read the fixed status/warnings, not raw config dumps.
2. For topology problems inspect `codex --profile work mcp list`; for a particular
   allowlist use `codex --profile work mcp get <name>`. Do not share raw transport,
   environment, or authentication fields.
3. For a server failure consult its qualified tooling document; separate executable,
   version, roots, entitlement and permissions. Do not reinstall everything.
4. For graph-dependent work assess relevant coverage/freshness and explicitly
   re-index only when needed. Doctor does not prove freshness or perform refresh.
5. For Context7 authentication failure complete the private
   `codex --profile work mcp login context7` browser flow; keep codes/tokens out of
   chat and logs. Restricted `unknown` status alone does not prove logout.
6. Requalify deliberate version changes before relying on new behavior.

The diagnostic was developed with isolated mock/control/privacy fixtures: drift,
missing tools/login, fifth/leaked MCPs, allowlist omissions/additions/disabled tools,
malformed JSON, required policy, unknown OAuth status, absent graph state, and
unsafe/symlinked credential metadata. Fixtures and sanitized CP7 evidence stay
ignored under `.local/m7.5/cp7/`, never in product tests or credential stores.

Validation uses Bash syntax, `just agent-doctor`, ordinary `just doctor`, recipe
integrity, links/privacy and whitespace checks, plus explicit tooling smoke.
No product suite, M6/M7 acceptance campaign, or CP8 evaluation was run. CP1–CP6
historical evidence, product schema v12 and runtime behavior remain unchanged.

## Final requalification prerequisite

After the developer reviews and commits CP8R remediation, final CP8Q must start
in a **new top-level `codex --profile work` session** created after that commit,
not resume the failed conversation or recursively launch Codex inside an agent.
Verify the actual live 7/4/8/2 = 21-tool catalog before Scenario A, separately from
the offline configuration checks. Run the fixed A–E corpus exactly once, in order,
only when separately authorized. Retain the
[failed attempt](m7-5-evaluation-attempt-1.md); the new `m7-5-final-evaluation.md`
must reference it and compare CP1, attempt 1, and requalification.

Disclose the session difference: CP1 used an ongoing warm session; attempt 1 used
an ongoing warm session with a stale/pre-CP7 live catalog; CP8Q will use a fresh
post-remediation top-level session. Fresh startup is catalog provenance, not a
claim of cold filesystem/package caches or statistical comparability.
