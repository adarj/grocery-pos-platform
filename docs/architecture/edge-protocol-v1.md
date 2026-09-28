# Edge Protocol v1

## Status, scope, and normative language

This is the accepted M8.1 wire and semantic specification under
[ADR-0033](../adr/0033-use-a-semantic-local-edge-protocol-for-pos-hardware.md).
MUST, MUST NOT, and required invariants govern future implementation. M8.1
implements no protocol server, Rust workspace, Racket client, or hardware
schema. [Edge-agent architecture](edge-agent.md) defines runtime ownership;
the [threat model](../security/edge-agent-threat-model.md) defines security and
future acceptance requirements.

Only Racket POS Core calls the production protocol. Rust observes devices and
performs requested semantic physical operations; Racket/SQLite remain business
authority. This private contract is separate from the Flutter-to-Racket
[local POS API](local-api.md), including its bearer authentication and durable
transaction-command receipts.

## Transport, versioning, and peer boundary

The v1 transport is **HTTP/1.1 + UTF-8 JSON + `AF_UNIX SOCK_STREAM`**. Production
MUST use a local filesystem Unix-domain socket. The conceptual endpoint is
`/run/grocery-pos/edge.sock`; privileged machine configuration may choose its
exact pathname. There is no production TCP listener, browser CORS surface,
bearer-token requirement, or TLS requirement on this channel.

The future systemd `.socket` unit owns the listener and passes it to the edge
service. The target socket is root-owned, group `grocery-pos-edge-api`, mode
`0660`, with qualified parent-directory permissions/lifecycle and SELinux
labels. Rust MUST check `SO_PEERCRED` on every accepted connection and require
the expected `grocery-pos` service UID before HTTP processing. DAC group access
alone is insufficient. Missing or wrong peer credentials fail closed, without
executing a request. These are deployment requirements, not current facts;
see the [Linux architecture boundary](edge-agent.md).

Protocol major version is encoded in `/v1`. Agent metadata may additionally
report major/minor. Incompatible meanings require a new major version rather
than silently changing `/v1`. Compatible response additions may be ignored by
older clients; unknown safety-relevant enum values must fail explicitly rather
than be interpreted as success, readiness, or non-effect.

Strict request schemas remain strict as versions evolve. New request fields or
command schemas require explicit client/server support; response tolerance
does not authorize sending fields an older server rejects. A reported or newly
implemented capability still requires configuration allowlisting.

## HTTP surface and meaning

| Endpoint | Meaning |
| --- | --- |
| `GET /v1/health` | Edge process/protocol alive; no requirement that all devices be present |
| `GET /v1/status` | Agent identity, protocol/version metadata, monotonic uptime, bounded runtime metadata |
| `GET /v1/devices` | Snapshot of current configured logical devices and published capabilities |
| `GET /v1/devices/{device_id}` | One current configured device snapshot |
| `POST /v1/commands` | Submit one semantic physical operation attempt |
| `GET /v1/commands/{command_id}` | Current retained command state in this agent epoch |
| `GET /v1/events` | One long-lived operational Racket NDJSON stream |

Health is available after validated configuration, Core/discovery
initialization, running BindingManager, and listener availability. Device
conditions are separate from liveness. Racket evaluates lane workflow
capability; a missing printer MUST NOT automatically make POS Core globally
unready. This preserves
[ADR-0020](../adr/0020-keep-pos-core-api-loopback-only-and-separate-liveness-from-readiness.md).

HTTP describes request/protocol acceptance, not physical success:

| Status | Meaning |
| --- | --- |
| `200` | Successful GET or deduplicated command submission returning existing state |
| `202` | New command accepted; a record exists, but physical success is not asserted |
| `400` | Malformed JSON/envelope, duplicate keys, unknown request fields, or structural invalidity |
| `404` | Unknown configured device, command record, or route |
| `409` | Agent/binding precondition conflict or same-ID/different-semantics conflict |
| `413` | Request body exceeds its bound |
| `415` | Unsupported request media type |
| `422` | Invalid semantic kind/payload/capability or expired new/forgotten submission |
| `503` | Bounded resource cannot accept work or runtime cannot safely admit new work |

Unsupported endpoint methods use `405` and an appropriate `Allow` header.
HTTP/header parsing also has explicit bounded failures. Wrong peer UID is
denied at the connection boundary, not treated as an operator bearer challenge.
Stable machine-readable error codes distinguish causes within a status.
For example, a pre-acceptance response may conceptually be:

```json
{
  "request_id": "opaque-request-id",
  "agent_instance_id": "opaque-agent-id",
  "error": {
    "code": "submission_expired",
    "message": "Submission deadline has passed."
  }
}
```

Errors MUST NOT echo raw request payloads, OS/device errors, stack traces, or
secret-bearing responses. There is no generic `"retryable": true` flag; Racket
owns retry policy. Paper-out reported after acceptance is a command
state/result, not a retroactive HTTP 503. A lost HTTP response establishes
neither acceptance nor non-effect; recovery uses the same semantic command ID
and state inquiry within the epoch.

## Strict and bounded parsing

Requests MUST contain UTF-8 JSON and exactly one document, with duplicate
object keys rejected at every nesting level. Unknown request fields are
rejected. Command payloads require strict command-specific typed schemas when
those commands are implemented. Envelope IDs are bounded nonempty strings;
timing fields are bounded exact nonnegative integers, with `timeout_ms`
positive and capped. Floating-point approximations and integer overflow cannot
determine deadlines or identity.

Header/body sizes, JSON depth, collection/string lengths, connections,
request-read time, and serialization work must all be bounded. Exceeding a
bound fails explicitly, without partial acceptance. JSON property order,
whitespace, and equivalent string escapes do not alter typed semantics.
Adapters receive typed commands, never arbitrary JSON.

Non-stream responses use JSON. Events use UTF-8 NDJSON: exactly one bounded JSON
record per line, with arbitrary HTTP chunk boundaries independent of record
boundaries. Clients must bound their framing buffers too.

## Identifier and time domains

| Identifier | Generator and meaning |
| --- | --- |
| `agent_instance_id` | Rust at startup; opaque UUID-like ID for exactly one daemon lifetime |
| `device_id` | Privileged configuration; stable logical slot surviving hardware replacement |
| `binding_instance_id` | Rust on successful bind; random opaque ID for one physical attachment/binding epoch |
| `command_id` | Racket; one intended semantic physical operation attempt, stable across transport retries |
| `request_id` | Racket; one HTTP request attempt, changed across transport retries |

Identifiers are opaque; clients MUST NOT derive ordering or time from them.
Agent uptime, deadlines, and event ordering use explicit fields, not UUIDs.
The agent's monotonic clock measures elapsed time since startup. Wall-clock
corrections do not affect freshness, command deadlines, retention, or sequencing.

Device replacement, disconnect/reconnect, transport invalidation/rebind, and
edge restart reconstruct bindings with new binding IDs. Restart also changes
the agent ID and resets the event sequence domain. An old ID never becomes
current again.

## Device snapshots

Only configured logical slots are public. A snapshot conceptually contains
agent ID, logical device ID, current binding ID or null, per-device
`state_revision`, adapter kind, availability, namespaced conditions, and the
published capability set. It does not expose arbitrary unconfigured candidates
or raw descriptors, kernel paths, USB serials, or topology inventories.

Illustrative snapshot; this is not a printer-specific payload schema:

```json
{
  "agent_instance_id": "opaque-agent-id",
  "device_id": "lane-01.receipt-printer",
  "binding_instance_id": "opaque-binding-id",
  "state_revision": 7,
  "adapter_kind": "compiled-printer-adapter",
  "availability": "degraded",
  "conditions": ["printer.paper_out"],
  "capabilities": ["receipt.print", "printer.status", "drawer.open"]
}
```

Core owns each device's increasing state revision within one agent epoch.
Binding changes do not reset that logical device's revision in the same epoch.
Clients must not replace a newer snapshot with an older query/event result.
Unbound devices have null binding IDs; their capabilities must not imply an
available command target.

| Availability | Generic meaning |
| --- | --- |
| `disabled` | Configuration does not enable the slot |
| `absent` | No authorized candidate is present |
| `connecting` | Binding/initialization is in progress |
| `ready` | Binding operational without reported degradation |
| `degraded` | Binding has conditions or limited operation |
| `faulted` | Binding/selection cannot operate safely, including ambiguity |

Conditions such as `printer.paper_out`, `printer.cover_open`, and
`scale.unstable` are separate namespaced facts. Readiness alone is not a promise
that any particular operation will succeed. Published capabilities are the
intersection of configured permissions, adapter implementation, and current
hardware support. Racket decides the workflow consequences.

## Command submission

A normative conceptual envelope is:

```json
{
  "request_id": "opaque-request-id",
  "command_id": "opaque-command-id",
  "expected_agent_instance_id": "opaque-agent-id",
  "device_id": "lane-01.receipt-printer",
  "expected_binding_instance_id": "opaque-binding-id",
  "not_after_agent_uptime_ms": 950113,
  "kind": "receipt.print",
  "timeout_ms": 5000,
  "payload": {}
}
```

`payload` is an illustrative placeholder, not an executable printer contract.
Later checkpoints define typed command-specific payloads, effect classes,
success criteria, and valid outcome/evidence combinations. There is no generic
raw-byte payload. A new operation must target the current agent and exact
successful binding; logical device ID alone is insufficient.

`not_after_agent_uptime_ms` limits admission of a new or forgotten command ID.
Racket obtains agent uptime and chooses a finite submission window. It is not
a wall-clock timestamp, execution timeout, or permission to repeat an effect.
`timeout_ms` independently runs from acceptance, including queue time.

## Acceptance ordering and execution fence

The architecture and implementation MUST preserve:

```text
parse + structural validation
        ↓
agent-instance precondition
        ↓
existing command_id lookup
        ↓
submission freshness check
        ↓
device lookup
        ↓
binding-instance precondition
        ↓
capability/payload validation
        ↓
cache capacity
        ↓
reserve bounded executor-queue slot
        ↓
CREATE COMMAND RECORD
        ↓
enqueue
        ↓
physical effect may begin
```

Structural parsing includes the typed decoding needed to compare command
identity. The later validation step checks capability authorization and
command/device constraints for a new operation. A retained duplicate is compared
with its original typed semantics, without re-deciding against current device
state or revalidating its now-stale binding as a new operation.

Core arbitrates concurrent submissions, cache/queue reservation, and record
creation. A command record MUST exist before its effect can begin. Admission
failures create no accepted operation and cause no requested physical effect.
If enqueue/handoff fails after record creation, resolve the existing record
safely; never execute outside it.

Binding validation at acceptance is insufficient by itself. Before driver I/O,
the executor must enforce continued binding validity and the command deadline.
Invalidation fences queued and executing work. An old queue cannot be moved
onto replacement hardware. A duplicate query may return an old record after
binding invalidation, but MUST NOT cause new execution.

## Deduplication, freshness, and cache retention

Within one agent epoch, same `command_id` plus same semantic command returns
existing state and never executes again. Same ID with different semantics
returns conflict, preserving the original record. `request_id` is excluded
from semantic identity. Identity includes at least:

```text
device_id
expected_binding_instance_id
not_after_agent_uptime_ms
kind
timeout_ms
typed payload
```

The agent precondition is checked before lookup, so a retry targeting an old
agent cannot be accepted by a new one. Equality compares typed/canonical
semantics, not raw request bytes or JSON property order. A retained private
fingerprint must preserve conflict detection without needing the full terminal
payload; it is not a public log or support-bundle field.

Freshness rules are:

| Record lookup | Deadline condition | Result |
| --- | --- | --- |
| Existing record | Any, including expired | Deduplicate or conflict; no new execution |
| New/forgotten ID | Agent uptime <= `not_after_agent_uptime_ms` | May continue admission checks |
| New/forgotten ID | Agent uptime > `not_after_agent_uptime_ms` | Reject before effect |

The freshness value is semantic identity. A transport retry cannot extend it.
Expiration does not cancel an already accepted command; its
acceptance-relative timeout governs execution.

Within the live agent epoch, records MUST remain while nonterminal. A terminal
record MUST remain until both its submission deadline has passed and the
terminal recovery minimum has elapsed. The initial recovery target is at least
120 seconds after terminal completion. Restart loses ephemeral cache state;
this minimum is not a durability guarantee across restart.

Freshness alone cannot detect changed semantics under a forgotten ID. To
preserve the per-epoch conflict guarantee as well, compact accepted-command
identity, fingerprint, and terminal state MUST remain for the entire agent
epoch within the command-record bound. Sensitive payload disposal is not
identity disposal. v1 must not silently forget accepted identities and permit
their reuse; loss of this Core-owned evidence requires process termination and
a new agent epoch. The new/forgotten-ID freshness check still applies to delayed
submissions with no record, including requests that were never accepted.

No eviction policy may remove correctness evidence to accept more work.
Cache-full returns an explicit pre-acceptance failure, including when compact
epoch retention consumes capacity. M8.2 must qualify sustained lane throughput
against that bound; the initial 4096 target may need adjustment. Long deadlines
cannot produce unbounded allocation. An implementation must not weaken ID
conflict detection as an undocumented cache optimization.

A command lookup returns 404 only when no record is retained in the current
agent. Expiration or payload disposal must not make an accepted command's
compact state disappear within its epoch. **404 is not evidence that an effect
did not happen**, including in an earlier agent epoch. Racket must use its own
correlation/recovery policy, never infer a safe replacement operation from cache
absence. This differs deliberately from
the durable business receipts in
[ADR-0011](../adr/0011-use-durable-command-receipts-and-expected-stream-versions.md).

## Lifecycle, outcomes, and effect evidence

The generic lifecycle is:

```text
accepted → executing → terminal
    └────────────────→ terminal (for example, queue timeout before execution)
```

Terminal state is immutable. A terminal record exposes an outcome and effect
evidence; later observations MUST NOT rewrite it.

| Outcome | Meaning |
| --- | --- |
| `succeeded` | Command-specific success criterion observed |
| `rejected` | Adapter/device refused before the requested effect began |
| `failed` | Success criterion not achieved, with sufficient evidence for a known failure |
| `unknown` | Requested physical effect may or may not have occurred |

`unknown` MUST NOT be silently treated as `failed` or `succeeded`. Protocol
admission rejection is distinct from terminal `rejected`: the latter belongs
to an already accepted command record.

| Effect evidence | Meaning |
| --- | --- |
| `none` | Agent knows the requested physical effect did not begin |
| `possible` | Some or all of the requested effect may have occurred |
| `confirmed` | Command-specific success criterion observed |

Typical pairs are `rejected + none`, `failed + none`, `failed + possible`,
`unknown + possible`, and `succeeded + confirmed`. Exact valid pairs are defined
per command/effect class. Known partial failure (`failed + possible`) still does
not grant permission to repeat a discrete effect. Confirmation means the
specified device criterion, not proof that a customer took a receipt.

Illustrative terminal command state, with no receipt content:

```json
{
  "agent_instance_id": "opaque-agent-id",
  "command_id": "opaque-command-id",
  "device_id": "lane-01.receipt-printer",
  "binding_instance_id": "opaque-binding-id",
  "kind": "receipt.print",
  "phase": "terminal",
  "outcome": "unknown",
  "effect_evidence": "possible",
  "error": {"code": "execution_timeout"},
  "accepted_agent_uptime_ms": 945113,
  "terminal_agent_uptime_ms": 950113
}
```

Core/Executor owns the monotonic EffectTracker `None → Possible → Confirmed`.
The adapter advances a restricted handle to `Possible` immediately before the
first action after which the requested semantic effect could have happened.
Core derives conservative public results after timeout, panic, or disconnect.

`timeout_ms` is monotonic time from acceptance, including queue time, until the
command must become terminal. Timeout before effect may yield `failed + none`.
Timeout/panic after `Possible`, without confirmation or known-failure evidence,
requires `unknown + possible`. After driver execution begins, timeout/panic
invalidates the binding and closes/discards its transport. The old executor
must be stopped/fenced before rebinding. Core/control-plane failure terminates
the daemon, creating a new epoch on restart.

Known non-effect terminalization must fence old execution and capture evidence
safely against the first-I/O/deadline race. Observing tracker `None` while a task
can still begin an effect is insufficient for `failed + none`. If the agent
cannot establish non-effect, preserve conservative uncertainty; it must not
publish known failure and allow subsequent old-task I/O. Uncontainable execution
requires process termination, not reuse of the binding.

Internal effect classes are `Observation` (scale/status reads),
`ReplaceableState` (future indicators/display state), and `DiscreteEffect`
(receipt print/drawer open). Rust MUST NOT automatically repeat a discrete
effect once it may have begun. Racket chooses retry/recovery policy; transport
deduplication is not a business retry decision.

## Initial bounded implementation targets

These are initial defaults to qualify in M8.2, not immutable protocol constants:

| Resource | Initial target |
| --- | --- |
| HTTP headers | Approximately 16 KiB total |
| Command body | Approximately 256 KiB |
| Non-stream JSON response | Approximately 256 KiB |
| One event record, including initial snapshot | Approximately 64 KiB |
| Command timeout maximum | 60 seconds |
| Executor queue | 32 waiting commands per physical resource |
| Command records | 4096 per agent, including nonterminal and retained terminal records |
| Terminal recovery minimum | 120 seconds after terminal completion, also subject to freshness retention |
| Operational event streams | One Racket subscriber |

All queues, caches, observation channels, framing buffers, and work admission
must remain bounded. Per-resource bounds also require bounded configured
resource/device counts and aggregate memory. Configuration/runtime validation
must reject unsupported capacity or an oversized full snapshot explicitly,
rather than omit devices or split away its atomic meaning. Implementation must
also bound connections, parser depth, and read/send deadlines without claiming
those unqualified numeric choices are already fixed.

**Exceeding a bound fails explicitly; the daemon never responds by allocating
without limit or silently discarding correctness evidence.** New-command cache
or queue exhaustion fails before acceptance. Commands touching one physical
resource execute serially through its FIFO; different resources may run
concurrently. There is no priority mechanism in v1.

## Events: atomic snapshot and sequence domain

`GET /v1/events` establishes one long-lived NDJSON stream for the operational
Racket subscriber. An additional concurrent subscriber must be refused
explicitly without replacing the existing one.

Core registers the subscriber and captures a full configured-device snapshot
and cursor atomically. The first record contains agent ID, event cursor, agent
uptime, and all current configured device snapshots. It is a snapshot boundary,
not replay of earlier events. Conceptual framing:

```json
{"type":"snapshot","agent_instance_id":"opaque-agent-id","event_cursor":41,"agent_uptime_ms":945100,"devices":[{"agent_instance_id":"opaque-agent-id","device_id":"lane-01.receipt-printer","binding_instance_id":"opaque-binding-id","state_revision":7,"adapter_kind":"compiled-printer-adapter","availability":"ready","conditions":[],"capabilities":["receipt.print","printer.status","drawer.open"]}]}
{"type":"device.state_changed","agent_instance_id":"opaque-agent-id","sequence":42,"device_id":"lane-01.receipt-printer","binding_instance_id":null,"state_revision":8,"device":{"agent_instance_id":"opaque-agent-id","device_id":"lane-01.receipt-printer","binding_instance_id":null,"state_revision":8,"adapter_kind":"compiled-printer-adapter","availability":"absent","conditions":[],"capabilities":[]}}
{"type":"heartbeat","agent_instance_id":"opaque-agent-id","agent_uptime_ms":955100}
```

The example shows one configured printer losing its binding after the snapshot.
State-change records carry complete replacement snapshots, including identity,
revision, capabilities, and conditions. Later checkpoints define device-specific
observation payloads.

Subsequent externally visible events use one increasing per-agent sequence;
the first after the snapshot is cursor + 1 and later records are contiguous.
Restart changes agent ID and resets the sequence domain. Heartbeats do not
consume sequence numbers. Device revisions and event sequence have separate
purposes: snapshot ordering for one logical device versus continuity of the
whole stream.

Conceptual categories are `device.state_changed`, `command.state_changed`,
`scanner.barcode_observed`, and future scale observations. State events prefer
complete replacement snapshots over deltas. Core attaches agent, logical device,
binding, state revision, and event sequence; adapters do not assign them.
Command events refer to their command's binding, even if that binding has since
been invalidated. Invalidated-binding observations cannot be attributed to its
replacement.

The initial snapshot contains device state, not durable history or all command
results. Racket queries retained outstanding command IDs separately. Event
observations do not establish sale lines, cash movements, or money.

## Continuity, backpressure, and session recovery

Events are ephemeral. v1 has no durable Rust event broker or replay API. A
disconnected Racket may lose transient scanner input; losing it is preferable
to replaying stale human input later. A new snapshot recovers current state,
not missed scans. Sequence gaps are explicit continuity failures and must not
be silently ignored.

All event and observation channels are bounded. If the subscriber falls behind,
close the stream, reconnect, and obtain a new atomic snapshot. Do not discard
records while claiming a continuous stream. Internal adapter-to-Core overflow
must become an explicit continuity/binding fault; if Core cannot safely report
that failure, fail the control plane rather than hide loss. Old observations
cannot leak into a rebound device's stream.

Heartbeats may be emitted without consuming event sequence numbers. About
10 seconds between heartbeats and a longer client stale threshold are initial
operational targets, not business correctness constants. Racket marks stream
health stale on loss/timeout/gap and obtains a fresh snapshot before relying on
continuity. Reconnect does not itself retry physical commands.

The future Racket `EdgeSession` holds agent ID, cursor, device snapshots,
stream health, and outstanding commands. New agent ID invalidates old binding
assumptions and prohibits automatic replay of old pending physical operations.
The generic client boundary described in [edge-agent architecture](edge-agent.md)
owns epoch validation, framing, and wire errors. Racket business services retain
workflow, authorization, and retry decisions.

## Payload privacy and explicit exclusions

Typed payloads may be needed while queued/executing. Terminal retention should
discard full sensitive payload content while keeping bounded metadata, private
semantic fingerprint, outcome, effect evidence, safe result/error, and timing.
Strict equality/conflict detection must still work after payload disposal.
Receipt content, barcode values, raw device packets, customer content, and
credential-like values must not enter ordinary logs or support metadata.
[ADR-0023](../adr/0023-build-support-bundles-from-allowlisted-operational-metadata.md)
remains allowlist-based; neither fingerprints nor device inventories become
ordinary support exports merely because they are available in memory.

v1 provides no cancellation, atomic multi-device command, live configuration
mutation, remote administration, durable edge database/event replay, or
exactly-once physical-effect guarantee. It has no `/raw-usb`, `/raw-serial`,
`/vendor-command`, `/run-bytes`, or equivalent raw escape hatch. Generic payment
authorization, capture, void, refund, reconciliation, and other card-payment
execution are excluded; future payment architecture is separate.

Printers do not create authoritative receipts or commit/roll back sales;
drawers do not establish tender; scales do not compute money. Normal Flutter
customer-display presentation is not an edge protocol use case. Full security
non-goals, residual risks, and future Tier A–D evidence are in the
[threat model](../security/edge-agent-threat-model.md).
