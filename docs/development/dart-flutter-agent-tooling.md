# Dart/Flutter agent tooling

CP7.5.4 qualifies optional developer tooling, not product behavior or a new
project gate. `just` remains the Grocery POS validation interface. Start with
targeted source when it already answers the question; see the
[Codex workflow](codex-workflow.md) for routing and proportional validation.

## Qualified versions and ownership

Qualification used the CP3 baseline `9500aae06f755d394a0e9a0bc255d96ba84849cf`
on Linux aarch64, with Flutter **3.41.9 stable**, Dart **3.11.5 stable**, and
Codex **0.157.1**. The project Nix development environment supplies Flutter/Dart.
`dart mcp-server` ships with that SDK; its MCP initialization reports
`dart and flutter tooling`, version **0.1.2+1**. There is no separately installed
Dart MCP package to upgrade.

DCM **1.39.2** runs natively on this host and is installed as versioned
**user tooling**, not a Flutter, Nix, appliance, or CI dependency. Its official
Linux arm64 archive was obtained from the
[vendor's exact release](https://github.com/CQLabs/homebrew-dcm/releases/tag/1.39.2).
The executable lives under `~/.local/lib/dcm/1.39.2/`, with a user-bin symlink;
no shell configuration was changed. The developer activated it privately;
a sanitized `dcm license` check exited 0 and confirmed **Free**. Free CLI and
useful MCP read operations are now qualified. No activation code, credential
file, account information, or device identifier was inspected or recorded.

Installed help/protocol responses establish the pinned SDK's capabilities.
Current [upstream Dart MCP documentation](https://github.com/dart-lang/ai/tree/main/pkgs/dart_mcp_server)
still labels the package experimental and describes a different, consolidated
tool inventory and different defaults. Do not copy upstream `main` flags or
assume its disabled tools are disabled in this SDK. The current
[Flutter AI setup guide](https://docs.flutter.dev/ai/get-started) also recommends
a plugin/skills bundle; that bundle was deliberately **not** installed, to keep
this lane's effect separate from extra agent instructions.

## Work-profile setup and roots

Only `~/.codex/work.config.toml` received these qualified blocks:

```toml
[mcp_servers.dart]
command = "dart"
args = ["mcp-server"]

[mcp_servers.dcm]
command = "dcm"
args = ["start-mcp-server", "--force-roots-fallback"]
```

Launch Codex from the project Nix environment so `dart` resolves to the qualified
SDK and `dcm` resolves to the qualified user executable, then select `--profile work`.
Installed Codex help defines this profile as
the separate `work.config.toml` layered over base configuration. The
[Codex MCP reference](https://learn.chatgpt.com/docs/extend/mcp) documents the
stdio `command`/`args` table; default/global registration commands were avoided
because this installation belongs only to the work profile.

Base and learn files stayed byte-identical. The work file differs only by the
exact blocks above; all non-MCP settings stayed unchanged. Work lists Dart/DCM;
learn and base list no MCP servers. No repository `.codex/config.toml`, profile,
permission, domain, model, reasoning, or environment setting was added/changed.

The server uses **stdio**, not a new network listener. Installed help supports
`--dart-sdk`, `--flutter-sdk`, `--log-file`, `--exclude-tool`, and
`--tools=all|dart` (`all` is default). There is **no roots-fallback flag** in
this SDK. The exposed `add_roots` tool registers the Flutter package's file URI
(`<repo>/flutter/apps/pos_terminal`) in server memory; no repository file is
written. Both direct protocol and fresh Codex smoke used that operation before
analysis. No fallback option was needed. Treat roots as tool scope, not a
replacement for OS/Codex permissions.

Initial resource and resource-template lists were empty. No bundled skills were
installed or automatic package-skill loading observed in this qualification;
this is not a claim about future SDKs. Avoid `--log-file` unless a deliberately
sanitized diagnostic capture is needed: it logs protocol traffic.

## Installed capability and mutation boundary

All **27** tools below were advertised by the default server. None of those 27
was disabled by default. `--tools=dart` advertised 18 tools in a separate
probe, and `--exclude-tool=run_tests` successfully removed that tool in another
probe; neither selector is in the permanent configuration.

| Tools/category | Effect and network boundary | Qualification |
| --- | --- | --- |
| `analyze_files` | Local analyzer diagnostics; tooling may maintain caches | Targeted cashier-controller analysis returned `No errors` |
| `resolve_workspace_symbol`, `hover`, `signature_help` | Local LSP/symbol information | Symbol resolution and hover worked; signature help metadata inspected, not invoked |
| `read_package_uris` | Local dependency source/directory access using package configuration/cache | Flutter framework URI resolved; cached `collection` source read in fresh smoke |
| `add_roots`, `remove_roots` | Change in-memory server scope, not source | Root addition worked; removal not needed |
| `connect_dart_tooling_daemon`, `get_runtime_errors`, `get_active_location`, `get_widget_tree`, `get_selected_widget` | Runtime/editor discovery and reads via a supplied DTD connection; can expose sensitive live state | Exposed; no runtime connected |
| `set_widget_selection_mode`, `flutter_driver`, `hot_reload`, `hot_restart` | Change runtime/UI state; driver actions are not made harmless by a read-only annotation | Exposed; not invoked |
| `launch_app`, `stop_app`, `list_devices`, `get_app_logs`, `list_running_apps` | App/device lifecycle and logs; launching can build/write generated state | Exposed; not invoked |
| `run_tests` | Executes project code; may write build/cache state, and tests may have other effects | Exposed; not invoked or promoted to project gate |
| `dart_format`, `dart_fix`, `create_project` | Source/project mutation | Exposed; not invoked |
| `pub` | Dependency commands; add/remove/get/upgrade can change source, locks or caches and contact registries | Exposed; not invoked |
| `pub_dev_search` | Sends a search query to pub.dev | Exposed; not invoked |

`rip_grep_packages`, consolidated `lsp`/`dtd`/`roots`/`vm_service` tools, and
`package-root:` URI support were **not advertised** by this installed server.
Do not claim them from newer upstream documentation.

Tool annotations are hints, not authorization. Use Dart MCP for semantic,
analyzer, dependency-source, and explicitly requested runtime assistance.
Source fixes/formatting, dependency changes, project creation, and runtime
actions require task-specific scope. Runtime data/logs may contain credentials
or customer information; do not attach to arbitrary apps or copy their output.

The server's initialization text prefers MCP tools, and `run_tests` says to
always replace shell test commands. Those tool-level instructions do **not**
override repository/user guidance: existing `just` recipes remain authoritative
for project tests and gates. A specifically useful focused MCP test may be
considered in a future task, not automatically substituted for `just test-flutter`,
`just test-pos-integration`, or `just check`.

## Read-oriented smoke and usefulness

A fresh ephemeral `codex --profile work exec` session was explicitly forbidden
to edit, run tests/apps/pub, install skills, inspect credentials, or invoke other
MCPs. It registered only the Flutter package root and used Dart analyzer,
workspace-symbol, hover, and package-URI tools. Repository status stayed clean
before/after this smoke; no product tests were run.

The trial followed the 401 → lock → same-command recovery path rather than
traversing the whole repository. Symbol lookup provides concrete locations and
hover supplies types/contracts, but source and protecting tests are still
needed to verify behavior. It used **19 MCP calls** (one root registration, one
analysis, five symbol searches, eleven hovers, one package read) and **14 shell
calls inspecting 14 repository files**, plus the dependency file via MCP. The
fresh process exited 0 in **216.6 seconds** on this host. That exploration cost
does not establish an improvement. This is a specialist smoke, **not** the formal
CP7.5.8 comparison. Sanitized results are local under `.local/m7.5/cp4/`; CP1
evidence stays untouched.

For context, CP1 Scenario B used **0 MCP calls, 4 shell/search calls, and 11
files**. The smoke tasks were not perfectly identical, so this is not a formal
benchmark comparison. It still demonstrates that MCP availability does not
automatically reduce exploration cost. CP7.5.6 should route semantic tools to
real semantic uncertainty or expensive exploration, not mechanically before
ordinary source/search. The original trial was not rerun to improve its numbers.

The verified path runs through `HttpPosCoreClient._serverFailureFrom`,
`AuthenticationController._handleSessionMemoryChanged`, the protected
`PosTerminalApp` subtree, and `CashierSessionController.retryPendingCommand`.
A 401/authentication-required response clears session memory while retaining
the exact retryable command. Protecting test names include “authentication
rejection keeps the exact persisted command retryable,” “all retry-required
typed failures retain the exact submitted command,” and “startup restores
pending command without network and retry uses it.” Those tests were inspected,
not executed.

## DCM Free: qualified CLI and MCP lane

The [official installation guide](https://dcm.dev/docs/getting-started/for-developers/installation/?os=linux)
supports native Linux arm64 and direct vendor archives. DCM 1.39.2's arm64 ELF
ran here without emulation. The first pass stopped at activation; the developer
subsequently handled [Free activation](https://dcm.dev/docs/getting-started/for-developers/free-plan/)
privately. No activation, paid trial, purchase, or DCM extension installation
was performed by the agent. Never include activation data in prompts or evidence.

### Observed Free CLI capabilities

Commands ran from `flutter/apps/pos_terminal`, targeting `lib`, with console
output and `--no-analytics`. Structure uses its supported DOT output rather than
an unsupported console reporter. All six primary commands exited 0.

| Capability | Local qualification / limitation |
| --- | --- |
| `analyze` | Qualified with task-local `--only-rules`; `avoid-unused-parameters`, `prefer-conditional-expressions`, and a separate `avoid-dynamic` run found no issues. Not an exhaustive test of the vendor's 100-rule claim |
| `calculate-metrics` | Free command accepted, but contexts were skipped: the project enables no DCM metrics. Empty output is not a clean metrics assessment |
| `init metrics-preview` | Qualified real metric calculation without writing configuration; MCP preview reported 22 applied metrics. Selective preview arguments still returned the complete Free metric set |
| `check-unused-files` | Qualified; subsequent `lib test integration` run parsed 35 + 20 + 2 files and found no unused files |
| `check-unused-l10n` | Qualified command accepted with `--class-pattern=^AppLocalizations$`; no matching class exists here, so no actual localization fixture/detection result is claimed |
| `check-exports-completeness` | Qualified; no incomplete-export findings in the selected application scope |
| `analyze-structure` | Qualified import graph: 23 grouped nodes, 76 edges with `--modules=/features/[^/]+`; structure is CLI-only in the observed MCP inventory |
| Configurable formatter | Vendor advertises Free availability; source formatting was not exercised |
| Lint preview | Exposed/documented; not exercised in this continuation |

Resolved metrics configuration confirmed empty method/class/file metric sets.
The preview is the useful policy-free alternative, not a generated baseline or
proposed project configuration. No `analysis_options.yaml` change occurred.

Representative preview signals were maximum cyclomatic complexity **32**,
maximum object-class coupling **62**, and maximum widget nesting **10**. These
are review/navigation hints, not product defects or adopted threshold gates.
The graph independently shows `PosTerminalApp` depending on cashier,
authentication, and the POS client interface. No source refactor was performed.

Dart analyzer/LSP answers correctness and semantic-navigation questions; the
focused controller check returned `No errors`. DCM adds aggregate complexity,
coupling/cohesion, and import-structure information that that diagnostic result
does not provide. The selected DCM lint checks produced no additional warnings;
its demonstrated extra value is metrics/structure, not simply more warnings.

### Licensing LOC and paid boundaries

No inspected help, safe license output, or qualification result exposed an exact
**licensing LOC** count. Successful license-bounded checks over all three source
scopes establish this package's current Free viability; they do not quantify
headroom under the published 50k limit. Neither CP1 physical lines, DCM's 57-file
count, nor preview function-body line sums are substituted for licensing LOC.
The vendor documents analyze/format as LOC-exempt; analyze ran successfully,
format did not run, and the exemption itself was not stress-tested.

Keep [published plan boundaries](https://dcm.dev/pricing/) distinct from execution:

- JSON analysis reporting was **rejected**, exit 1, as unavailable for this
  license. Console is the qualified analysis output; structure's DOT format is
  separately supported.
- A harmless CLI `fix --dry-run` exited 0 with zero auto-fixable issues and a
  Teams-upgrade hint for the full report. It was **not** an explicit dry-run
  rejection and proves no fix entitlement. No fix was applied.
- Presets, baseline, applied CLI fixes, dedicated widget/assets analysis, and
  Teams/CI integration remain paid/unavailable according to plan documentation;
  their execution was not adopted or exhaustively probed. Free widget-nesting
  metrics do not establish entitlement to dedicated widget analysis.

### MCP, Codex roots, and scope

`dcm start-mcp-server` initializes over stdio as `DCM (dart code metrics)
tooling`, MCP version **0.2.0**. It advertises 19 tools with native roots;
`--force-roots-fallback` adds two root-management tools, for **21**.
Advertisement is not Free entitlement: the inventory includes paid and mutating
tools as well as useful Free reads.

A direct protocol client supplying roots successfully ran `dcm_analyze` and
`dcm_init_metrics_preview` under Free. The actual fresh Codex 0.157.1 native-roots
probe instead failed with an **empty registered-root list**. That observed
failure—not a copied example—justifies `--force-roots-fallback`. With the flag,
DCM `add_roots` registers the Flutter package in server memory and the Free
metrics preview succeeds. `--client=codex` was not needed and was not added.
The [vendor MCP guide](https://dcm.dev/docs/ide-integrations/mcp-server/) documents
this fallback mechanism.

Registration followed the successful invocation-only Codex/Free/root probe.
The final fresh session using the actual work-profile blocks made **two DCM
calls** (root + metrics preview) and **two Dart calls** (root + analyzer), exited
0 in **55.7 seconds**, and reported real DCM metrics plus Dart `No errors`.
It made no shell/source-exploration calls. The two documentation files were
byte-identical before/after the session, and no other repository file changed.
Learn/base still list no MCPs. This smoke does not replace the first Dart trial.

Qualified DCM MCP reads are lint analysis and metrics preview. Additional Free
CLI checks have exposed MCP counterparts but were not individually exercised
through Codex. Do not infer paid tool availability from successful Free MCP
startup. `dcm_fix`, `dcm_format`, and `dcm_init_baseline` are exposed mutation
tools and were **not invoked**; root management affects server scope only.
No MCP operation is blanket permission to edit or bypass the project `just`
interface. Use the CLI where an observed capability, such as structure, has no
MCP tool. If the optional server is unavailable, the qualified Free CLI or
ordinary Dart/source/`just` workflow remains usable.

## Version, privacy, and troubleshooting policy

- Dart MCP follows the project-qualified SDK. Recheck help, inventory, roots,
  analyzer and symbol/package reads after an SDK change; a newer inventory may
  expose different mutations or instructions.
- Keep DCM at **1.39.2**, qualified for native execution and the observed Free
  CLI/MCP subset, until a deliberate host-user upgrade. Unexpected minor/major
  upgrades require rechecking plan, CLI reads, metrics preview, Codex roots and
  MCP mutation inventory; no floating auto-upgrade policy was introduced.
- DCM's [vendor privacy statement on analysis](https://dcm.dev/pricing/) says
  source analysis is local. No upload option was used. License validation is
  distinct from analysis, telemetry, and update/version checks. Temporary
  approved network access was used, without changing permanent domain rules.
  CLI analyses/previews/probes used `--no-analytics`; license and MCP startup
  do not accept that option. No analytics setting was enabled, but those paths
  cannot be claimed telemetry-free. No update check was deliberately requested,
  and this was not a network packet audit.
- Qualified Dart semantic operations used local SDK/cache/source. No pub search,
  dependency download, or running-app connection was requested. This is not a
  network packet audit; available package/runtime operations have broader access.
  Normal Codex model requests are external; “local MCP” is not a claim that the
  complete agent workflow keeps all source on-device.
- For startup trouble, verify the SDK on `PATH` in the Nix environment, inspect
  `dart mcp-server --help`, and start a fresh work-profile session. Add the package
  root before semantic queries. Do not add unrecognized fallback flags or install
  a plugin bundle as a repair shortcut.
- For DCM trouble, distinguish executable/version, activation, plan entitlement,
  roots, and network policy. Stop at private activation or denied network access;
  never put keys in evidence or quietly expand domain permissions.

No DCM project rules, baseline, fixes, formatter action, CI integration, or required
editor extension was added. Codebase-memory and Context7 remain provisional for
CP7.5.5; no fifth MCP is proposed.
