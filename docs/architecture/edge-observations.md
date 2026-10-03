# Edge observation runtime and binding

## Scope and authority

M8.3.2 implements a generic owned observation runtime and the first semantic
observation, `scanner.barcode`, over Edge Protocol v1.1. Hardware-free sources
exercise the real Core, UDS stream and opt-in Racket session. There is no physical
scanner driver, production daemon, hotplug monitor or checkout scanner bridge.
A barcode means a device reported input; it never establishes a sale line.
Flutter presents, Racket decides, SQLite remembers, and Rust talks to edges.

`edge-supervisor::BindingManager` owns configured-slot reconciliation and
binding attempts. `edge-core::ObservationSupervisor` owns observation sources;
`ExecutorSupervisor` retains command adapters. Only Core owns public bindings,
device revisions, command state and event sequence. Sources supply typed values,
never a device ID, epoch, revision, sequence or wire event.
The bounded `RuntimeFactoryRegistry` dispatches only catalog-known first-party
factories. A metadata entry without a runtime factory remains unavailable;
examples do not become production adapters. Factories must transfer attachment
I/O ownership to the prepared runtime rather than retain independent I/O.

## Preparation and fresh authorization

The bounded, injectable manager performs this algorithm in sorted slot order:

1. Take a complete discovery snapshot and reconcile all configured selectors.
   Withdraw existing bindings whose exact candidate facts are no longer uniquely
   authorized. A failed snapshot withdraws existing manager-owned bindings and
   returns an authored failure (`edge.discovery_failed` for withdrawn bindings);
   a partial inventory is never used.
2. For an eligible unbound slot, ask the compiled runtime factory to prepare the
   exact attachment. Preparation owns its current handle and cannot silently
   migrate to replacement hardware, even if the kernel reuses a sysfs path.
3. Take another complete snapshot and rerun **global** reconciliation. Require
   the same candidate and matching bounded facts, with no ambiguity or conflict.
   Withdraw any other bindings that lost authorization in this new scan.
4. Check the held attachment against those fresh facts. Missing, ambiguous,
   conflicting, changed or malformed discovery discards the prepared runtime.
   The factory must reject loss/replacement of its held handle. No sleep or
   remembered `Eligible` value substitutes for this check.
5. Obtain a fresh opaque binding ID, install all required runtime components,
   and move their complete proof into Core activation.

Discovery scans are non-atomic. Two scans alone do not prove attachment
continuity or freeze all future hotplug. The factory's held-handle contract
protects the prepare-to-activate interval; later changes must invalidate that
exact runtime rather than retarget it. Synthetic tests establish composition,
not Linux-hardware proof. A real driver must prove handle ownership,
attachment checking and loss behavior on its actual interface. Notifications
can later trigger another complete reconciliation; event ordering grants no
authority.

Disabled slots remain disabled; absent slots become absent. Ambiguity and
cross-slot conflict become faulted with `edge.discovery_ambiguous` and
`edge.discovery_conflict`. Preparation failures use
`edge.binding_preparation_failed`. Discovery remains operational authorization,
not device attestation. No candidate ID becomes a binding ID. Production secure
ID generation and process bootstrap remain deferred: composition must inject
unpredictable IDs; there is no weak production default. Core refuses activated
ID reuse and bounds binding history at 4,096 epochs by default.

## Complete runtime installation

In this v1 slice, allowed capabilities with command-resource mappings require
command executors; allowed capabilities without mappings require an observation
source. This classification is privileged startup authority, not wire input.

| Slot shape | Required installed components |
| --- | --- |
| Command-only | Complete configured resource set |
| Observation-only | Source covering the complete unmapped capability set |
| Mixed | Both sets, joined into one proof |

`BindingInstallationWitness` is opaque and move-only. Independently issued
component proofs can combine only for the same Core owner, logical device,
binding ID and connecting revision, without overlapping components. Core checks
the exact required sets and all installation lifetime seals before activation.
Dropping/rejecting a proof cancels its pending runtime. Replacing a source
cancels older proofs across supervisors, as well as fencing old publication
handles. Dropping a live supervisor abandons the Core epoch; it is not a way to
keep a live public binding without runtime ownership.

The command executor still rejects an empty installation. Observation-only
activation is first-class source ownership, never a dummy command/resource.
Command admission still requires a resource mapping **and** a currently
published capability. An allowed/published barcode capability is not executable.
Bound capabilities remain the configured/compiled/current-hardware intersection,
reported by trusted composition and checked against Core's allowlist. Discovery
alone does not publish them.

## Polling, loss and cleanup

`ObservationSource::poll` returns `Pending`, a typed observation, `BindingLost`
or `ContinuityLost`. Each call performs bounded synchronous work. One drive polls
each currently installed source at most once in logical-device order; it never
drains a source until pending. Runtime/device counts remain bounded by Core's
configured registry bounds (production configuration permits at most 32 slots).

Sources must own the exact attachment, perform no autonomous I/O beyond their
ownership, stop all future I/O on Drop, return in bounded time and never panic
in Drop. Poll/preparation panics use the existing adapter privacy boundary:
payloads are never logged; source cleanup precedes binding invalidation.
Destructor panic aborts the process rather than claiming successful cleanup.
The entire attachment epoch loses authority on source loss, continuity loss or
poll panic, including every command resource of a mixed device. Before any later
command begin/poll, the executor checks Core's current binding; it drops old
operations/adapters instead of performing more I/O. Queued/unstarted work ends
`failed + none`; interrupted active work retains conservative evidence
(`unknown + possible` when an effect may have begun). Conversely a command fault
that invalidates the binding causes the observation supervisor to reap its source
without polling. Retiring either side never transfers old work to a replacement.

Composition serializes admission, activation, publication, invalidation and
runtime retirement under one Core owner. The server's control thread cannot
handle a queued request during bounded source cleanup. It invalidates the old
binding before processing that request. Drop must not delegate cleanup to an
independent task that returns while old physical I/O remains possible.
This does not forcibly stop arbitrary blocking code; such drivers require a
stronger isolation boundary. Install application panic hooks before the runtime
privacy wrapper during serial bootstrap, and never replace it afterward.

`BindingLost` invalidates the exact binding and makes the slot absent.
`ContinuityLost` drops/fences the source and faults the binding with
`edge.observation_continuity_lost`. Poll panic or invalid source capability
faults with `edge.observation_fault`. Source error strings and physical data
never become public condition codes. A delayed old-binding report cannot
invalidate its replacement. There is no automatic source recovery/retry inside
an observation drive; another explicit reconciliation must install a fresh epoch.

## Wire contract and continuity

```json
{"type":"device.observation","agent_instance_id":"agent","sequence":42,"device_id":"lane-01.scanner","binding_instance_id":"binding","state_revision":3,"observation":{"kind":"scanner.barcode","barcode":"049000001234"}}
```

`barcode` is nonempty opaque UTF-8, at most **4,096 encoded bytes**. Leading zeros,
spaces, Unicode, controls and NUL are preserved. There is no trimming, Unicode
normalization, numeric conversion, symbology guess or catalog lookup. JSON escapes
controls; worst-case escaping plus bounded metadata remains below the 65,536-byte
event-record default. Both Rust and Racket reject unknown observation kinds and
invalid values with safe errors. Barcode/event diagnostics redact the value. Tests round-trip controls and NUL
through JSON in Rust and Racket; the private wire carries the value, ordinary
printing/debug/errors do not. This substrate preserves the existing opaque POS
string domain; it does not qualify a future scanner-to-business bridge or its
catalog/storage handling.

Core validates an installed publication token's owner, lifetime, device and
current binding, then requires the observation capability to be currently
published and unmapped as a command. Fenced or unavailable observations consume
no sequence. Accepted events carry the current state revision without advancing
it. Observations, device changes and command changes share one global per-agent
sequence; heartbeats remain sequence-free. Identical consecutive barcodes produce
two events, without deduplication.

The existing subscriber queue (256 records by default) closes continuity on
overflow, including a lost barcode. No single record is silently dropped while
claiming a healthy stream. With no subscriber, observations are ephemeral and
advance the cursor without a backlog. Reconnect receives current snapshot/cursor,
**never replay of missed barcodes**. Cashier recovery must request a rescan after
continuity loss; replaying stale human input would be unsafe.

Racket's immutable parser yields `edge-observation-event` with an opaque printable
`edge-scanner-barcode` value. `EdgeSession` validates agent/sequence and cached
device binding, revision and capability before advancing its cursor and invoking
the opt-in `#:on-observation` callback. A mismatch marks the stream stale, delivers
no callback, and retains the prior cursor/device cache. Observations do not change
the cached device snapshot and the session retains no barcode history. There is
no implicit inquiry/retransmission, business command or SQLite write.
The cursor is committed **before** callback invocation, so the callback may read
`edge-session-current` and observe its accepted sequence. Any raised callback
value is replaced with the authored `observation-callback` failure; nonlocal
escape also marks the session stale and closes the stream. Exception payloads
are never retained or printed. This can lose the ephemeral scan: there is no
callback retry or reconnect replay, and the cashier must rescan. A local continuation prompt
rejects abort payloads without invoking their thunks outside the privacy
boundary; a continuation barrier prohibits reentering a completed callback later.

Callbacks must return after bounded work; they run serially on the session
reader thread. While one runs, later EOF/events cannot be processed. Reading
current state is supported. Self-stop publishes `stopped` before shutting down
the callback's custodian and may never return; external stop while a callback
waits also remains stopped. Neither completion nor escape can resurrect health.
Blocking indefinitely or escaping control is outside the callback contract.

Protocol metadata now reports **1.1**; routes stay `/v1`. Rust and Racket are
upgraded together. The current Racket client accepts v1.0 metadata and streams containing the
legacy vocabulary. It also accepts bounded future major-1 minor metadata, which
is not proof of support for future semantics. Unknown event/observation kinds
fail the stream; ignoring them while claiming contiguous sequence is prohibited.
Thus a v1.0 client receiving a v1.1 observation must fail safely. Additive minor
vocabulary is not transparently ignorable on this ordered continuity domain.

## Validation and remaining work

Hardware-free tests cover complete command/observation/mixed proofs, incomplete
and stale authority, competing supervisors, delayed old-binding publication,
fresh global revalidation races, source loss/panic, barcode byte limits/privacy,
overflow/no replay, and real UDS delivery through the Racket session callback.
Canonical development gates remain `just check-rust`, `just test-racket` and
`just check`.

DS2208 transport selection, real adapter/open/revalidation proof, HID/CDC/SSI/
SNAPI parsing, barcode decoding, production hotplug/bootstrap/secure epoch IDs,
Racket's business scanner bridge, Flutter UX and physical qualification remain
later work. No production scanner adapter is registered. SQLite remains v12;
Edge owns no durable observations. Frozen M8.2 evidence is unchanged and applies
to its historical source, not this newer cumulative Core/protocol implementation.
