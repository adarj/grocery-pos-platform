# M7.5 CP1 — Pre-optimization workflow baseline

Observed 2026-09-27. This is an inventory, not a workflow change or new product
qualification. Measurements preceded creation of this document and the
[repeatable evaluation corpus](m7-5-evaluation-corpus.md).

## Repository and environment

- Repository: `adarj/grocery-pos-platform`; root verified as the intended checkout.
- Initial branch: `main`; HEAD, local `main`, and merge-base with `main` were
  `7aa1df83a539ca761da331ee6a1db4ed269f7223` —
  `test(integration): harden crash-recovery timeout (#8)`.
- Initial tracked/untracked worktree was clean. No milestone branch was created.
- The baseline's [push CI run](https://github.com/adarj/grocery-pos-platform/actions/runs/36295562331)
  was independently queried through the public GitHub API: completed/success.
  This does not replace M7's conditional hardware/appliance acceptance record.
- Shell environment: Fedora Linux 44 container, aarch64, kernel
  `7.2.7-200.fc44.aarch64`; container marker and active Nix development-shell
  marker observed. Outer host, hypervisor, and editor were not independently
  identified. README's Apple Silicon/VMware claim is not disproved by this shell.
- Codex diagnostic warned about disk headroom; the checkout filesystem had
  approximately 3.5 GiB free (96% used). `/tmp` was a separate approximately
  5.9 GiB tmpfs. No cleanup or environment repair was performed.
- Migration inventory ends at v12. Flutter presents; Racket decides; SQLite
  remembers; Rust talks to edges; the cloud coordinates. These remain unchanged.

## Codex configuration ownership and semantics

These are observed user-local files, **not repository policy**:

| Layer | Observed purpose/settings |
| --- | --- |
| `~/.codex/config.toml` | `gpt-6-sol`, high reasoning; this checkout trusted; no explicit MCP or permission profile |
| `~/.codex/work.config.toml` | `gpt-6-sol`, xhigh; `on-request`, `auto_review`; `gpos-work` extending `:workspace`; command network enabled, local binding allowed, domain allows `pub.dev`/`cache.nixos.org`; network proxy enabled |
| `~/.codex/learn.config.toml` | `gpt-6-sol`, xhigh; `never`, `:read-only`; intended inspection/learning, not repository mutation |

Installed `codex-cli 0.157.1 --help` explicitly selects the separate files with
`codex --profile work` or `codex --profile learn`; they layer over base config.
This agrees with current official documentation, rather than assuming older
inline `[profiles.*]` syntax.

Precedence, highest first: CLI overrides; trusted project `.codex/config.toml`
layers (nearest directory wins); selected profile file; user base; cloud-managed
defaults; system config; built-ins. Enforced requirements are additional
constraints. Therefore adding trusted repository config can override selected
`work`/`learn` values. Do not casually move their permission model into Git.
[Official configuration precedence](https://learn.chatgpt.com/docs/config-file/config-basic).

`on-request` lets the agent request escalation; `never` does not request it and
returns execution failures. `auto_review` changes the reviewer of eligible
requests, not sandbox authority; with `never` there is no escalation to review.
CLI help and [official auto-review semantics](https://learn.chatgpt.com/docs/sandboxing/auto-review)
support this distinction.

`:read-only` restricts local command writes; `:workspace` permits workspace/temp
writes and preserves protected paths. Custom inheritance retains those baseline
protections. Domain rules require an active network proxy; that proxy does not
filter hosted web/app/MCP tools. `allow_local_binding` also relaxes the
local/private-network guard, not merely one POS port. Legacy sandbox settings
can supersede permission profiles; the inspected files contain none.
[Official permission profiles](https://learn.chatgpt.com/docs/permissions),
[configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference).

Both profiles have `shell_environment_policy.inherit = "all"` **and**
`ignore_default_excludes = false`. Automatic KEY/SECRET/TOKEN-name exclusions
therefore remain enabled; name filtering is not proof of a secret-free child
environment. Explicit overrides are listed below. No potentially sensitive
inherited names matched the inventory's conservative name scan; values were
not dumped. Names are ignored local evidence only.
[Official shell-environment semantics](https://learn.chatgpt.com/docs/config-file/config-advanced).

Neither profile specifies polling settings. Current documented
`background_terminal_max_timeout` is the maximum empty `write_stdin` poll
window, default 300000 ms, replacing `background_terminal_timeout`; it is not
an automatic polling interval. This session's tool schema also exposes a
300000 ms maximum. The developer's <=60-second blocking-call rule and existing
conversation guidance apply separately. No polling policy was changed.
[Polling reference](https://learn.chatgpt.com/docs/config-file/config-reference).

No repository `.codex/config.toml` or probed `/etc/codex/` config/requirements
file was present. Base `codex doctor --summary` reported restricted filesystem
and network, OnRequest, and no configured MCPs. The current agent harness
advertises workspace/temp write roots and automatic escalation review;
approved shell calls used escalation. Those observations do **not** establish
which named profile launched this conversation or enumerate cloud/managed
policy. Effective profile identity and any additional managed layers remain
unresolved; no boundary-changing experiments were attempted.

## Tool and MCP substrate

| Tool | Observed version | Current supplying layer |
| --- | --- | --- |
| Codex | 0.157.1 | User standalone distribution, outside project flake |
| Nix | 2.34.7 | User Nix profile |
| direnv | 2.37.1 | Nix-store executable; declared in project dev shell |
| just | 1.51.0 | Project Nix dev shell |
| Git | 2.54.0 | Project Nix dev shell |
| Flutter | 3.41.9 stable | Project Nix dev shell, wrapped SDK |
| Dart | 3.11.5 stable, linux_arm64 | Flutter-provided Nix SDK |
| Racket | 9.1 | Project Nix dev shell |
| DCM | unavailable | Not on PATH or usual user/Nix-profile bin paths |
| codebase-memory-mcp / codebase-memory | unavailable | Not on PATH or usual user/Nix-profile bin paths |
| Context7 | no registered server/version | No observed installation route |

`codex mcp list --json` succeeded with **zero** configured servers under base,
work, and learn. Hosted app/plugin tools exist separately; zero manual MCP
registrations does not mean the agent has no hosted tools. No specialist MCP
appeared in available tool metadata or the filtered plugin inventory. No MCP
handshake/health claim is made for an unconfigured server.

| Intended MCP | Baseline state / config | Trust boundary currently known or intended |
| --- | --- | --- |
| Official Dart/Flutter | Installed SDK command; not configured in any inspected profile; `dart mcp-server --help` works; no protocol health test | Local stdio, repository/SDK access; upstream exposes analysis, dependency actions, formatting and tests, so not intrinsically read-only. Network actions/project transmission depend on enabled tools and host agent. No credential needed for help; full setup/roots boundary to verify in 7.5.4 |
| codebase-memory | Not installed in observed command locations; not configured; version unavailable | Intended local structural repository index; needs repository access. Execution, mutation, network, credentials and external transmission capabilities to verify in 7.5.5 |
| Context7 | Not configured; installation unknown, version unavailable | Intended online documentation provider, possibly local bridge or hosted transport; network/query disclosure expected by intent. Credentials, repository access, execution/mutation and exact transmission contract to verify in 7.5.5 |
| DCM | Not installed in observed command locations; not configured; version unavailable | Intended local Dart analysis/MCP surface; repository access expected. License/credentials, network, execution/mutation and transmission capabilities to verify in 7.5.4 |

No installation, registration, repair, model change, or extra MCP was attempted.
Nix owns the project language/toolchain pin; user-local Codex and future
specialist installations need their own explicit upgrade owner.

## Repository context and interfaces

| Surface | Lines | Bytes | Observation |
| --- | ---: | ---: | --- |
| `AGENTS.md` | 290 | 8084 | 13 major sections, six subsections; substantial invariant and teaching guidance |
| `README.md` | 554 | 20798 | Current implemented capabilities mixed with early-phase/environment framing |
| `justfile` | 141 | 5166 | Canonical commands; complete `check` includes analysis, unit and real-process tests |

AGENTS composition: authority/transaction/security/local-first/Git/scope rules
are universally required invariants; API/ADR/command locations are routing
pointers; collaboration, TDD steps, validation and dependency procedures are
detailed workflow guidance; explanatory lists and commit examples are possible
routing/compression candidates. This classification does not authorize deleting
invariants or weakening learning-oriented collaboration.

Inventory reviewed `.envrc`/`.env.example`, Nix inputs/dev shell/source filter,
VS Code settings/tasks, doctor, CI, Flutter analyzer/pubspec/lock, the development
notes, architecture contracts, ADR index and M7 evidence overview. `.envrc`
uses the flake and optionally loads ignored `.env.local` (contents not inspected).
Nixpkgs is pinned at `f83fc3c307e74bc5fd5adb7eb6b8b13ffd2a36e1`; Rust overlay and
flake-utils are also locked. Deployable inputs exclude `.local` and other
generated directories. CI runs scaffold, Nix, Racket, Flutter analysis/unit and
integration gates. Flutter uses `flutter_lints 6.0.0`, `http 1.6.0`, and SDK
constraint `^3.11.5`; DCM is not in analyzer/project configuration.

Verified drift, left unchanged:

- README introduction, “Current Implementation Status” opening and “Running
  the Walking Skeleton” still frame the project as walking-skeleton/early
  domain work despite its documented M7 security/recovery implementation.
  “Checkpoint 2” unlock wording is also historical. “Not production-ready”
  remains consistent with conditional M7 acceptance.
- README's “Development Environment” and VM notes identify Apple Silicon,
  VMware, Kinoite aarch64, Distrobox and VSCodium as the primary setup. This is
  machine-specific guidance needing current developer confirmation, not a
  verified false claim about this session's outer host.
- Mechanical task-to-`just --dump --dump-format json` comparison found missing
  `test-rust`, `fmt`, and `supabase-stop`. All eight other referenced recipes
  exist. `supabase-start` exists but is a TODO echo, not a working service start.
  Whether to add recipes or remove tasks is deferred to 7.5.3.

Flutter inventory used tracked/nonignored `rg --files -g '*.dart' flutter` and
physical text-line counting, **not** bytes or a semantic LOC estimate:

| Category | Files | Physical lines | Nonblank lines, including comments |
| --- | ---: | ---: | ---: |
| Production (`lib/`) | 35 | 6759 | 6210 |
| Test/integration | 22 | 12100 | 11042 |
| Total | 57 | 18859 | 17252 |

Largest files: cashier widget tests 2657 lines, real-process integration 2454,
production `cashier_screen.dart` 1518, recovery-controller tests 1183,
controller tests 1101, HTTP-client tests 1031. Largest other production files:
HTTP client 682, status screen 652, cashier controller 651, register models 362.
This is a transparent size baseline, not proof of DCM Free eligibility.

`just doctor`: exit 0; no missing tools/scaffold; warnings only for global
`commit.gpgsign` and `gpg.format` unset. It checks global, not effective local,
Git configuration. It prints identity/path/environment values, including Git
name/email, so collection was redacted before persistence. No credential value
was observed/exposed; its output is not suitable for blind AI evidence copying.
A separate Codex doctor raised the disk warning above. No doctor was changed.

## Existing environment workarounds

| Setting | Classification and evidence |
| --- | --- |
| `TMPDIR=/tmp` (work/learn) | Known current suitability: writable temporary area, currently tmpfs. Original workaround cause and necessity versus inherited default remain unknown; packaging's private TMPDIR isolation is a separate contract |
| `PUB_CACHE=<repo>/.local/codex/pub-cache` (work) | Known current purpose: workspace-local dependency cache; effective shell matches that location and Scenario E resolves dependencies. Necessity of this override versus other permitted caches is unverified |
| `FLUTTER_SUPPRESS_ANALYTICS=true` (work/learn) | Probably harmless but unverified; supplied intent is noninteractive analytics suppression. No repository justification or proof of current SDK enforcement found |

Repository search found no Codex-specific rationale for these overrides and
no top-level local workaround notes. Existing VM notes explain nixGL, a
separate documented graphics workaround. None was removed or tested through
destructive counterfactual experiments.

## Pre-change evaluation results

Counts exclude general inventory and bookkeeping; elapsed A–D values include
reasoning/tool latency and are approximate. Token/context usage is unavailable
for every scenario, not estimated. All four intended MCP providers had zero
calls. Tests identified in A–C were read, not executed.

| Scenario | Files read | Shell/search calls | MCP calls | External-doc calls | Tests started | Follow-up polls | Elapsed | Correctness |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- |
| A — SQLite policy | 3 | 2 | 0 | 0 | 0 | 0 | ~28.8 s | Source verified |
| B — 401/pending recovery | 11 | 4 | 0 | 0 | 0 | 0 | ~51.6 s | Source verified |
| C — reset/final writer/retry | 10 | 5 | 0 | 0 | 0 | 0 | ~75.7 s | Source verified |
| D — official MCP setup | 0 | 2 | 0 | 5 | 0 | 0 | ~65.0 s | Documented with version caveats |
| E — `just crash-m6 3` | 0 | 1 | 0 | 0 | 1 | 1 | 56.78 s | Passed, three iterations |

A: `open-pos-sqlite-connection` establishes WAL for create, verifies it for
read/write, and sets/verifies FULL=2, foreign keys and checkpoints. Five
`sqlite-connection-policy-test.rkt` cases protect initialization, compatible
conversion, rejection, cleanup/busy settings and arguments. ADR-0018 separates
durability policy from business decisions/migrations.

B: `HttpPosCoreClient._serverFailureFrom` makes protected
`authentication_required` 401 retryable with the same command ID and clears
`MemoryAuthenticationSession`. `AuthenticationController` locks;
`PosTerminalApp` replaces the protected Navigator. `CashierSessionController`
persists before POST and retains pending identity on retryable failure;
`PersistedCashierSession`/`FileCashierSessionStore` preserve operator-bound
recovery independently. HTTP-client, recovery-controller, widget lock/navigation
and “401 before mutation preserves exact command across reauthentication”
integration tests were inspected.

C: root wrapper/CLI privilege and canonical DB checks lead to
`operator-service-reset-pin` and `rotate-operator-pin!`: hashing outside writer,
expected-revision arbitration, revision increment, throttle clearing, grant
revocation and required audit. Authentication rejects old session revision;
`commit-plan` carries the new internal principal revision. The command UoW
performs final duplicate/provenance/exact-payload lookup under `BEGIN IMMEDIATE`
before fresh active/enrolled/revision/permission validation. A new valid
same-operator session recovers historical durable outcomes rather than
reauthorizing history. The controlled writer-race/durable-retry UoW regression
and root-reset/pending-command integration cases were inspected.

D: SDK/help -> one official-domain web search -> current Flutter setup guide,
Dart 3.11 release note, upstream server README/tools page -> official Codex MCP
documentation. Five web calls; no duplicate search query or network-policy
change. One additional external plugin-catalog listing was discovery, not a
documentation/MCP call; it unexpectedly returned a very large catalog.
Some B/C searches guessed nonexistent paths; those attempts remain in the
call counts, not concealed or repeated to inflate the baseline.

For this installed SDK, invocation is `dart mcp-server` (stdio). A manual Codex
registration would be `codex mcp add dart -- dart mcp-server`, or a server entry
with command `dart` and args `["mcp-server"]`; **not executed**. This combines
installed help with [official Codex MCP configuration](https://learn.chatgpt.com/docs/extend/mcp?surface=cli).
The [current Flutter guide](https://docs.flutter.dev/ai/get-started) instead
offers a Codex plugin route and describes Flutter 3.47, newer than installed
3.41.9. The [upstream server README](https://github.com/dart-lang/ai/tree/main/pkgs/dart_mcp_server)
still labels the package experimental, requires 3.9-era-or-later SDK support,
and recommends Tools/Resources/Roots client support; its older experimental
flag is removable for stable 3.9+. Installed help needs no such flag. Explicit
SDK selectors are available; protocol-traffic logging would need privacy care.
Exact Codex roots negotiation and newer tool availability on 3.11.5 remain
specialist-checkpoint work. Hosted web access succeeded without changing the
work profile's command-domain list; that is not proof shell access is allowed.

E: one test passed (reported body duration ~54 s); GNU time measured 56.78 s,
exit 0. One empty follow-up poll waited up to 50 s and returned completion/new
information. Zero “still running” updates; zero unnecessary restarts. Existing
135-second campaign and 30-second per-start readiness bounds were unchanged.
This is real process-crash evidence, not physical power-loss qualification.

## Findings and later checkpoints

- **A — required:** repair current-state guidance and mechanical task drift;
  establish specialist prerequisites/health and explicit ownership in 7.5.4/5;
  preserve work/learn separation across config precedence; review broad
  environment inheritance, local/private-network allowance and hosted-tool
  trust separately. Clarify doctor output privacy before any AI-specific reuse.
- **A — measurement limitation to carry:** active session profile/managed layers
  and exact token accounting are unresolved. Preserve these labels, not invented
  measurements. Low host disk headroom is an observed operational prerequisite
  for later tooling; no cleanup is authorized by this checkpoint.
- **B — useful/unproven:** route detailed context while retaining invariants;
  separate optional `doctor-ai` from general doctor; avoid oversized discovery
  output and unnecessary source exploration. Keep `just` canonical. One-poll
  Scenario E does not demonstrate a current polling defect; broader improvement
  remains a hypothesis, not a reason to add shell job wrappers now.
- **C — defer:** product work, additional MCPs, paid DCM capabilities, hardware
  integrations and broad refactors. No fifth MCP is justified by this sample.

Suggested 7.5.2 direction: a small always-required invariant layer with explicit
routes to language/security/workflow explanations, retaining pair-programming
and test safety. README should distinguish actual implemented state, intended
architecture, developer-specific setup and outstanding appliance evidence.
This document does not implement that redesign.

Raw evidence is ignored under `.local/m7.5/baseline/`: sanitized doctor output,
crash output, scenario file/call manifest and variable **names only**. No token,
credential store, OAuth data, complete environment values or private key was
printed or persisted. Only this document and the corpus were added; no source,
guidance/configuration/tooling, acceptance ledger, timeout, or polling policy
was changed. Validation is proportionate: `git diff --check` and document review,
not another complete product/acceptance run.
