# M7.5 CP8Q — Final agentic workflow requalification

Observed 2026-09-28 in the fresh post-remediation top-level conversation. Evaluate
workflow correctness, unnecessary work, privacy and structural optimization;
this is not new product, appliance or physical-hardware acceptance.

## Purpose and retained history

The [fixed corpus](m7-5-evaluation-corpus.md) is the scenario/metric authority.
Three distinct observations remain intact:

1. [CP1](m7-5-baseline.md): original pre-optimization baseline on
   `main`, HEAD `7aa1df83a539ca761da331ee6a1db4ed269f7223`.
2. [CP8 attempt 1](m7-5-evaluation-attempt-1.md): **HOLD / FAIL**, starting at
   `1d99c021228e032a949540d36b64bbd97d9a483d`. Correct scenario answers did
   not overcome the live-catalog mismatch and unsafe fixture output.
3. CP8Q: this fresh-session final requalification, starting at
   `1313662b152090461872b724c8396564809c7f20` —
   `docs(dev): remediate agent workflow qualification`.

Neither historical artifact nor the corpus is rewritten by this evaluation.
Final disposition: **CONDITIONAL PASS**, supported by the readiness results below.

## Methodology and session provenance

- Repository: `adarj/grocery-pos-platform`; branch:
  `chore/m7-5-agentic-optimization`. Starting and final HEAD are the same
  remediation commit above; initial worktree was clean.
- The current thread's first session-metadata record, matched to its current
  thread/session identifiers, records creation at **2026-09-28T03:00:39.943Z**.
  The remediation commit timestamp is **2026-09-28T02:51:06Z**. This establishes
  conversation creation after remediation, independently of process start time.
- The source-blind Pre-CP8Q gate completed first: clean exact branch/HEAD;
  independently matching configured/live catalogs; agent doctor exit 0;
  zero corpus/product-source reads, specialist/documentation calls, tests or
  repository modifications. CP8Q was not begun during that gate.
- This task then read the three committed benchmark documents and the remediated
  workflow. Historical summaries therefore supplied locations and prior answers
  before scenario timers; **no A–E product/test source was preloaded before this
  task**. This is source-blind preflight, not answer-blind execution.
- Exact corpus prompts A–E were evaluated once each, in order, with no recursive
  Codex, subagent, scenario rerun, configuration tuning or cache clearing.
  No source/configuration edit was part of A–D.
- CP1 and attempt 1 used warm ongoing conversations; CP8Q uses this fresh thread.
  Filesystem, package and OS caches may still be warm. B and C inspect different
  relevant sections of the same integration file, giving C some ordered-session
  context warmth. No artificial cold-start conditions were created.
- Unique files count substantive content inspection, including partial ranges;
  filename-only discovery, administrative files and indirect test reads are
  excluded. Each shell invocation counts once; batching remains visible in the
  ignored manifest. Actual provider calls, external retrieval invocations and
  every explicit job follow-up are counted separately.
- A–D elapsed values use host `Date.now()` boundaries with millisecond
  resolution, including reasoning, reading and tool latency; displayed precision
  is not a performance guarantee. A's answer boundary also includes reasoning
  about preparing safe later excerpts; its measured duration is retained without
  subtracting that tail. E uses GNU time around the unchanged canonical command.
  Inventory, bookkeeping and final validation are outside scenario call counts.
- Exact context/token usage: **unavailable**, for every scenario and the whole
  evaluation. No estimates, token savings or aggregate cost score are inferred.

Sanitized command/read/tool/result manifests, exact prompts and frozen hashes are
ignored under `.local/m7.5/cp8q/`. A local bounded reader omits irrelevant quoted
fixture payloads before output reaches model context. Its preparation is
administrative, outside scenario execution. The first manifest-save process was
rejected before launch by the OS argument-size limit; saving through the file-edit
tool resolved that administrative problem. No scenario was repeated or environment
setting changed. Full conversation/token accounting remains unavailable.

## Environment and live-tool snapshot

The same work-profile conversation that passed preflight was retained. Observed
architecture/kernel: aarch64, Linux `7.2.7-200.fc44.aarch64`. Installed tools:
Codex 0.157.1, Flutter 3.41.9 stable, Dart 3.11.5 stable (`linux_arm64`),
DCM 1.39.2, codebase-memory 0.11.0. Scenario D independently checked SDK versions
before external lookup. The Nix Flutter wrapper reports a synthetic framework
revision/date; that is not a trustworthy upstream source-commit identity.
Historical CP4/CP7 MCP protocol version 0.1.2+1 was not freshly handshaken here.

| Provider | Configured | Live before corpus | Live after corpus | Difference |
| --- | ---: | ---: | ---: | ---: |
| Dart | 7 | 7 | 7 | 0 |
| DCM | 4 | 4 | 4 | 0 |
| codebase-memory | 8 | 8 | 8 | 0 |
| Context7 | 2 | 2 | 2 | 0 |
| **Total** | **21** | **21** | **21** | **0** |

Configured evidence came from sanitized local Codex CLI list/get output;
live evidence came independently from the active `ALL_TOOLS` registry. All
expected names match, including Context7's hyphen-to-underscore callable-name
normalization. No missing/unexpected specialist names, broad Dart
test/fix/format/pub/app/runtime tools, or DCM fix/format/baseline tools appear.
Base and learn remain MCP-free; work has exactly the four intended optional
providers. No fifth provider was added.

Byte-identical base/work/learn config hashes preserve allowlists, permissions,
profile/shell/network/startup and required/optional policy. Frozen AGENTS,
workflow, agent-doctor and benchmark-document hashes also match; agent-diagnostics
matches starting HEAD. No TMPDIR/PUB_CACHE/analytics/authentication setting was
changed, no permission widened, and no watcher/auto-index or graph refresh was
enabled or invoked. Configured policy and live catalog are distinct evidence;
agent doctor alone proves neither live narrowing nor provider execution health.

## Attempt 1 and CP8R remediation

Attempt 1 exposed **58 live tools** despite a configured 21. Its B exploration
read 13 files with seven shell calls, three failed path/glob guesses, unrelated
model content and poorly targeted excerpts. Two responses emitted public
synthetic PIN/capability payloads. These were output violations, not live-secret
compromise; the historical record remains unchanged.

D additionally put an OpenAI documentation search before its scenario-local
SDK check and spent two unproductive Context7 calls. E maintained start-once and
no-spam behavior, but counted three follow-ups: one process poll and two wrapper
resumptions. These causes justify the retained historical HOLD.

CP8R clarified locate-once navigation, explicit unresolved evidence links,
deliberate excerpt expansion, pre-output fixture filtering, installed-first
direct first-party documentation routing, and wrapper-aware observation
classification. It recorded the post-restart 21-tool finding as a
session/configuration-lifecycle mismatch rather than an allowlist-file failure.
The fresh preflight and this unchanged session verify that lifecycle correction.
CP8Q measures the committed policy; it does not edit it after observing results.

## CP8Q scenario metrics

MCP tuple order throughout: **Dart / codebase-memory / DCM / Context7**.
No other MCP/app provider was called. Documentation calls include retrieval and
find invocations; they are not interchangeable with shell or provider counts.

| Scenario | Correctness | Unique files | Shell/search | MCP tuple | External docs | Tests started | Follow-ups | Still-running updates | Elapsed seconds |
| --- | --- | ---: | ---: | --- | ---: | ---: | ---: | ---: | ---: |
| A | PASS | 3 | 1 | 0/0/0/0 | 0 | 0 | 0 | 0 | 63.243 |
| B | PASS | 12 | 6 | 0/0/0/0 | 0 | 0 | 0 | 0 | 174.363 |
| C | PASS | 10 | 6 | 0/0/0/0 | 0 | 0 | 0 | 0 | 133.102 |
| D | PASS, version caveats | 0 | 1 | 0/0/0/0 | 2 | 0 | 0 | 0 | 69.924 |
| E | PASS | 0 | 1 | 0/0/0/0 | 0 | 1 | 1 | 0 | 57.28 |

### A — production SQLite connection policy

Source verified in [sqlite-connection.rkt](../../pos-backend-racket/pos/persistence/sqlite-connection.rkt):
`establish-or-verify-wal!` establishes/verifies WAL in create mode and only
verifies existing WAL on normal read/write opens. `apply-and-verify-per-connection-policy!`
sets FULL and verifies effective value 2, then verifies foreign keys and the
checkpoint threshold. `open-pos-sqlite-connection` supplies explicit busy
parameters and disconnects after establishment/verification failure.

The five [focused tests](../../pos-backend-racket/tests/sqlite-connection-policy-test.rkt)
protect fresh initialization, compatible conversion preserving events/migrations,
normal-open rejection, failure cleanup/busy parameters and invalid arguments.
[ADR-0018](../adr/0018-use-wal-with-full-synchronous-durability.md) explains the
tradeoff: Racket chooses application/connection policy; SQLite supplies local
durability. PRAGMAs do not become business semantics or schema migrations.
The ADR's schema-v6 statement is historical; the focused test expects v12.
No physical power-loss result is inferred from selecting FULL.

Three exact known paths were inspected in one bounded shell batch. No specialist
or test execution was needed. Unnecessary work: **none**. Missing work: **none**.

### B — 401, lock and exact pending-command retry

[HttpPosCoreClient](../../flutter/apps/pos_terminal/lib/core/pos_core/http_pos_core_client.dart)
calls `_serverFailureFrom` with same-command preservation enabled for command
POST errors. A 401 `authentication_required` produces `retrySameCommandId=true`
and clears [MemoryAuthenticationSession](../../flutter/apps/pos_terminal/lib/core/pos_core/authentication_client.dart).
[AuthenticationController](../../flutter/apps/pos_terminal/lib/features/authentication/authentication_controller.dart)
listens for that loss and locks. [PosTerminalApp](../../flutter/apps/pos_terminal/lib/app/pos_terminal_app.dart)
replaces the protected Navigator identity; [RegisterLockScreen](../../flutter/apps/pos_terminal/lib/features/authentication/register_lock_screen.dart)
presents login and receives the same cashier controller after authentication.
UI teardown is presentation protection, not server authorization.

[CashierSessionController](../../flutter/apps/pos_terminal/lib/features/cashier/cashier_session_controller.dart)
saves the operator-bound command before POST. Retryable failure leaves the saved
record intact and retains that command in pending state. `retryPendingCommand`
requires recovery ownership and passes the existing command to execution without
a new ID or refreshed expected version.
[PersistedCashierSession](../../flutter/apps/pos_terminal/lib/features/cashier/cashier_session_store.dart)
serializes the pending typed command and decodes its original ID/version;
[FileCashierSessionStore](../../flutter/apps/pos_terminal/lib/features/cashier/file_cashier_session_store.dart)
writes, flushes and renames the local record. This recovery file is not
authoritative transaction truth or a stored bearer capability.

Protecting tests inspected:

- [HTTP client](../../flutter/apps/pos_terminal/test/core/pos_core/http_pos_core_client_test.dart):
  protected 401 clears memory while 503 retains it; authentication rejection
  preserves exact-command retryability.
- [Recovery controller](../../flutter/apps/pos_terminal/test/features/cashier/cashier_session_recovery_controller_test.dart):
  startup restores without network; retry uses the same object and allocates
  zero command/transaction IDs.
- [Widgets](../../flutter/apps/pos_terminal/test/widget_test.dart): manual lock
  retains recovery; clearing memory destroys protected navigation and operator
  switch reloads presentation while recovery remains stored.
- [Real-process integration](../../flutter/apps/pos_terminal/integration/real_pos_core_test.dart):
  “401 before mutation preserves exact command across reauthentication” checks
  saved-command equality, original expected version, original command ID and
  no new ID allocation after same-operator reauthentication.

Dart MCP was **not used**: textual relationships and assertions resolved the
question without an unresolved type/signature/semantic ambiguity. No failed
path guesses or unrelated authentication-model read occurred. The extra
lock-screen source closes an explicit presentation link. Unnecessary work:
**minor**—one mistaken login range selected PIN-change code, and bounded test
excerpts spilled into adjacent cases. These were retained and corrected, not
hidden. Navigation materially improved over attempt 1; it was not perfect.
Missing work: **none**. No fixture payload was emitted.

### C — credential reset, final writer and historical recovery

[Root CLI](../../pos-backend-racket/scripts/operator-auth.rkt) rejects non-root
before opening the selected database and reads PIN input from stdin.
[operator-service-reset-pin](../../pos-backend-racket/pos/application/operator-service.rkt)
requires enrollment and computes the new hash outside the writer.
[rotate-operator-pin!](../../pos-backend-racket/pos/persistence/sqlite-operators.rkt)
arbitrates expected revision under IMMEDIATE, increments it, clears throttle,
revokes related approval grants and appends required audit atomically.
[Authentication service](../../pos-backend-racket/pos/application/authentication-service.rkt)
compares stored/session revisions, invalidates an obsolete session and constructs
an internal principal from current security state.
[commit-plan](../../pos-backend-racket/pos/application/transaction-service.rkt)
binds that authenticated revision internally, rather than accepting a UI claim.

The [command unit of work](../../pos-backend-racket/pos/persistence/transaction-command-unit-of-work.rkt)
acquires its IMMEDIATE writer transaction before deciding the final result.
For an unused command, `fresh-actor-still-authorized?` checks active identity,
enrolled credential, matching revision and transaction permission before writing.
An already-authenticated old-revision request cannot commit a fresh mutation
after reset wins that writer race.

For a durable duplicate, actor/approval provenance and exact typed-command
equality are checked before stream reads and fresh-command authorization. The
existing original outcome is returned without new events. A later valid session
for the same actor can recover it; the old bearer still fails authentication.
This does not turn a receipt into an authoritative transaction snapshot/replay
input, refresh expected version or reauthorize history as a new mutation.

Protecting evidence: [root CLI tests](../../pos-backend-racket/tests/operator-auth-cli-test.rkt)
for non-root-before-DB and enrolled-only reset/no PIN output;
[authentication tests](../../pos-backend-racket/tests/authentication-service-test.rkt)
for revision invalidation/current authoritative state;
the [controlled writer-race test](../../pos-backend-racket/tests/transaction-command-unit-of-work-test.rkt)
denying revision 1 with zero events/receipts/attributions, accepting revision 2
once, then recovering the same durable command at revision 3 with one event and
one receipt. [Integration tests](../../flutter/apps/pos_terminal/integration/real_pos_core_test.dart)
protect root-reset bearer revocation and exact pending-command recovery. The
pending integration command is **not yet durable**; the writer regression supplies
the separate durable-outcome recovery evidence.

codebase-memory was **not used**: filename discovery and authoritative symbols
resolved topology. No graph-dependent claim, freshness check or refresh was
needed; graph absence/readiness was never treated as security authority.
Unnecessary work: **minor**—initial overlapping filename discovery and a broad
filtered symbol scan (332 lines, with a small truncated tail). The safe SQL
expansion was necessary: blanket string omission initially hid revision-update
actions, so only SQL structure with value literals omitted was revealed.
Missing work: **none**. Ten relevant files were substantively inspected.

### D — exact installed SDK versus current official MCP guidance

The first scenario action checked **Flutter 3.41.9 / Dart 3.11.5**, then installed
`dart mcp-server --help` and Codex registration help. External lookup followed.
Installed help identifies a stdio server, SDK selectors (`--dart-sdk`,
`--flutter-sdk`), tool-set/exclusion controls and a protocol-traffic log option.
No experimental enablement or roots-fallback flag appears in this installed
help; protocol logging would need privacy controls and was not enabled.

[Official Codex MCP documentation](https://learn.chatgpt.com/docs/extend/mcp?surface=cli)
documents STDIO command/args tables and CLI registration. Together with installed
help, the applicable invocation/configuration shape is:

```toml
[mcp_servers.dart]
command = "dart"
args = ["mcp-server"]
```

The corresponding generic registration command is
`codex mcp add dart -- dart mcp-server`. Neither form was applied here; the
qualified work-only allowlist/configuration remains unchanged.

The [current Flutter guide](https://docs.flutter.dev/ai/get-started) recommends
a Codex plugin bundle but reflects **Flutter 3.47**, updated 2026-09-14. The
[official upstream README](https://github.com/dart-lang/ai/blob/main/pkgs/dart_mcp_server/README.md)
labels the package experimental/WIP, gives a 3.9-era minimum, recommends
Tools/Resources/Roots-capable clients, and says the older experimental flag is
removable on stable 3.9+. Its `main` tool catalog/older client examples are not
the exact installed 3.11.5 contract. Root management remains the previously
qualified add/remove-roots route; exact client/server roots negotiation was
not reprobed or inferred from absence of a help flag.

Two direct official documentation calls: one batched open of those three pages,
then one batched find for relevant configuration/version/roots/status sections.
No failed retrieval or redirect was reported; no external plugin discovery,
network escalation or Context7 call occurred. Known first-party sources answered
the question, leaving no distinct discovery question for Context7. Installed
help supports pinned invocation; current docs support current guidance, with
drift explicitly preserved. Unnecessary work: **minor**—the initial long HTML
response emitted 824 navigation lines before the requested content. Missing
work: **none within the prompt**; exact protocol roots negotiation remains an
explicit operational caveat rather than a claim of pinned-version verification.

One Codex documentation find excerpt also returned unrelated HTTP-authentication
options with clearly illustrative variable names and a generic authentication
placeholder. That public placeholder echo is retained as minor unrelated
documentation output, distinct from usable credentials or Grocery POS fixture
payloads. Its value is not copied into this document; the original tool response
remains in the ignored manifest. Narrower retrieval would avoid that noise.

### E — unchanged focused process-crash campaign

| Observation | CP1 | Attempt 1 | CP8Q |
| --- | --- | --- | --- |
| Command | `just crash-m6 3` | same | same |
| Exit status | 0 | 0 | 0 |
| GNU wall-clock seconds | 56.78 | 57.09 | **57.28** |
| Tests started | 1 | 1 | **1** |
| Total follow-up observations | 1 | 3 | **1** |
| Discretionary agent polls | 1 | 1 | **1** |
| Tool-wrapper/session resumptions | 0 | 2 | **0** |
| Observations with new information | 1 | 1 | **1** |
| Still-running updates | 0 | 0 | **0** |
| Unnecessary restarts | 0 | 0 | **0** |

The canonical command ran once under GNU time, with no iteration/timeout changes,
sleep/poll wrappers or restart. Initial normal execution yielded a process
session; one `write_stdin` observation with a 50-second window returned completion.
The ordinary execution wrapper stayed available for that call; there were no
additional wrapper waits. All three iterations passed (one test launch, not
three launches). The +0.50 s versus CP1 is an observation, not a regression claim.
Every follow-up is counted; classifications do not lower the raw count.
Unnecessary work: **none**. Missing work: **none**. This is real POS Core process
SIGKILL evidence, **not physical power-loss qualification**.

## Comparable CP1 / attempt-1 / CP8Q results

Cells retain all three measurements; deltas are CP8Q minus CP1 in the same unit.
Timing deltas are approximate because CP1 A–D times were rounded observations.

| Scenario | Files CP1 → Attempt 1 → CP8Q (delta) | Shell/search CP1 → Attempt 1 → CP8Q (delta) | Docs CP1 → Attempt 1 → CP8Q (delta) | Seconds CP1 → Attempt 1 → CP8Q (delta) |
| --- | --- | --- | --- | --- |
| A | 3 → 3 → 3 (0) | 2 → 4 → 1 (−1) | 0 → 0 → 0 (0) | ~28.8 → 29.99 → 63.243 (~+34.4) |
| B | 11 → 13 → 12 (+1) | 4 → 7 → 6 (+2) | 0 → 0 → 0 (0) | ~51.6 → 83.38 → 174.363 (~+122.8) |
| C | 10 → 10 → 10 (0) | 5 → 5 → 6 (+1) | 0 → 0 → 0 (0) | ~75.7 → 71.67 → 133.102 (~+57.4) |
| D | 0 → 0 → 0 (0) | 2 → 1 → 1 (−1) | 5 → 6 → 2 (−3) | ~65.0 → 71.92 → 69.924 (~+4.9) |
| E | 0 → 0 → 0 (0) | 1 → 1 → 1 (0) | 0 → 0 → 0 (0) | 56.78 → 57.09 → 57.28 (+0.50) |

MCP counts are 0/0/0/0 throughout CP1/CP8Q; attempt 1 D alone is 0/0/0/2.
Tests started remain A–D=0 and E=1 in all three samples. A–D follow-ups and
still-running updates remain zero; E's full comparison is above. Token/context
usage remains **unavailable** in every sample. CP1 D's one separate oversized
plugin-catalog discovery remains outside its five documentation calls; CP8Q has
zero such discovery.

There is **no demonstrated universal runtime or call-count improvement**.
A–C took materially longer in this fresh-thread sample. B/C also exceed CP1's
shell counts, and B reads one extra relevant presentation file. Safe filtering,
explicit evidence closure and fresh-context reasoning contribute work; the
sample cannot isolate those effects from host/harness/model variation or assign
their exact causal shares. No duration is discounted or converted to cost.
B navigation/privacy and D routing improve relative to the failed attempt;
those concrete corrections do not erase worse observed timings.

## Unnecessary and missing work

| Scenario | Unnecessary-work classification | Observed unnecessary work | Missing-work classification |
| --- | --- | --- | --- |
| A | none | None in the source/test route; elapsed boundary caveat retained | none |
| B | minor | Mistargeted login range and small adjacent-test spillovers | none; all six behavioral/evidence links closed |
| C | minor | Overlapping filename discovery and broad/truncated symbol output | none; essential SQL actions deliberately verified after filtering |
| D | minor | Initial HTML navigation and unrelated public authentication-placeholder output | none within scope; exact roots negotiation caveat explicit |
| E | none | No unnecessary observation/restart/update | none |

No source claim relies only on filenames, a graph, analyzer success or a test
title. Protecting assertions and authoritative code were inspected. Reading
tests is not presented as running them. No latest documentation was silently
treated as pinned source, security distinction omitted, failed scenario command
ignored, or output violation concealed. The administrative storage failure was
investigated separately and is not assigned to a scenario.

## Structural optimization evidence

| Surface | Earlier evidence | Current evidence | Meaning and limit |
| --- | --- | --- | --- |
| Always-loaded root guidance | CP1: 290 lines / 8,084 bytes | Measured: **120 lines / 6,629 bytes** | **Reduction in always-loaded repository guidance**: 170 lines / 1,455 bytes; not token savings |
| Specialist tool surface | Pre-CP7 and attempt-1 live: 58 | Configured/live: **21**, 7/4/8/2 | 37 fewer exposed tools, now independently verified in this active session |
| Three-local-server schema | CP7: 74,885 bytes | Preserved CP7: **18,544 bytes** | Serialized schema byte proxy; excludes Context7/wrappers; not freshly remeasured and not token usage |

Root guidance retains authority, money/idempotency, security, validation and Git
invariants while routing conditional detail. Source/test/dependency/CI/schema and
acceptance domains were not changed for this requalification.

## Routing, allowlists and workflow dimensions

The committed workflow operated naturally: known-source/lexical routes answered
A–C; installed-first first-party documentation answered D; canonical `just`
answered E. No provider was called for its own sake. No excluded capability was
genuinely needed; 7/4/8/2 sufficed for this corpus. There is no evidence here that
policy is too restrictive. Minor excerpt spillovers show continued need to
apply its bounding/stop rules; no policy edit is justified by this one sample.

| Dimension | Classification | CP1 / attempt-1 / CP8Q evidence |
| --- | --- | --- |
| Correctness / evidence | maintained | All three samples preserve authoritative/test chains; CP8Q explicitly separates C fresh mutation/durable recovery and D version drift |
| Context selection | improved | B 13 → 12 versus attempt 1; unrelated model removed and exact paths used; A/C file counts unchanged. B still exceeds CP1's 11 and minor spillovers remain |
| Tool routing | improved | D installed-first restored; unproductive Context7 2 → 0 and docs 6 → 2; A–C source-first restraint maintained from CP1 |
| Duplicate/repetitive work | improved | Failed A/B/C path guesses eliminated; E 3 → 1 total observations versus attempt 1; B/C shell counts still exceed CP1 and minor output overhead persists |
| Validation proportionality | maintained | A–D inspect without test launches; E starts only the requested campaign; broad gate is separately required branch validation |
| Long-job behavior | maintained | CP1 start-once/no-spam/one informative observation retained; attempt-1 wrapper overhead absent, without changing raw counting |
| Security/privacy output discipline | improved | Attempt-1 fixture exposures 2 responses → 0; local pre-output filtering, no secret-store contents or internal Context7 queries |
| Configuration/tool-surface hygiene | improved | Attempt-1 live mismatch 58 versus 21 resolved to byte-stable configured/live 21 in the proven fresh session |

These classifications describe evidence dimensions, not a score. The materially
slower A–C observations preclude a universal latency improvement claim. None of
the four live specialists was executed, so narrowed discovery and unobstructed
source work do **not** prove every provider's health, startup latency, exact-version
coverage, semantic utility or failure fallback. No graph-value/DCM-quality
conclusion is drawn from unused tools.

## Security and privacy assessment

No real credentials, usable bearer/capability payloads or credential-store contents
were exposed or stored. No unnecessary Grocery POS synthetic credential/capability
literals appeared in source/test output. The bounded reader filtered them
locally before tool responses; when it hid useful SQL, only SQL structure was
expanded with value literals still omitted. Ordinary doctor personal/environment
values are suppressed before output or evidence persistence.

D's generic public documentation authentication placeholder is recorded above,
without its literal value. It is classified as unrelated illustrative output,
not a usable credential or a repeated repository sensitive-fixture exposure.
That classification and the original response remain reviewable; it is not erased
or used to claim perfect output bounding.

No Grocery POS source, identifiers or security implementation went to Context7
(zero calls); direct web requests contain only public upstream URLs/search terms.
No auth/network/permission policy was widened. Local evidence remains ignored;
no graph database was copied, queried, refreshed or committed. Model/hosted-tool
use is not described as an entirely on-device workflow. The historical fixture
violation is retained as distinct from live-secret compromise.

## Final repository validation

Executed after A–E and artifact creation, in the requested order:

- `git diff --check`: exit **0**. Supplemental checking of the new untracked
  document found no trailing whitespace, a final newline and **28 valid relative
  links**. Whitespace/scope checks were repeated after final evidence edits;
  product tests were not repeated.
- `just agent-doctor`: exit **0**. Expected warning: Context7 authentication is
  not confirmed by offline status. No remote authentication query was added.
- Sanitized `just doctor`: exit **0**, **47 OK**, **two warnings**, **zero missing**.
  Warnings: global `commit.gpgsign` and `gpg.format` unset. Personal Git identity
  and environment values were suppressed before output/persistence.
- `just check`: **one actual invocation, exit 0**, **1575.283 s** measured by the
  local monotonic runner. Flutter analysis clean; **605 Racket**, **265 Flutter**
  and **34 real-process integration** tests passed. Audit append, session cleanup
  and structured denial/unavailability diagnostics were retained in the ignored
  sanitized log; no failed suite was hidden, skipped or rerun.

The first output-filter wrapper had a Python quoting error and exited before
starting `just check`. Its diagnostic was preserved; correcting the local
wrapper led to the sole actual gate launch. This is an administrative defect,
not a discarded gate attempt or scenario rerun. A process-name diagnostic probe
also returned no matching process; contemporaneous module-log progress, rather
than that incomplete probe, established continued progress. No timeout, source,
test, configuration or permission was altered around either observation.

The broad gate is outside A–E and is not acceptance. Its internal integration
coverage is not a second benchmark E attempt. `just accept-m6` and `just accept-m7`
are not run, and historical conditional appliance/hardware evidence is not
upgraded. Only this new document is intended reviewable repository scope;
raw evidence and the temporary reader remain ignored and unstaged.

Final branch/HEAD remain exact. The only reviewable repository change is the new
`docs/development/m7-5-final-evaluation.md`; no pre-existing tracked file or
index entry changed. Base/work/learn hashes, frozen policy/benchmark hashes and
the active 7/4/8/2 registry remain unchanged after broad validation. Configured
work therefore retains four optional providers; base/learn remain MCP-free.

## Disposition, limitations and durable conclusions

**CONDITIONAL PASS.** The evidence supports a
conditional qualification rather than a universal efficiency claim: correctness
and privacy are sound, structural narrowing is real, failed-attempt routing and
catalog defects are corrected, and CP1's good long-job behavior is maintained.
Fresh versus warm conversations, answer/location context from required historical
reads, one sample per scenario, cache warmth, model/harness variation, extra safe
inspection work and unavailable tokens limit causal comparisons. A–C's slower
measured times and remaining minor excerpt work are retained as real observations.

Durable conclusions: keep direct-source authority, locate-once discovery,
explicit unresolved links and task-driven specialist/freshness triggers. Establish
installed versions before lookup, prefer known first-party sources and preserve
version drift. Filter irrelevant security fixtures before output. Start long jobs
once and count all transport observations without unchanged narration. Validate
configuration separately from active-session discovery after lifecycle changes.
Do not add providers, enable watchers or widen permissions to improve a sample.

Evidence-backed deferred follow-ups:

- Improve precise excerpt endpoints and targeted HTML/Markdown retrieval; B/C/D
  retained minor avoidable output despite remediation. This is execution discipline,
  not authorization to edit the frozen policy here.
- If a general efficiency claim is needed, use a separately authorized controlled
  comparison with matched context and multiple samples; investigate the observed
  A–C latency increase without rerunning or changing this corpus retrospectively.
- Requalify provider/version/roots behavior when a real task depends on it or SDK
  versions change. This unused-tool sample and current `main` docs do not prove it.
  Existing incomplete Racket graph coverage remains a source-verification caveat.

No commit, push, staging, merge, rebase, reset, PR, release or history rewrite was
performed. Suggested human-reviewed commit:
`docs(dev): qualify agentic workflow optimization`.
