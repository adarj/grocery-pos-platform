# M8.2 Tier-A requirements

These are obligations for the **generic foundation**, not evidence of execution.
IDs are stable. The closed evidence mapping lives in `m8-2-report.rkt`.

## CP1

| ID | Requirement |
| --- | --- |
| M8.2-CP1-001 | **Racket caller boundary.** Only the Racket POS/Core side owns the production Edge client boundary; Flutter has no direct Edge Protocol or raw-peripheral authority. |
| M8.2-CP1-002 | **Rust authority boundary.** Rust Edge owns no POS business facts and has no POS SQLite access or mutation authority. |
| M8.2-CP1-003 | **Closed semantic protocol.** Generic v1 exposes neither arbitrary raw-device commands nor card-payment execution. |
| M8.2-CP1-004 | **Capability authority.** Published executable capabilities remain constrained by configured/compiled Core authority and installed exact-epoch resources. |
| M8.2-CP1-005 | **Simulation isolation.** The synthetic fixture is qualification-only and feature-gated; it cannot silently become a production adapter path. |

## CP2

| ID | Requirement |
| --- | --- |
| M8.2-CP2-001 | **Epoch and identity.** Commands capture agent and binding epochs; new semantic attempts use fresh unpredictable command IDs and each transmission uses a fresh request ID. |
| M8.2-CP2-002 | **Record before effect.** Admission creates a retained command record before FIFO visibility and physical-effect eligibility. |
| M8.2-CP2-003 | **Retained identity.** Exact retained retries deduplicate and changed retained semantics conflict before current binding/freshness admission checks. |
| M8.2-CP2-004 | **Freshness and timeout.** New or forgotten submissions must satisfy original freshness, maximum future horizon, and bounded independent acceptance-relative timeout. |
| M8.2-CP2-005 | **Bounded protected admission.** Cache/queue capacity failures precede accepted records/effects; nonterminal and protected terminal evidence is never evicted for new work. |
| M8.2-CP2-006 | **Dual retention.** Terminal identity is protected while either original freshness remains open (including equality) or terminal recovery minimum has not elapsed. |
| M8.2-CP2-007 | **Safe eviction and reuse.** Only after both protections expire may terminal records be reclaimed; original replay is then stale before effect. New IDs reuse capacity without restart. Command 404 never proves non-effect. |
| M8.2-CP2-008 | **Payload compaction.** Terminal record/events release full typed payloads while compact retained identity still supports dedupe/conflict and public state remains immutable. |

## CP3

| ID | Requirement |
| --- | --- |
| M8.2-CP3-001 | **Monotonic evidence.** Evidence moves None→Possible→Confirmed; direct confirmation and contradictory completion fail conservatively. |
| M8.2-CP3-002 | **Outcome matrix.** Known pre-effect failure remains failed/rejected+none; known post-Possible failure may be failed+possible; interruption after Possible is unknown+possible; confirmed evidence dominates later driver faults. |
| M8.2-CP3-003 | **Interruption containment.** Timeout/panic/binding loss contain old operations before terminal publication, invalidate exact current binding where required, and prohibit later polls/effects. |
| M8.2-CP3-004 | **Resource scheduling.** Same-resource FIFO never overlaps; different resources progress independently; one drive remains bounded. |
| M8.2-CP3-005 | **No semantic retry.** Neither executor nor event/session recovery automatically repeats a semantic physical operation; business recovery belongs to Racket. |
| M8.2-CP3-006 | **Fatal and monotonic control.** Clock regression/invariant failure abandons the control-plane epoch. Protocol safety, deadlines and retention use monotonic time, independent of wall clock. |

## CP4

| ID | Requirement |
| --- | --- |
| M8.2-CP4-001 | **Binding freshness/history.** Every successful attachment uses a fresh never-reused ID; the first activation is remembered and history exhaustion fails closed within a bounded agent epoch. |
| M8.2-CP4-002 | **Exact stale facts.** Invalidation clears current public binding/capabilities; stale old-epoch status/fault/invalidation cannot mutate a replacement or consume revision/sequence. |
| M8.2-CP4-003 | **Safe rebind.** Configured resources survive unbinding; activation requires complete fresh exact-epoch installations; old active/queued commands never migrate to replacements. |
| M8.2-CP4-004 | **Revision and sequence.** Core owns checked per-device revisions and a separate checked global state-event sequence; actual changes advance once, while no-op/dedupe/stale reports do not. |
| M8.2-CP4-005 | **Atomic live boundary.** One exclusive snapshot/subscription operation captures all configured devices deterministically and current cursor; first later state event is cursor+1. Snapshot/heartbeat consume no state sequence. |
| M8.2-CP4-006 | **Bounded continuity.** One subscriber has an opaque generation and bounded FIFO; overflow closes continuity and discards backlog after committing authoritative state. Reconnect has fresh snapshot/no replay; stale tokens cannot poll/close replacements. |

## CP5

| ID | Requirement |
| --- | --- |
| M8.2-CP5-001 | **Authenticated filesystem transport.** Only filesystem AF_UNIX/SOCK_STREAM is served from an inherited listener; trusted expected UID is checked via SO_PEERCRED before HTTP parsing. Same-user repository evidence is not deployed UID separation. |
| M8.2-CP5-002 | **Bounded resources.** Connections, mailbox, headers/counts, body collection, responses, event records and transport handoff/deadlines are explicitly bounded; rejected mailbox work never reaches Core. |
| M8.2-CP5-003 | **HTTP route/status contract.** Exactly seven v1 routes use HTTP/1.1 with one request per connection, strict methods/Allow, no compression or transport authentication alternatives, and correct codec/Core status classes without retry guidance. |
| M8.2-CP5-004 | **Core ownership/liveness.** A dedicated thread constructs/owns non-Send Core/executor/tokens. Typed bounded mailboxes preserve executor/heartbeat progress, cancellation safety and fatal epoch termination. |
| M8.2-CP5-005 | **Transport continuity/privacy.** NDJSON forwards Core snapshot/events through one-record handoff; wake races are harmless, cleanup bypasses ordinary mailbox pressure, overflow/disconnect ends stream, and diagnostics expose no payload/peer secrets. |

## CP6

| ID | Requirement |
| --- | --- |
| M8.2-CP6-001 | **Immutable attempts.** Crypto-random new command identity captures immutable epochs, device, binding, original deadline, kind, timeout and payload; reconnect cannot rewrite it. |
| M8.2-CP6-002 | **One transmission.** Every request explicitly configures total attempts=1 and redirects=0; server observations prove no hidden POST/body replay or follow-up request. |
| M8.2-CP6-003 | **Uncertain transport.** Lost POST response is typed uncertainty, distinct from definite protocol rejection/untrusted response. Explicit same-attempt retransmission changes only request ID and begins the adapter once. |
| M8.2-CP6-004 | **Patched bounded HTTP.** Pinned private HTTP decoding incrementally bounds response framing/body storage, rejects malformed/ambiguous/truncated framing and unsupported compression, and emits authored diagnostics. |
| M8.2-CP6-005 | **Bounded NDJSON.** Byte-oriented record reading bounds whitespace/framing before allocation, validates strict UTF-8 and one document/LF record, and is independent of HTTP chunk boundaries. |
| M8.2-CP6-006 | **Session continuity.** Snapshot validates wholly before cache replacement; same-agent sequence/revision and uptime progression is checked. Gap/duplicate/backward/malformed/EOF/second snapshot/unknown slot stale the stream. Direct GET cannot mutate stream cache. |
| M8.2-CP6-007 | **Epoch and cleanup.** Same-agent reconnect cannot move known cursor/revisions backward; new-agent snapshot replaces the epoch and surfaces its end without automatic command replay. Reader/callback/custodian cleanup is bounded. |

## CP7

| ID | Requirement |
| --- | --- |
| M8.2-CP7-001 | **Closed evidence.** Only the hard-coded mandatory Tier-A groups and stable requirement mapping may enter the ledger; missing/duplicate/unknown/malformed evidence is rejected. |
| M8.2-CP7-002 | **Canonical regression.** Locked Rust regression, focused Edge Racket regression and complete just check are mandatory, with repeated focused/canonical executions explicitly identified. |
| M8.2-CP7-003 | **Source audit.** Whole-M8.2 static/manual classification preserves authority/unsafe/schema/simulation/production isolation and documents remaining boundaries. |
| M8.2-CP7-004 | **Capacity and load.** Actual defaults are exercised with fake-time boundaries and bounded real end-to-end load. Counts/high-water and timing are host observations, not performance guarantees. |
| M8.2-CP7-005 | **Controlled process death.** A finite 25-cycle Rust process-death/new-agent campaign rotates observed software points and proves session loss/new snapshot/no automatic replay/old-agent rejection. It does not prove physical power-loss behavior. |
| M8.2-CP7-006 | **Dependency/source integrity.** Cargo.lock, pinned Racket/Nix dependencies and the mandatory private HTTP patch are part of the tested boundary; ignored generated developer state cannot enter filtered deployment sources. |
| M8.2-CP7-007 | **Evidence workflow integrity.** Runner/reporter self-tests isolate mocks and discover failures; authoritative runs require a clean exact committed tree, collect ordinary failures, fail on publication errors, and freeze evidence in a separate Phase-2 docs commit without future-tier overclaims. |

## Scope reconciliation

Accepted M8.1 calls for eventual bounded production `edge.toml` parsing and candidate matching. M8.2.1–M8.2.6 intentionally defer the complete schema, discovery selectors, ambiguous physical matching and production simulator launch permission. This qualification evaluates validated internal seeds, Core capability constraints and fixture feature isolation; it does **not** qualify those missing production composition paths or rewrite M8.1.

Barcode, stable/unstable weight, paper-out and internal device-observation overflow remain later device-specific schemas/adapters and qualification. Generic synthetic command/binding/state events establish their substrate, without inventing production observations.

M8.2 Tier-A passing does not mean whole-M8 Tier-A or Tier-B/C/D passing. SQLite remains v12.
