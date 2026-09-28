# Edge-agent threat model and acceptance contract

## Status and security objective

This document records normative M8.1 constraints and **future** qualification
targets under
[ADR-0033](../adr/0033-use-a-semantic-local-edge-protocol-for-pos-hardware.md).
Read it with the [edge architecture](../architecture/edge-agent.md) and
[Edge Protocol v1](../architecture/edge-protocol-v1.md). No edge daemon,
Linux policy, client, simulator, driver, or hardware qualification is claimed
to exist as a result of this checkpoint.

> No failure or compromise below Racket's business-authority boundary may
> silently create, reinterpret, duplicate, or erase a Grocery POS business fact.

This objective protects the authority path, not the truthfulness of every
physical observation. A hostile scanner or compromised edge can fabricate
input or lie about a device result. Racket must treat those as untrusted facts,
apply current workflow/authorization, and create business facts only through
its authoritative boundaries. This design cannot make unauthenticated hardware
observations trustworthy or neutralize a compromised POS Core.

## Assets and trust boundaries

Protected assets include transaction journal integrity, exact money, canonical
receipt truth, cash-ledger integrity, operator ownership/approval, physical
effect identity and uncertainty, device-role authorization, event continuity,
bounded availability, and customer/credential privacy.

```text
Flutter / kiosk
  → authenticated local POS API
Racket POS Core
  → SQLite journal, command receipts, cash/security state
  → private semantic UDS Edge Protocol
grocery-pos-edge
  → configuration-authorized device adapters
peripherals / untrusted OS-derived discovery properties
```

Racket is business authority. The
[local API](../architecture/local-api.md),
[authorization/ownership policy](authorization-and-ownership.md), and
[canonical receipt contract](../architecture/receipts.md) remain authoritative.
Edge has no SQLite access or authority to persist/alter sales, receipts as
business records, payments, cash movements, catalog, operator identity, or shifts.
If evidence matters after edge restart, Racket/SQLite must own it. Edge events
and cache entries are ephemeral device/operation state, not business history.

Runtime principals are `grocery-pos-kiosk` (GUI), `grocery-pos` (Racket/SQLite),
and `grocery-pos-edge` (selected peripherals). Only `grocery-pos` calls the
production socket; neither GUI nor raw hardware access belongs to Racket's
edge-client layer. Root and privileged technician administration are outside
this runtime separation and outside the containment claim.

## Actors and failure sources

The model includes broken, hostile, and misconfigured peripherals; a physical
attacker; compromised Flutter; a compromised ordinary local user; a buggy
Racket caller; a buggy adapter; a compromised edge daemon; resource exhaustion;
hotplug/churn; wall-clock anomalies; edge crash; and appliance update/rollback.
Correctness failures need not be malicious to duplicate a print or target the
wrong replacement device.

| Compromised component | Potential authority | What should remain prevented |
| --- | --- | --- |
| Flutter | UI and Racket API operations permitted to its authenticated session | Raw POS hardware, direct SQLite, Edge socket, bypass of server ownership/approval |
| Peripheral | Malformed/fabricated input; misleading responses and physical behavior | Direct business mutation or automatic authorization from presence |
| Adapter | Bound device I/O through the intended interface; arbitrary code execution may gain daemon authority | Typed interface must prevent arbitrary Core command/event mutation; no claim of an in-process security sandbox |
| Edge daemon | Configured physical-device control, possible fabricated observations/outcomes | POS SQLite/business-store access and payment authority |
| Racket | Business authority and allowed semantic edge commands | Direct arbitrary raw-device access and undeclared edge capabilities |
| Ordinary user | Ordinary OS privileges | Edge socket/hardware/configuration authority |
| Root | Effective host control | Explicitly outside containment claim |

A compromised Racket is already a serious business-authority compromise. It
could issue malicious allowed drawer/print commands with fresh identities;
Rust cannot infer whether those business decisions were legitimate. It can
still enforce its narrow configured semantic capabilities and OS boundary.
Likewise, memory safety and typed adapter handles mitigate bugs, but an adapter
with arbitrary code execution in the shared process is an edge compromise,
not something CoreActor isolation contains cryptographically.

## Hostile input, replacement, and spoofing

USB descriptors, serial strings, HID reports, scale/printer response packets,
and udev properties are untrusted. Require bounded parsing, allocation, and
logging; no shell interpretation, raw unbounded diagnostic echo, or arbitrary
wire-event construction. Malformed input faults the candidate/binding rather
than corrupting Core state. Hardware/library updates do not silently add
configuration capabilities.

**Generic USB VID/PID/serial/topology matching is operational authorization,
not cryptographic device attestation.** A capable physical attacker can spoof
descriptors. Layer mitigations: physical security, privileged provisioning,
strict selectors, port binding where appropriate, udev/systemd/SELinux access
restrictions, and future cryptographic identity when supported. None makes
generic descriptors proof of authenticity. Peripheral attacks on the host
kernel remain a residual risk.

One enabled privileged slot has one deterministic selector. Zero matches means
absent; one may bind; multiple means ambiguous/faulted. Never select the first
or weaken a serial-specific selector for a near-match. A topology selector may
intentionally follow a compatible replacement at a configured port. A candidate
cannot back two logical devices; composite printer/drawer capabilities should
share one binding/resource.

Kernel enumeration paths are current access paths, never durable identity.
Every successful attachment/rebind gets a new random binding ID, including
replugging the same physical unit. Invalidation stops admission and fences old
queued/executing work; late facts cannot update replacement state. No command
can reach new hardware merely because its stable logical slot name is unchanged.

Scanner binding must exclude the cashier's ordinary keyboard. The reference
path uses edge-owned hardware observations through Racket business authority,
not keyboard-wedge focus injection. Device-family permissions alone must not
cause all keyboard/input nodes to be opened or captured.

## Stale commands, duplicate effects, and uncertainty

Agent and binding preconditions fence process restarts and hardware replacement.
Stable Racket-generated command IDs distinguish transport retries from new
physical attempts; request IDs change per HTTP attempt. Duplicate equality is
typed/canonical, excludes request ID, and includes device/binding, freshness,
kind, timeout, and payload. Changed semantics conflict rather than reinterpret
an old intended operation.

A monotonic `not_after_agent_uptime_ms` prevents an unaccepted or forgotten
unchanged submission from becoming a new arbitrarily late effect. Existing
records deduplicate even after expiration; retry cannot extend freshness.
Admission timeout is separate from execution timeout. Wall clock is irrelevant
to both protocol safety and cache-retention timing.

There is a retention tension worth making explicit: freshness alone prevents
an unchanged expired request from re-executing, but cannot detect changed
semantics once its identity has been forgotten. The per-epoch conflict rule
therefore requires compact accepted-command identity and terminal state for
the whole epoch. Full sensitive payloads can be discarded. All retention stays
within the command-record bound; when full, new admission fails. Loss of Core
identity evidence requires a new process epoch, not silent reuse. Initial
capacity/throughput needs M8.2 qualification; changing this guarantee would
require an explicit architectural decision.

Core must reserve capacity and create a record before physical execution. Queue,
cache, stale epoch, invalid payload, and freshness failures happen before
acceptance/effect. Binding/deadline checks also fence already-queued commands.
One resource runs one command at a time, even when printer and drawer operations
share a transport; different resources may run concurrently.

EffectTracker belongs to Core/Executor. Adapters only advance `None → Possible
→ Confirmed`, marking `Possible` before the first potentially effective I/O.
Timeout/panic with `None` permits known non-effect failure; with `Possible`
and no reliable success/failure evidence it requires `unknown + possible`.
Partial known failure may also have possible effect and is not safe to repeat.
Terminal state cannot be rewritten by later observations.

Rust does not choose business retry policy or emit a generic retryable flag.
Lost responses, cache absence, restart, and `unknown` must not automatically
create a replacement print/drawer attempt. Racket-owned recovery must preserve
uncertainty, operation correlation, and any required durable intent.
[ADR-0011](../adr/0011-use-durable-command-receipts-and-expected-stream-versions.md)
does not promise exactly-once hardware execution or permit holding a SQLite
writer lock around I/O. M8.4 will define durable print-job behavior separately.

Printer success does not establish sale completion or customer possession;
printer failure does not roll back a sale. Drawer opening does not establish
tender or cash movement. Weight does not establish price, tax, or money.
Generic v1 payment authorization/capture/void/refund/reconciliation and other
card-payment execution are prohibited, not merely deferred command kinds.

## Adapter/Core failure and resource exhaustion

Per-command supervised execution must conservatively derive terminal state,
invalidate a binding after driver timeout/panic, and close/discard its
transport. The old executor must stop or be fenced before replacement I/O;
potentially corrupted protocol state cannot be reused. Core/control-plane
invariant failure terminates the whole daemon and changes agent epoch on
restart. This is a larger blast radius than an ordinary binding failure.
Known non-effect requires fencing old execution against a first-I/O/deadline
race; sampling `None` while the adapter could still act does not establish it.
If fencing fails, preserve uncertainty and fail the process when execution
cannot be contained.

All requests, queues, caches, observations, subscribers, and framing buffers are
bounded. v1 initial targets are approximately 16 KiB headers, 256 KiB command
body/non-stream response, 64 KiB event record, 60-second maximum timeout,
32 waiting commands per resource, 4096 command records, at least 120-second
terminal recovery, and one operational stream. These are implementation
defaults to qualify, not eternal protocol constants. Aggregate configured
devices/resources and connection/parser work also need bounds.

Memory exhaustion must not cause silent loss of command identity or event
continuity. Cache/queue overflow rejects new commands before acceptance.
Subscriber overflow closes the stream for a new snapshot; internal observation
overflow becomes an explicit continuity/binding fault. If safe failure reporting
is impossible, fail the control plane. Repeated churn may deny availability;
it must not authorize a near-match, reuse an old binding, or grow memory forever.

The first event record is an atomic configured-device snapshot and cursor.
Subsequent events share a monotonic per-agent sequence; gaps are continuity
failures. Heartbeats do not consume sequence numbers. Disconnect may lose
transient scans; a reconnect snapshot recovers current state, not stale input.
There is no replay broker. Racket must mark event-stream health separately from
device availability and process liveness.

## Local privilege and deployment targets

Future deployment must enforce these layers together:

| Layer | Required purpose |
| --- | --- |
| systemd device cgroup | Permit only qualified device classes/families |
| udev/DAC | Give edge UID/group access to concrete recognized nodes |
| SELinux | Mandatory separation under enforcing policy |
| Root-owned `edge.toml` | Authorize one candidate for one logical slot/adapter |
| Capability allowlist | Bound semantic operations callable by POS Core |
| Socket DAC and `SO_PEERCRED` | Permit expected Racket UID, deny kiosk/ordinary users/wrong UID even with group access |
| Flatpak and Unix identity separation | Keep presentation away from raw POS input/USB, database, config, and edge socket |

The systemd-owned pathname listener target is root:
`grocery-pos-edge-api`, mode `0660`. Parent directories, labels, listener
descriptor inheritance, and lifetime alongside POS Core's runtime directory
must be qualified. Peer credentials identify the OS principal, not the caller
executable; code running as `grocery-pos` is inside that principal's trust
boundary. Linux documents pathname DAC and peer credentials in
[unix(7)](https://man7.org/linux/man-pages/man7/unix.7.html).

Root-controlled `/etc/grocery-pos/edge.toml` is read-only to edge, never rewritten
by it, and not writable by Racket or Flutter. Configuration declares
`schema_version = 1`, with strict validation, privileged changes, and service
restart. No production live mutation/reload exists. Unknown compiled adapters fail closed; runtime
shared-object plugins are excluded.

The [architecture hardening target](../architecture/edge-agent.md) specifies
the intended systemd directives and narrow udev group `grocery-pos-edge-hw`.
Udev must not run business commands, assign logical roles dynamically, modify
config, or grant desktop `uaccess` to POS peripherals. Zero ambient capabilities
is the default; `CAP_SYS_ADMIN`, `CAP_SYS_RAWIO`, and `CAP_DAC_OVERRIDE` are not
integration shortcuts. Additional privilege requires explicit security review.

No generic LAN/Internet authority is needed. Prefer `PrivateNetwork=yes` or
equivalent where compatible. Its impact on udev netlink delivery must be
qualified rather than assumed away, as described by
[systemd execution sandboxing](https://raw.githubusercontent.com/systemd/systemd/main/man/systemd.exec.xml).
An Ethernet/network peripheral requires a new design review. This does not
change Racket's host-loopback API topology.

Fedora Kinoite remains SELinux enforcing. Existing policy may suffice or a
narrow edge policy may be required; disabling enforcement is never an
integration option. Enforcing mode applies mandatory policy, while permissive
mode records would-be denials; see
[Red Hat's SELinux documentation](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/using_selinux/getting-started-with-selinux_using-selinux).
This supports the enforcement requirement, not proof of Fedora edge deployment.

Appliance update/rollback must preserve strict config/protocol compatibility,
privileged provisioning, capability allowlists, and runtime separation. Edge
restart changes epochs; old pending operations are not automatically replayed.
An OS rollback does not restore or downgrade POS SQLite. M8.1 changes no
existing migration, update mechanism, or M6/M7 qualification record.

## Privacy, logging, and simulation

Ordinary edge logs may contain logical device ID, adapter kind, availability
transition, sanitized condition/fault, published capability set, latency,
binding lifecycle, and agent version. They must not normally persist receipt
content, barcode values, raw scale transaction history, raw USB/serial packets,
customer content, credential-like values, full environments, or a raw udev
database. Bound and sanitize device-derived strings even in error paths.

PINs, passwords, private keys, credential verifiers, tokens/capability digests,
full PAN, CVV/CVC, track data, sensitive raw EMV, and unsanitized secret-bearing
device responses must not enter logs/support output. Generic payments being
excluded is not permission to dump a misconfigured terminal's traffic.

Support bundles remain explicitly allowlisted under
[ADR-0023](../adr/0023-build-support-bundles-from-allowlisted-operational-metadata.md).
The current collector is not extended here. Future safe operational sections
must not implicitly export raw logs, full config, physical identities, or cache
fingerprints. Fingerprints support in-memory equality, not ordinary diagnostics.

Every adapter must have a deterministic simulator following the real binding,
queue/cache, tracker, timeout, event, and Core paths. Production simulated
configuration fails unless launch explicitly permits simulation. Device absence
must never silently select it. Simulator success is not physical qualification.

## Normative M8 edge invariants

The following constrain all future implementation and qualification:

1. **E1:** Only Racket POS Core may call the production Edge Protocol.
2. **E2:** Flutter has no direct Edge Protocol or raw peripheral authority.
3. **E3:** Edge has no authority to create or mutate POS business facts.
4. **E4:** Edge cannot directly access POS SQLite.
5. **E5:** Device presence never implies device authorization.
6. **E6:** Commands target an agent epoch and binding epoch.
7. **E7:** A stale agent/binding command cannot produce a physical effect.
8. **E8:** A command record exists before its physical effect can begin.
9. **E9:** Same command ID plus same semantics executes at most once per agent epoch.
10. **E10:** Same command ID plus different semantics is rejected; compact identity must survive the epoch to enforce this.
11. **E11:** Expired, forgotten submissions cannot become arbitrarily late effects.
12. **E12:** Physical outcomes distinguish known failure from uncertainty.
13. **E13:** `unknown` is never silently converted into success or failure.
14. **E14:** Rust does not decide business retry policy.
15. **E15:** Discrete effects are not automatically repeated once effect may have begun.
16. **E16:** One physical resource executes one semantic command at a time.
17. **E17:** All queues, caches, requests, and event channels are bounded.
18. **E18:** Event loss is detectable; silent loss is forbidden.
19. **E19:** Edge events are ephemeral observations, not business history.
20. **E20:** Device reconnect always creates a new binding epoch.
21. **E21:** Adapters cannot arbitrarily mutate Core-owned command/event identity through their interface; arbitrary code execution remains a daemon compromise.
22. **E22:** Core/control-plane failure creates a new agent epoch.
23. **E23:** Generic Edge Protocol exposes no arbitrary raw-device command channel.
24. **E24:** Published capabilities are explicitly configuration-allowlisted.
25. **E25:** Payment authorization and other card-payment execution are outside generic Edge Protocol v1.
26. **E26:** Simulation cannot activate accidentally in production.
27. **E27:** Reference appliance qualification requires SELinux enforcing.
28. **E28:** Wall-clock correctness is not required for protocol safety.
29. **E29:** Hardware descriptors and device traffic are untrusted input.
30. **E30:** Generic USB identity is not cryptographic attestation.

## Future acceptance tiers

These tiers describe future M8 evidence, not execution performed in M8.1. They
continue the project's evidence separation in the
[M6](../acceptance/m6/README.md) and [M7](../acceptance/m7/README.md) records
without changing those milestones' historical tier meanings or results.

| M8 tier | Evidence required | What it cannot establish |
| --- | --- | --- |
| A — deterministic repository qualification | Protocol/Core invariants, simulator and Racket-client behavior; no physical hardware; normal CI once implemented | Deployed OS permissions or real device behavior |
| B — Linux appliance security qualification | Booted target's systemd, UDS/DAC/peer UID, identities, udev, cgroup, SELinux, filesystem/Flatpak/config isolation | A selected physical model's driver correctness |
| C — physical-device qualification | Selected model's actual USB/HID/serial behavior, hotplug, conditions, and driver behavior | Complete lane workflow and recovery |
| D — integrated lane qualification | Flutter → Racket → SQLite and Racket → Rust → physical device under representative checkout failures | Universal device certification or exactly-once effects |

A simulator pass cannot be recorded as Tier C or D physical evidence. M8 Tier D
is integrated lane qualification; it does not relabel M6/M7's physical power
interruption evidence. Device-specific cases remain high level until models
and command schemas are selected.

### Tier A: deterministic future contract

Future normal CI must cover protocol semantics, Core ownership, typed decoding,
configuration, simulation, client behavior, and at least these cases:

| Case | Required observation |
| --- | --- |
| Old agent command | Rejected before effect |
| Old binding command, including already queued work | Rejected/fenced; cannot reach replacement hardware |
| Same ID/same semantics, including lost response/concurrent submissions | One execution; existing state returned |
| Same ID/different semantics | Conflict; original command preserved |
| Expired unseen/forgotten submission | New execution rejected before effect; retained identities still deduplicate/conflict |
| Record-before-effect | Effect start observes the already-created record |
| Queue overflow | Pre-acceptance failure; no effect or accepted record |
| Cache guarantee/capacity | Nonterminal/fresh/recovery evidence and epoch identity preserved; reject new work when full |
| Timeout before effect | Known non-effect, such as `failed + none`; fenced execution cannot act later |
| Timeout after possible effect | `unknown + possible`; binding invalidated |
| Panic before effect | Known non-effect; binding invalidated if driver execution began |
| Panic after possible effect | `unknown + possible`; binding invalidated and old transport fenced |
| Same physical resource | Commands never overlap |
| Different resources | Independent commands may execute concurrently |
| Event subscription | Atomic snapshot/cursor; no snapshot-to-stream race |
| Event ordering | Contiguous monotonic sequence within one agent; heartbeat does not consume it |
| Subscriber overflow | Stream closes; reconnect obtains new snapshot |
| Internal observation overflow | Explicit continuity/binding fault, never hidden loss |
| Restart | New agent ID; old pending operations not automatically replayed |
| Replug | New binding ID even for identical hardware |
| Malformed/duplicate-key/unknown-field JSON | Strict rejection at all relevant nesting levels |
| Oversized request/record/configuration | Explicit bounded failure; no incomplete snapshot or unbounded buffers |
| Terminal payload privacy | Full sensitive payload discarded; equality/conflict and safe terminal state retained |
| Production simulator guard | Simulated adapter fails without explicit launch permission |
| Strict configuration/binding | Unknown adapter/version/field and ambiguous or duplicate candidate claims fail closed |
| Racket client | Epoch/gap/wire-error handling and cache absence preserve uncertainty; business retry is not invented |

Deterministic adapter scenarios must include connect/disconnect, barcode input,
stable/unstable weight, paper-out, pre-effect failure, possible-effect crash,
success confirmation, panic, timeout, and rebind through the actual Core paths.

### Tier B: real Linux security boundary

Future positive qualification must prove that `grocery-pos` can connect; edge
can open an authorized device and read its root-controlled config; and the
workflow succeeds under SELinux enforcing. Record actual service identities,
socket/parent permissions and lifetime, peer UID enforcement, device cgroup,
udev permissions, filesystem isolation, and narrow Flatpak grants.

Future negative qualification must prove:

- Kiosk and ordinary users cannot connect to the edge socket.
- A wrong UID with socket-group access is still rejected by `SO_PEERCRED`.
- Kiosk and Racket cannot open raw POS peripherals.
- Edge cannot read POS SQLite or home data and cannot modify `/etc`.
- Edge has no unintended network access; qualified discovery/hotplug still works.
- Cashier Flatpak cannot access raw USB/input or the edge endpoint.
- The cashier's ordinary keyboard is not captured by scanner binding.
- Configuration ownership and simulation launch permission cannot be changed by
  runtime identities.

Proposed hardening text is not evidence that these checks pass. SELinux
enforcing status is required evidence; a permissive run cannot substitute.

### Tier C: selected physical devices

| Device | Representative real-hardware cases |
| --- | --- |
| Printer/drawer transport | Normal print, paper-out, cover-open, disconnect before effect, disconnect after possible effect, reconnect, drawer pulse, power cycle, boundary-size receipt |
| Scanner | Valid/rapid scans, disconnect/reconnect, wrong keyboard-like device, malformed report, event flood |
| Scale | Zero, stable/unstable weight, overcapacity, disconnect/reconnect, rapid observations |

Qualify selected model/firmware/connection combinations; simulator transcripts
do not substitute for the device's actual success criterion or failure behavior.

### Tier D: integrated lane

Future integrated qualification must exercise a scan, cash checkout, drawer
action, printer absent after sale commit, unknown print outcome, unavailable
scanner with manual fallback, edge restart, hardware replacement, and stale
command rejection. Confirm authoritative totals, receipts, cash facts, operator
authorization, uncertainty handling, and continued local-first behavior across
the whole lane. No payment transaction is a generic edge qualification case.

### Machine-readable evidence direction

Future implementation/qualification should continue machine-readable acceptance
ledgers. A conceptual record is:

```json
{
  "scenario": "edge.command.timeout_after_effect_possible",
  "tier": "A",
  "result": "pass",
  "expected": {
    "outcome": "unknown",
    "effect_evidence": "possible",
    "binding_invalidated": true
  }
}
```

This example is not an executed result. Actual records must distinguish
expected behavior from observations and pass/fail/blocked/not-run evidence.
Physical evidence should identify relevant device model, firmware, connection,
appliance/agent version, and SELinux state without serial numbers, credentials,
customer data, raw packets, or sensitive host metadata. M8.1 creates no ledger.

## Residual risks and explicit non-goals

Physical compromise can spoof observations, misdirect hardware, or attack the
kernel; compromised edge can lie about effects. In-process adapters share a
daemon compromise boundary. Crashes can leave irrecoverably uncertain effects,
and transient disconnected input can be lost. Compact per-epoch command identity
consumes bounded capacity; sustained throughput and safe recovery on restart
need implementation qualification. Correct workflow and retry policy in Racket
remain essential.

Edge Protocol v1 does not provide:

- Cryptographic authentication of generic USB peripherals.
- Exactly-once physical effects or durable edge event replay.
- Payment-card authorization, execution, or reconciliation.
- Containment against root compromise or malicious business decisions by a
  compromised POS Core.
- Remote Internet/LAN device administration or live configuration mutation.
- Atomic multi-device hardware transactions.
- Proof that a printed receipt was physically taken by a customer.

These are honest scope boundaries. Qualification must not turn an accepted
architecture, intended deployment rule, or simulator result into a claim of
implemented or physically tested security.
