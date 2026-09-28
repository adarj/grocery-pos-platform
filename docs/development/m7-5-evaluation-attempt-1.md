# M7.5 evaluation — attempt 1

This is the **initial CP7.5.8 qualification attempt**, with disposition
**HOLD / FAIL**, not the final M7.5 evaluation. Its measurements, correctness
grades, and findings remain historical evidence. CP8R was created in response;
separately authorized final requalification will produce a new
`m7-5-final-evaluation.md` and retain/reference this attempt.

Post-attempt CP8R note: after the developer-reported VM/Codex restart, the active
session tool registry independently exposed 7/4/8/2 = 21 tools, matching disk
configuration. The earlier 58-tool observation is therefore classified as a
**session/configuration-lifecycle mismatch**, not a CP7 allowlist configuration
failure. This later finding does not revise this attempt's measurements or HOLD.

## Purpose, protocol and qualification

Evaluate unnecessary context/tool work without sacrificing correctness, privacy,
evidence or developer understanding. The fixed [corpus](m7-5-evaluation-corpus.md)
and [CP1 baseline](m7-5-baseline.md) remain unchanged. A–E ran once, in order, in
the ongoing session; no nested Codex, cold-context manufacture, cache clearing,
scenario rerun, configuration tuning or graph re-index occurred.

**Qualification: HOLD / FAIL — final workflow qualification is on hold.** All
scenario answers/process results are correct, and durable structural improvements
are verified. However B incurred material unnecessary exploration, prohibited
synthetic credential literals appeared in source-read output, and this session's
live catalog did not match the configured narrowing. This sample cannot certify
the optimized setup as evaluated. No correction was made mid-benchmark.

A–D use `Date.now()` start/end boundaries (millisecond resolution), including
reasoning, tool latency and source inspection; displayed seconds are rounded.
E uses GNU `/usr/bin/time` around the unchanged project command. Inventory,
measurement bookkeeping and final readiness checks are outside scenario counts.
Exact context/token usage is **unavailable** for every scenario.

Counts follow the corpus: one meaningful shell invocation, including batching and
failed path guesses, is one call; substantive partial file reads count once per
scenario. Each documentation tool invocation counts once, including batched
retrievals, redirects and unsuccessful retrievals. Context7 calls are also external
documentation calls; those dimensions are not added into a composite score.
E counts *every* follow-up observation, including tool-wrapper resumptions.

Protocol limitation: D's official OpenAI search preceded its scenario-local SDK
version/help check. The documentation skill's source-order instruction was
incorrectly favored over the corpus's installed-first sequence.
General inventory had already established the versions, but this is not the
corpus's exact installed-first scenario sequence. It is disclosed, not rerun.

Sanitized command/read/provider/timestamp manifests and bounded E output are
ignored under `.local/m7.5/cp8/`. No raw credentials or environment values were
stored. Evidence is a manifest/summary, not a full transcript archive.

## Frozen environment

- Branch: `chore/m7-5-agentic-optimization`.
- Starting HEAD: `1d99c021228e032a949540d36b64bbd97d9a483d`; parent
  `2e1b12de99b3cceeb57a1fdb51e730431b98b3c5`. CP1–CP7 commits present.
- Initial worktree clean; approximately 39 GiB disk available.
- Installed: Codex 0.157.1, Flutter 3.41.9 stable, Dart 3.11.5 stable,
  DCM 1.39.2, codebase-memory 0.11.0. SDK MCP 0.1.2+1 remains the CP4/CP7
  protocol-qualified version; not freshly handshaken for inventory.
- Initial agent doctor exit 0; ordinary doctor exit 0 (47 OK, two warnings,
  zero missing). Personal ordinary-doctor fields were suppressed.
- User work configuration: exactly `dart`, `dcm`, `codebase_memory`, `context7`,
  optional, configured allowlists 7/4/8/2. Base and learn MCP-free.
- Live ongoing-session discovery: **27/21/8/2 = 58** tools, rather than the
  configured 21. No tools outside the intended allowlists were invoked.
  Effective managed/session provenance remains unresolved; configuration on
  disk is not proof of this session's effective tool surface.
- Three user config SHA-256 hashes were frozen and rechecked byte-identical;
  protected credential-file metadata passed. No credential contents inspected.

This is warm context: project/workflow and previous qualification knowledge,
potentially warm filesystem/OS/package caches, and available specialist tools.
No scenario-specific source was deliberately preloaded before its timer.

## Results and CP1 comparison

Each cell below shows **CP1 → CP8 (delta)**. MCP tuple order is
**Dart / codebase-memory / DCM / Context7**; these are separate provider counts,
not interchangeable costs. CP1 time approximations do not justify precise
percentage claims. No unrelated plugin-catalog discovery occurred in CP8;
CP1's separate oversized plugin discovery remains outside D documentation calls.

### A — SQLite policy: PASS

| Metric | CP1 → CP8 (delta) | Interpretation |
| --- | --- | --- |
| Unique files | 3 → 3 (0) | Same narrow authoritative evidence set |
| Shell/search | 2 → 4 (+2) | Two incorrect directory guesses added work |
| MCP providers | 0/0/0/0 → 0/0/0/0 | Specialist restraint |
| External docs | 0 → 0 | Local question stayed local |
| Tests / polls | 0/0 → 0/0 | Read-only investigation |
| Elapsed | ~28.8 s → 29.99 s (~+1.2 s) | Host observation, not a speed claim |
| Token/context usage | unavailable → unavailable | No estimate |

Inspected [connection policy](../../pos-backend-racket/pos/persistence/sqlite-connection.rkt),
[focused tests](../../pos-backend-racket/tests/sqlite-connection-policy-test.rkt)
and [ADR-0018](../adr/0018-use-wal-with-full-synchronous-durability.md).
`open-pos-sqlite-connection` establishes/verifies WAL in create mode, verifies
already-WAL state in normal read/write mode, and applies/verifies FULL=2 per
connection. Five tests protect initialization, compatible conversion, normal-open
rejection, failure cleanup/busy parameters and invalid arguments. Racket owns
policy/business decisions; SQLite supplies durability. PRAGMAs are operating
policy, not a schema migration. ADR schema-6 statements are historical.

Unnecessary work: **minor**, failed `racket/` and `src/` guesses. Missing work:
none required by the scenario; tests identified, not executed.

### B — 401 / lock / exact recovery: PASS

| Metric | CP1 → CP8 (delta) | Interpretation |
| --- | --- | --- |
| Unique files | 11 → 13 (+2) | One unrelated model read and broader exploration |
| Shell/search | 4 → 7 (+3) | Failed guesses and poorly targeted excerpts |
| MCP providers | 0/0/0/0 → 0/0/0/0 | No semantic ambiguity requiring Dart MCP |
| External docs | 0 → 0 | No external implementation query |
| Tests / polls | 0/0 → 0/0 | Protecting tests inspected only |
| Elapsed | ~51.6 s → 83.38 s (~+31.8 s) | Material exploration overhead observed |
| Token/context usage | unavailable → unavailable | No estimate |

[HttpPosCoreClient](../../flutter/apps/pos_terminal/lib/core/pos_core/http_pos_core_client.dart)
maps protected `authentication_required` 401 to same-command retryability and
clears [MemoryAuthenticationSession](../../flutter/apps/pos_terminal/lib/core/pos_core/authentication_client.dart).
[AuthenticationController](../../flutter/apps/pos_terminal/lib/features/authentication/authentication_controller.dart)
locks through the session listener;
[PosTerminalApp](../../flutter/apps/pos_terminal/lib/app/pos_terminal_app.dart)
replaces the protected Navigator while the lock screen presents login.
[CashierSessionController](../../flutter/apps/pos_terminal/lib/features/cashier/cashier_session_controller.dart)
persists before POST; a retryable failure preserves the saved exact command.
Operator-bound recovery is independent of the disposed route tree. After valid
same-operator authentication, `retryPendingCommand` executes the persisted command,
not a new ID or refreshed expected version.

Protecting evidence: client tests for bearer clearing and authentication-rejection
retryability; recovery-controller test “startup restores pending command without
network and retry uses it”; widget test for destruction of protected navigation
while preserving recovery; [real-process integration](../../flutter/apps/pos_terminal/integration/real_pos_core_test.dart)
“401 before mutation preserves exact command across reauthentication”.

Unnecessary work: **material cumulatively**—three failed directory/glob guesses,
unrelated authentication-model content, misplaced test ranges and oversized
output. No duplicated specialist queries. Missing work: none for the requested
chain. **Privacy/output lapse:** two tool responses exposed public synthetic
PIN/capability fixture literals. They were not live account credentials, and no
credential store was read, but repository rules prohibit such output regardless.
Later excerpts were redacted; the original transcript exposures were not erased or
silently reclassified as safe. Committed/local summary artifacts contain no values.

### C — reset / final writer / durable retry: PASS

| Metric | CP1 → CP8 (delta) | Interpretation |
| --- | --- | --- |
| Unique files | 10 → 10 (0) | Comparable authoritative layers |
| Shell/search | 5 → 5 (0) | Narrow source discovery; failed guesses retained |
| MCP providers | 0/0/0/0 → 0/0/0/0 | Known topology did not justify graph calls |
| External docs | 0 → 0 | Security question stayed local |
| Tests / polls | 0/0 → 0/0 | Tests inspected, not executed |
| Elapsed | ~75.7 s → 71.67 s (~−4.0 s) | No formal optimization claim |
| Token/context usage | unavailable → unavailable | No estimate |

Root CLI denies non-root use before database access.
`operator-service-reset-pin` requires an enrolled credential and hashes outside
the writer; `rotate-operator-pin!` arbitrates expected revision under IMMEDIATE,
increments revision, clears throttle, revokes related grants and appends required
audit. Authentication compares stored/session revisions and invalidates the old
session. `transaction-service` binds the authenticated revision internally.

The [command unit of work](../../pos-backend-racket/pos/persistence/transaction-command-unit-of-work.rkt)
rechecks active/enrolled/revision/permission state **after acquiring the writer**
for a fresh command. Its durable-duplicate path instead verifies actor provenance
and exact command equality first, returning the existing outcome without new
events. A later valid same-operator session can recover history; an old bearer
does not thereby gain fresh authorization or bypass authentication.

[Writer-race regression](../../pos-backend-racket/tests/transaction-command-unit-of-work-test.rkt)
denies stale revision 1 without events/receipts, accepts revision 2 once, and
recovers the exact durable command after revision 3. Authentication rotation,
root-reset CLI and real-process pending-reset tests protect adjacent layers.
The latter is pending fresh-command recovery, not by itself proof of durable
duplicate recovery; the writer regression supplies that distinct evidence.

codebase-memory was **not used**: already-known topology plus lexical search was
sufficient. No graph-dependent freshness check or index refresh was needed.
Its Racket limitations were not hidden or relied upon. Unnecessary work:
**minor**, two failed path guesses and a low-value final CLI excerpt. Missing
work: none for the requested authority/fresh-versus-durable distinction.

### D — official SDK MCP documentation: PASS, protocol caveat

| Metric | CP1 → CP8 (delta) | Interpretation |
| --- | --- | --- |
| Unique repository files | 0 → 0 (0) | Installed help and upstream material |
| Shell/search | 2 → 1 (−1) | SDK/version/help commands batched |
| MCP providers | 0/0/0/0 → 0/0/0/2 | One resolution, one query; no repetition |
| External docs | 5 → 6 (+1) | Four web invocations plus two Context7 calls |
| Tests / polls | 0/0 → 0/0 | No configuration or tests |
| Elapsed | ~65.0 s → 71.92 s (~+6.9 s) | Retrieval was not cheaper in this trial |
| Token/context usage | unavailable → unavailable | No estimate |

Installed help confirms Dart 3.11.5 / Flutter 3.41.9 and `dart mcp-server` stdio.
The [official Codex MCP page](https://learn.chatgpt.com/docs/extend/mcp)
supports a server table with `command = "dart"`, `args = ["mcp-server"]`.
This is a documented configuration shape, **not configured by CP8**; existing
work-only ownership remains repository policy.

The [official Flutter guide](https://docs.flutter.dev/ai/get-started)
now recommends a Codex plugin bundle and reflects Flutter 3.47 (updated
2026-09-14), newer than installed 3.41.9. Both old Flutter/Dart MCP documentation
URLs redirect there. No bundle, rules or skills were installed.

The [official server README](https://github.com/dart-lang/ai/blob/main/pkgs/dart_mcp_server/README.md)
still labels the package experimental/WIP, gives a 3.9-era minimum SDK and
recommends roots-capable clients. Installed help requires no experimental flag
and exposes no roots-fallback flag. The README's older Cursor link contains
flags absent from this installed help; its current consolidated tool catalog is
not the installed SDK catalog. Root registration/session setup remains the
previously qualified `add_roots` route, not newly negotiated in this scenario.
Do not infer pinned behavior from upstream `main`.

Context7 resolved `/dart-lang/sdk` (high source reputation), but its single query
returned **no matching documentation** and no exact SDK-version corpus.
Official upstream pages plus installed help supplied the answer. No repeated
resolution/paraphrase query. Two generic upstream-only Context7 calls consumed;
Free allowance 1,000/month, remaining balance unknown, no balance query.

Unnecessary work: **minor to material output overhead** from HTML navigation,
redirected repeated material and an unproductive Context7 route. Missing work:
no required answer omitted; exact current-doc/installed-version identity is
explicitly not claimed. Installed-first ordering caveat is recorded above.

### E — focused process crash: PASS

| Metric | CP1 → CP8 (delta) | Interpretation |
| --- | --- | --- |
| Files / shell calls | 0/1 → 0/1 | Same canonical command, time wrapper only |
| MCP providers / external docs | 0/0/0/0 and 0 → unchanged | No specialist needed |
| Tests started | 1 → 1 | Three-iteration campaign, not three launches |
| GNU wall time | 56.78 s → 57.09 s (+0.31 s) | Normal host variation; no speed claim |
| Follow-up observation calls | 1 → 3 (+2) | One process poll, two wrapper resumptions |
| Polls providing new information | 1 → 1 | Completion/diagnostic output |
| Unchanged still-running updates | 0 → 0 | No narration spam |
| Unnecessary restarts | 0 → 0 | Started once |
| Exit / correctness | 0 / passed → 0 / PASS | All three iterations passed |
| Token/context usage | unavailable → unavailable | No estimate |

Command: `just crash-m6 3`, unchanged, wrapped in GNU time. Initial execution
yielded after one second. One process-session follow-up waited for completion;
the JavaScript execution wrapper itself yielded, requiring two additional
`wait` calls (one empty, one completion). Strict corpus counting includes all
three, rather than reporting only the lower-level poll. Two intermediate
observations added no information; the short empty wrapper wait was avoidable.
Unnecessary work: **minor observation overhead**, worse than CP1's one-call
observation. No diagnostic was discarded or rerun. This is POS Core process
SIGKILL evidence, **not physical power-loss qualification**. No timeout changed.

CP8R interpretation note: the corpus's observation metric remains **3**.
Wrapper/session resumptions count under that metric but are analytically distinct
from discretionary agent polling of the underlying process. This clarification
does not change the recorded count, timing, or assessment above.

## Structural improvements versus observed operation

| Surface | Earlier value | Verified result | Meaning/limit |
| --- | --- | --- | --- |
| Always-loaded AGENTS | 290 lines / 8,084 bytes | 120 lines / 6,629 bytes | 170 fewer lines, 1,455 fewer bytes; invariants/router retained, not token savings |
| Configured tools | 58 before CP7 | 21: 7/4/8/2 | Disk configuration verified; live session still 58 |
| Local schema proxy | 74,885 bytes | CP7 measured 18,544 bytes | Serialized Dart+DCM+CBM definitions; excludes Context7/wrappers; not freshly remeasured or model tokens |

README now distinguishes implemented cash/local-first/security/appliance
foundations from deferred work and physical qualification. Host-neutral setup
preserves scoped VM/nixGL notes. Placeholder recipes/stale VS Code tasks were
removed; `just` remains truthful and canonical. Privacy-conscious agent doctor
is separate from ordinary doctor. Tools and machine-local configuration have
explicit ownership, work/base/learn separation and manual version qualification.
Branch diff inspection confirms no product/source/test/dependency/CI change.

No excluded Dart/DCM capability was needed by A–E. This supports restraint but
does **not** prove live allowlist enforcement: only Context7 was invoked, and
the ongoing session exposed the wider catalogs. No optional-server startup
failure blocked source work; CBM/DCM/Dart readiness and isolated startup cost
were not tested by these scenarios. CP7's CBM median 2.444 s is historical
direct-handshake evidence, not inferred from a model turn or rebenchmarked.

## Dimension assessment

| Dimension | Assessment | Evidence |
| --- | --- | --- |
| Correctness / evidence | Maintained | A–E correct; source/test contracts and version caveats preserved |
| Context selection | Regressed in this sample | B read 13 versus 11 files, unrelated content/oversized excerpts; A/C comparable |
| Tool routing | Maintained, not proven improved | No MCP-first behavior in A–C; D used two intentional but unproductive Context7 calls then official fallback |
| Duplicate/repetitive work | Regressed in this sample | Failed path guesses, repeated redirected docs and two extra E observation calls |
| Validation proportionality | Maintained | A–D no tests; E only requested campaign; final broad gate outside corpus |
| Long-job behavior | Regressed narrowly | Start-once/no-spam maintained, but three observation calls versus one |
| Security/privacy | Regressed in output discipline | Synthetic credential literals appeared in two responses; no live credentials/source sent externally or permissions changed |

CP6 specialist triggers and stop/authority rules mostly worked. The sample
violated its output-bounding and cheapest-path intent; available providers did
not solve lexical navigation mistakes. No evidence that the configured 21-tool
policy was too restrictive. No formal graph-value conclusion is possible from
an unused graph. No arbitrary aggregate score or token-saving claim is made.

## Final validation

Final checks are recorded after artifact creation; broad readiness is outside
A–E and is not acceptance. Initial and final diagnostic checks passed.

- `just agent-doctor`: exit 0; configured four-server 7/4/8/2 topology,
  optional specialists, base/learn separation, versions and protected metadata
  pass. Its expected offline authentication-status warning remains; D retrieved
  through Context7 successfully, without proving every effective config layer.
- `just doctor`: exit 0; 47 OK, two warnings, zero missing. Personal fields
  suppressed before sharing; no raw output copied into evidence.
- `just check`: **one invocation, exit 0**; clean Flutter analysis,
  **605 Racket**, **265 Flutter**, **34 real-process integration** tests passed.
  Test-emitted audit/denial/cleanup diagnostics were retained; no failed gate
  was hidden or rerun. Its internal crash test is ordinary broad validation,
  not another execution of benchmark Scenario E.
- `git diff --check` and supplemental whitespace checking of the new untracked
  document pass; 13 relative links resolve; privacy/path checks pass.
  Exact scope: this one untracked document, no staged files or tracked edits;
  evidence/graph state ignored. All three config hashes match the frozen start.

No M6/M7 acceptance campaign is run. CP1 evidence/corpus, CP2 root guidance,
qualification/policy docs, product source/tests, schema v12/migration lineage,
CI, flake and dependencies remain frozen. Only this evaluation document is
intended tracked scope; local manifests/graph state remain ignored and unstaged.
No commit, push, staging, merge, rebase, reset, PR, release or history rewrite.

## Limitations and retained recommendations

- CP1/CP8 are warm ongoing-session single samples; CP8 knows more project
  structure, caches may be warmer, and MCP availability differs by design.
  B incidentally inspected a reset integration case later used in C; that
  cross-scenario warmth was not removed, and reads count separately per scenario.
  Documentation/tooling changed; product behavior did not.
- Timing is host observation, not statistical benchmarking; five scenarios
  are a small representative corpus, calls have unlike costs, tokens unavailable.
- Configured versus effective live MCP catalogs differ. Isolate that provenance
  in a separately authorized follow-up, not by changing this benchmark.
- Racket graph extraction is incomplete (CP5: 164 Racket files, partial parses,
  three essentially unusable test parses, some module-only relations).
  Graph `ready` is not fresh; graph is never security/writer authority.
- DCM contributes quality metrics but exact Free licensing LOC headroom remains
  unavailable; static metrics/analyzer success are not behavioral proof.
- Context7 exact-version coverage is not guaranteed; this query yielded no
  matching MCP docs. Installed help/versioned source remains the fallback.
- Protected OAuth file storage is not an OS keyring; broader shell inheritance
  remains a compatibility compromise. No storage/permission/network change here.
- Agent doctor checks configuration/metadata offline, not every live MCP or
  remote-auth operation. No quota consumed merely for inventory or diagnostics.

Retain direct-source/lexical-first routing, distinct-question specialist use,
source/test authority, task-driven graph freshness, explicit version caveats,
proportional validation and start-once/no-spam execution. Do not add tools or
change policy merely because this sample is disappointing.

Findings: **A** — investigate live catalog provenance and correct unsafe excerpt
handling before final workflow qualification; resolve benchmark-fidelity/output
regressions in a narrowly authorized follow-up. **B** — path discovery and bounded
web reads, wrapper-aware sparse observation, and exact-version documentation
coverage merit follow-up. **C** — more MCPs, paid DCM, auto-watch/index, automatic
updates, product refactors and physical qualification remain out of scope.

The unchanged evaluated setup is not silently upgraded to PASS after recording
these findings. Any corrected setup needs separately authorized qualification;
old measurements do not qualify a newly changed system.
