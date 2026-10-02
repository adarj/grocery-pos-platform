# Codex development workflow

This is conditional workflow context behind [AGENTS.md](../../AGENTS.md), not
an instruction to load every linked document. The root constitution carries
universal safety rules; consult only the sections relevant to the task. This
policy does not change tool configuration or product behavior.

## Cheapest trustworthy path

Choose the cheapest trustworthy context/tool path: minimize unnecessary reads,
calls, duplicated analysis, tests, and polling without sacrificing correctness,
security, source verification, or human understanding. Before invoking another
specialist, state the distinct unresolved question it will answer. If there is
none, do not call it. Fewest calls regardless of evidence quality is not success.

Stop gathering context when authoritative evidence resolves the task with
confidence appropriate to its risk. Do not preload every ADR or security document
or keep browsing merely because related material exists. Use call/file/time
counts for requested evaluations or workflow investigations, not every edit.
There are no hard per-task call/file quotas. Never fabricate token measurements
or infer token savings from lines, bytes, timing, or call counts.

## Authority and evidence

| Evidence | What it establishes / limit |
| --- | --- |
| Actual source | Grocery POS implementation; inspect the relevant authoritative path |
| Tests | Expected/protected behavior; reading a test is not running it |
| ADRs | Accepted architectural rationale; consult the [index](../adr/README.md) before changing a boundary |
| Acceptance ledgers | What actually ran and passed, on which tier/environment—not everything in a plan |
| Language/runtime tooling | Semantic diagnostics or observed execution; analyzer success alone does not prove behavior |
| Structural graph | Candidate topology/impact, not security guarantees or completeness; verify source/tests |
| External documentation | Upstream behavior, not Grocery POS behavior or necessarily a pinned-version contract |

Source, tests, ADRs, and acceptance records answer different questions. Investigate
source/documentation conflicts rather than silently choosing the convenient answer.
Structured tool output is evidence to assess, not authority by itself. DCM metrics
are not correctness tests; graph results are not tests; upstream docs are not
runtime evidence. Do not use static success to skip required behavioral coverage.

## Context routes: source first, specialists when justified

Native Codex + shell + `just` are the default substrate. The four optional
specialists are qualified in the user work profile, not a mandatory pipeline:
[Dart/DCM qualification](dart-flutter-agent-tooling.md) and
[repository-context qualification](repository-context-agent-tooling.md) describe
their actual capabilities, mutation boundaries, and limitations. No fifth MCP
is part of this policy.

| Route | Trigger and action | Non-trigger / authority limit | Fallback |
| --- | --- | --- | --- |
| 0 — Known source | Known file/symbol → read relevant source and nearby tests/contracts if needed → stop | Do not search or invoke a specialist just to reconfirm a known location | Narrow search if the location proves wrong |
| 1 — Lexical discovery | Unknown location, searchable name/error/route/event/config/test description → `rg` / `rg --files` → exact path → source/tests | Locate uncertain paths once rather than repeatedly guessing; avoid whole-tree browsing | Structural discovery if hits remain ambiguous |
| 2 — codebase-memory | Genuinely unclear location, cross-cutting relationships, ambiguous lexical hits, or impact topology → verify root/relevant coverage → graph narrows → source confirms | Not required for every Racket task; missing graph callers do not prove no callers exist | `rg` + source when unavailable, stale, or incomplete |
| 3 — Dart MCP | Unresolved symbol/type/overload/signature/hover, analyzer, package-URI, or explicitly scoped runtime question | Not automatic for Dart/Flutter tasks or simple textual relationships; runtime tools are excluded by the routine allowlist and need separate qualification | Source + canonical Flutter/Dart analyzer/tests when semantic evidence is needed |
| 4 — DCM Free | Explicit complexity, coupling, nesting, maintainability, or qualified structural-quality question | Optional quality lens, not analyzer/test replacement, correctness proof, project gate, or post-edit ritual | Free CLI for qualified capabilities; defer metrics if unavailable, continue ordinary correctness work |
| 5 — External documentation | Establish installed/pinned version first → known, accessible authoritative first-party docs/source directly; Context7 may help when identity is uncertain, docs fragmented, or discovery useful | Context7 is not mandatory for external/version-sensitive questions or Grocery POS discovery; latest is not exact pinned-version evidence | Installed/versioned upstream source/help or official documentation |

Repository questions—login throttling storage, shift-close authorization, command
idempotency, transaction totals—stay local. For an upstream question such as
current Flutter/Nix/systemd behavior, first establish the installed/pinned version.
Before changing the Flutter ↔ Racket boundary, read the
[local API](../architecture/local-api.md). Prefer explicit commands and structured
errors; do not invent speculative APIs, duplicate backend semantics in Flutter,
or expose raw backend exceptions.

### Navigation and bounded excerpts

When a path is uncertain, locate it once with narrow `rg`, `rg --files`, or a
justified graph search, then read the exact path and relevant symbol/range. A
failed guess can happen; repeated neighboring guesses when search is available
are unnecessary work.

For a behavioral trace, keep the unresolved evidence links explicit—for example,
event/error → state transition → persistence → recovery → protecting test.
Once a link is established, read another file only to answer a remaining link or
verify authority, not because an adjacent model/helper looks related. Prefer exact
symbol ranges, targeted search context, and bounded sections. Expand deliberately
when insufficient; avoid overlapping broad rereads or hundreds of unrelated lines.
Apply the security-output filtering below before emitting sensitive-shaped ranges.

### Evidence behind the routes

The [CP1 baseline](m7-5-baseline.md) answered SQLite policy with 3 files/2
shell-search calls, Flutter 401 recovery with 11/4, and reset/durable retry with
10/5, without MCPs or tests. CP4's related Dart trace used 19 MCP calls, 14 shell
calls, and 14 manually inspected files versus CP1 B's 0/4/11. These were not
identical tasks or a formal regression benchmark; they demonstrate that MCP
availability does not automatically reduce exploration cost.

DCM supplied complexity, coupling, widget-nesting, and structural metrics not
provided by a clean analyzer result. Its extra value was that distinct quality
dimension, not simply more warnings. CP5 indexed 164 Racket files but observed
partial parses, three essentially unusable test parses, and some callers only
at file/module granularity. Temporal/database writer guarantees still required
source inspection: the graph locates and narrows; it does not prove security.

### Task-driven graph freshness

Watchers and auto-indexing remain disabled. Before materially depending on a
graph, confirm the repository root and ask whether relevant source/test content
has changed since the index used for the query. If yes or uncertain, use qualified
read-only status/coverage tools, notably selected-path `check_index_coverage`,
and inspect local changes. If relevant coverage is stale, refresh explicitly
using the qualified CLI procedure in the repository-context tooling document,
with the same root/cache/name, then source-verify the narrowed results.

`ready` is not fresh: CP5's renamed fixture still returned the old symbol while
status said ready; coverage detected `metadata_changed`, and explicit re-indexing
restored the result. Even fresh coverage is best-effort, not completeness proof.
Read parse gaps directly; never infer absent callers from absent graph edges,
especially in Racket. Git HEAD alone does not identify an uncommitted indexed tree.

Do not re-index because unrelated documentation changed or merely after every
edit. After source edits, refresh only if another structural query depends on
those edits. If a generic freshness difference is unrelated to the queried area,
verify that area rather than reflexively rebuilding the whole index. Do not
enable background watchers as an incidental repair.

### External versions and quota

Context7's qualified Free allowance is 1,000 calls/month; CP5 used three calls.
Determine the local version **before external retrieval**. If authoritative
first-party documentation/source is already known and directly accessible, use
it directly. Otherwise Context7 may help discover a public upstream corpus,
resolve uncertain library identity, or navigate fragmented docs. Resolve a library
once, reuse its ID, and ask one focused generic question. Check the returned
version/source. CP5 found no exact `package:http 1.6.0` corpus and received `/latest/` material;
installed pinned source supplied exact-version truth.

If exact material is unavailable, stop paraphrasing duplicate queries to coerce
a version match. Fall back to installed help/source, official versioned docs,
or other appropriate official upstream evidence. Do not query usage repeatedly
or use Context7 when installed evidence or known first-party docs already answer
the question. Necessary current-doc retrieval is legitimate; intentional use is
not quota hoarding.

### Combination, duplication, and mutation

Normally combine specialists only for different dimensions: codebase-memory
may locate a controller, then Dart MCP resolve an ambiguous type; analyzer validity
and a separately requested DCM complexity assessment are different questions.
The ritual `rg → graph → Dart → DCM → Context7` for one local question is not.

A second provider may answer substantially the same question for ambiguity,
known incomplete coverage, conflicting evidence, safety-critical independent
verification, or a different evidence class. Explain the reason when consequential;
do not automatically cross-check every answer with every tool.

Dart MCP test/fix/format/pub/app tools and DCM fix/format/baseline tools are not
blanket mutation authority. No automatic source fixes. Dependency, source, or
runtime mutations require explicit task scope. `just` remains the normal project
validation interface despite provider instructions preferring MCP tests. Optional
MCP failure must not block a simple local edit; use the fallbacks above.

## Validation: start with the changed invariant

Use TDD where practical, especially for domain behavior: identify the invariant,
write the smallest protecting test, observe the appropriate failure, implement
the smallest correction, and refactor with protection. Validation follows
behavioral blast radius, not merely file extension:

```text
changed invariant → smallest test/check that can falsify the change
  → relevant subsystem coverage
  → real-process integration when the affected boundary warrants it
  → just check when the coherent change is broadly ready and scope warrants it
  → acceptance only when qualification concerns require fresh evidence
```

Use existing `just` recipes; `just --list` is the current inventory, not another
static catalog here. A narrow underlying runner invocation is appropriate when
no recipe exposes the required focus. Do not create a parallel command surface.

| Changed concern | Proportional validation |
| --- | --- |
| Read-only research | No product tests merely for inspecting source. Execute a runtime test only if runtime evidence is needed to answer the question |
| Documentation / non-product agent configuration | Whitespace, links, privacy/path checks; parsing/startup smoke if configuration changed. Verify source/tests behind runtime claims; no ceremonial full product suite |
| Narrow Racket/domain behavior | Focused RackUnit protection → relevant subsystem → `just test-racket` when the slice is ready. Widen for HTTP/Flutter/persistence/process/packaging effects, not automatic Flutter testing |
| Rust protocol/Core/adapter work | Focused Rust tests → relevant format/Clippy checks → `just check-rust` when the slice is ready. Widen to cross-language/process validation when the affected boundary warrants it; ordinary Serde tests do not establish strict-codec or whole-M8 Tier A qualification |
| Isolated Flutter model/controller/widget | Focused Flutter tests → relevant analysis → broader Flutter suite when ready. Real-process integration if Core-boundary or recovery/auth/session semantics depend on it |
| Flutter ↔ Racket API, serialization, session, command/retry/recovery | Focused backend/client tests → subsystem suites → relevant real-process integration → `just check` when broadly ready. Mocks alone cannot establish actual HTTP/process/SQLite composition |
| Persistence/migration, journal/receipts, durability, backup/restore | Focused persistence/domain tests plus relevant real-process evidence; normally `just check` before handoff of a coherent change. Acceptance remains a separate decision |
| Credentials, session validity, authorization, approval, audit, ownership | Focused security tests plus relevant HTTP/integration coverage → `just check` when broadly ready; analyzer/DCM success is insufficient |
| Packaging/appliance/reliability | Narrow relevant package/appliance checks → wider validation as warranted. Qualification only for affected evidence concerns; no inference of physical success |

See the [integration guide](integration-testing.md) for the real-process boundary.
Report checks actually run, unavailable validation, and its consequence.

### Broad readiness versus acceptance

Run `just check` once the coherent change is broadly ready, not after every tiny
edit: focused edit/test cycles precede subsystem and warranted broad validation.
It is normally the readiness gate for cross-boundary, persistence, and security
changes, unless scope-specific documentation supplies a justified different or
stronger gate. It is not required for a research answer or documentation-only
correction. On failure, investigate causality, fix or report it; do not rerun
an unchanged failing command hoping for green. Identify flaky-test investigation
explicitly rather than hiding it in retries.

Development validation is not milestone acceptance. `just accept-m6` and
`just accept-m7` produce qualification evidence, not generic “extra thorough”
testing. Run them when the task changes the acceptance contract, changes a concern
explicitly qualified by the campaign, or prepares milestone/release qualification
needing fresh evidence—not automatically for every security edit. Do not regenerate
historical ledgers merely for unrelated changes.

Distinguish focused tests, broad repository validation, deterministic acceptance,
booted-appliance qualification, physical hardware, and destructive/power evidence.
A specification is not execution; never turn `blocked`/`not_run` into `passed`
or infer booted/physical qualification from emulation, widget tests, or SIGKILL.
The [M6](../acceptance/m6/README.md) and [M7](../acceptance/m7/README.md) records
establish actual qualification state. Destructive testing needs explicit scope,
disposable hardware, and its documented procedure, not a general test request.

## Failure, rerun, and timeout discipline

Preserve the first useful error, relevant test/process identity, and bounded
stdout/stderr diagnostics before rerunning. Determine whether implementation,
expectation, environment, or orchestration is wrong; make the smallest justified
correction. A rerun must answer a specific diagnostic question or validate a
corrective change. Do not delete/skip/rewrite legitimate tests solely to pass,
casually relax an invariant, add retries until green, or inflate a correctness
deadline to hide a deterministic failure.

Distinguish product/test correctness deadlines from outer orchestration/session
budgets. The post-M7 crash-recovery fix enlarged only the outer campaign budget;
each POS Core startup retained its 30-second readiness bound. If a healthy test
exceeds an execution wrapper's budget, adjust orchestration, not that narrower
correctness contract. A session yield is not necessarily termination: retain and
observe the existing process rather than starting another copy.

## Long jobs: start once, observe meaningfully

Short commands normally run foreground to completion; do not create polling loops.
For deterministic integration, Nix builds, acceptance, or crash/soak campaigns,
start once and observe coarsely according to expected behavior and session limits:
one observation near a known one-minute completion window may suffice; multi-minute
builds warrant meaningfully spaced observations; interactive jobs need observation
when input is required. There is no global “poll every N seconds” timer. Do not
poll every second/few seconds simply because a tool permits it.

Observe/report completion, new diagnostics, materially exceeded expected duration,
required interaction, failure, or evidence of a stall. An unchanged “still running”
message is not ordinarily useful. Keep required progress communication substantive.
Silence, an unchanged spinner, or a pause between test names is not failure. If
duration materially exceeds expectation, make one targeted diagnostic check—process
status, bounded tail, or harness state—and reassess. Do not repeatedly inspect
processes/files/logs without new reason.

Restart only for demonstrated failure, corrupted session, required configuration
change, confirmed stall/deadlock, or an intentional rerun after correction. Quiet
output or a lost UI update is insufficient; restarting destroys timing/failure
evidence. Use normal execution-session facilities, not shell sleep loops, polling
wrappers, watchdogs, repository polling settings, or test changes for agent observation.

CP1 Scenario E's `just crash-m6 3` passed in **56.78 seconds** with one initial
execution, one follow-up poll, zero unchanged updates, and zero unnecessary
restarts. Preserve/generalize that positive result; no campaign is rerun to
validate this policy. It was process-crash evidence, not physical power evidence.

## Concise collaboration and bounded output

For nontrivial work, give a short initial plan and surface early material findings,
changes, or blockers. For consequential/unfamiliar work, explain the affected
invariant, important language/architecture concept, meaningful design/security
tradeoff, and planned focused validation. Keep the developer able to explain
important decisions; implement only the agreed, independently reviewable slice.
Familiar local work needs no essay or ritual architecture recap. Do not narrate
every search/read/call or repeatedly announce unchanged jobs.

Prefer symbol ranges, relevant sections, narrow searches, output filters, and
bounded diagnostic tails to whole files/catalogs/logs. Summarize large output
rather than echoing it. CP1's oversized plugin catalog illustrates unnecessary
context expansion, not a reason to avoid necessary discovery. Final handoffs
emphasize the outcome, invariant, actual evidence/checks, limitations, changed
files, Git state, and suggested commit—not an action transcript or unrun test claims.

## Security and configuration boundaries

Credentials never belong in prompts, committed configs, logs, or baseline evidence.
Do not expose PINs, passwords, credential verifiers, private keys, bearer/approval
capabilities or digests, prohibited payment data, raw request bodies, or unsanitized
secret-bearing device/exception output. Synthetic privacy sentinels must be deliberately fake,
isolated, never copied from real secrets or into ordinary/external diagnostics.
Inspect environment names rather than values where possible; names-only inventories
belong in ignored local evidence, not committed dumps.

Public synthetic test credentials/capabilities are not live secrets, and their
display is not a credential compromise. Still treat PIN/password, bearer/session
token, approval/capability, verifier/key, and payment/authentication fixtures as
sensitive-shaped output: do not emit literal payloads unless the literal itself
is required by the task and permitted by the root security rules. Unnecessary
display is a process defect, not harmless merely because a fixture is public.

Prevent exposure **before tool output reaches model context**, not just by omitting
values from the final answer. When only location is needed, prefer filename-only
discovery such as `rg -l '<behavior-or-symbol>' relevant/path`. For security tests,
select structural/symbol/assertion ranges and reason about assertion semantics;
if irrelevant credential-shaped literals would appear, filter/redact their payloads
locally before emitting the bounded range. Do not rely on final-answer omission
after a tool has already exposed them, or build a speculative universal scrubber.

Grocery POS questions stay local. Context7 receives only minimal generic public
upstream queries: no source excerpts, internal identifiers, uncommitted design,
credentials, or security-sensitive implementation details, even for a public repo.
It is not a Grocery POS index. The local codebase-memory graph is ignored derived
source information; do not copy its database into prompts or commits. Local tools
do not make the complete Codex workflow on-device. Give external services only
necessary non-secret context; hosted services can have trust and network behavior
outside shell domain restrictions.

Review MCP installation/configuration separately; tool availability is not permission
to change it. Do not casually add trusted project Codex settings that override
selected profiles or blur work/learn separation. CP7.5.7 owns OAuth storage,
shell inheritance, TMPDIR/PUB_CACHE/analytics disposition, health/version diagnostics,
startup/catalog measurement, and tool cleanup/update hygiene. This policy changes
none of those settings, enables no watchers, and adds no diagnostic infrastructure.

## Dependencies, documentation, and human handoff

Before meaningful dependency addition/replacement, explain the needed capability,
why existing dependencies are insufficient, and security/maintenance cost. Keep
the surface small; do not update unrelated dependencies or add production/cloud
prerequisites merely because a tool exists. Update affected behavior, architecture,
and operational docs in the same authorized change. Record consequential decisions
in ADRs rather than silently replacing accepted rationale.

Usual cadence: planning → Codex checkpoint → human/ChatGPT review → developer-signed
commit → branch/PR review → squash merge. This is not mandatory ceremony for trivial
corrections or Git authorization. No commit, push, force-push, rebase, reset, merge,
history rewrite, or release without explicit instruction; preserve unrelated work
and do not stage merely for tooling. A Conventional Commit suggestion is not permission.

Future prompts should carry Goal, Scope, Key invariants, Expected areas, Acceptance,
and Non-goals; retrieve other context conditionally through the root router. Shorter
is not automatically safer: retain checkpoint-specific safety-critical/easily missed
invariants. CP7.5.8 repeats the [fixed corpus](m7-5-evaluation-corpus.md), not this
policy checkpoint. Preserve CP1 evidence unchanged; static routing rehearsal is
not benchmark execution or proof of improvement.
