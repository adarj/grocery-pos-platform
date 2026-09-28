# POS edge-agent architecture

## Status and authority

This is the accepted M8.1 architecture under
[ADR-0033](../adr/0033-use-a-semantic-local-edge-protocol-for-pos-hardware.md).
It specializes [ADR-0005](../adr/0005-use-rust-for-system-edge-agents.md).
Requirements below govern future implementation; M8.1 adds no Rust daemon,
workspace, client, hardware driver, unit, udev rule, or SELinux policy. The
[protocol specification](edge-protocol-v1.md) owns wire semantics; the
[threat model](../security/edge-agent-threat-model.md) owns the numbered
invariants and future qualification contract.

> Flutter presents. Racket decides. SQLite remembers. Rust talks to edges.
> The cloud coordinates.

```text
Flutter (presentation only)
   ↓ local POS API
Racket POS Core (business authority) → SQLite (durable business truth)
   ↓ private semantic Edge Protocol
Rust grocery-pos-edge (physical-device authority)
   ↓
USB / HID / serial / other local peripherals
```

**Devices may observe physical reality and enact explicitly requested physical
effects, but they never become a second business-authority path around Racket
and SQLite.**

| Device action | Authority it does not establish |
| --- | --- |
| Scanner reports a barcode | Adding a sale line |
| Scale reports a measurement | Computing money |
| Printer prints a receipt | Creating a receipt or committing a sale |
| Drawer opens | Recording cash tender |

Racket owns catalog lookup, exact integer monetary decisions, pricing, tax,
operator authentication/authorization, transaction mutations, retry policy,
and durable business facts. Device input crosses the same Racket decisions as
other input; it cannot bypass ownership, approval, or the typed transaction
command boundary. See the [local API](local-api.md),
[Racket runtime](racket-runtime.md), and
[authorization policy](../security/authorization-and-ownership.md).

Ordinary checkout remains local-first. No cloud, inventory, reporting,
telemetry, or update dependency joins the synchronous checkout path here.
Generic Edge Protocol v1 MUST NOT authorize, capture, void, refund, reconcile,
or otherwise execute card-payment transactions. Payment terminals require a
future specialized financial/payment architecture, even if it borrows edge
design principles.

A normal second-monitor customer display is a presentation projection of
Racket-authoritative state. It must not be routed through `grocery-pos-edge`.
Actual low-level protocols, such as a legacy serial pole display, can warrant
an edge adapter without transferring sale authority.

## One supervised lane-local service

M8 v1 will use one `grocery-pos-edge` OS process per lane, not one process per
scanner, printer, or scale. Independent bindings and executors isolate adapter
state within that supervised daemon. This keeps one Racket contract, command
identity domain, event order, and security policy while avoiding premature
systemd, packaging, and IPC complexity.

```text
EdgeSupervisor
   ├── ProtocolServer
   ├── CoreActor
   │    ├── DeviceRegistry
   │    ├── CommandCache
   │    └── EventSequencer
   └── BindingManager
          └── BindingRuntime (one per successful binding)
               ├── CommandExecutor
               ├── ObservationTask
               └── DeviceAdapter
```

These are conceptual ownership boundaries, not chosen Rust crates or framework
types. M8.2 must qualify implementation choices; M8.1 does not mandate Tokio,
Axum, Hyper, JSON, udev, USB, serial, or printer libraries. Future hardware may
require out-of-process adapters. That escape hatch is preserved without
designing its IPC, process topology, or plugin mechanism now.

## Core and adapter ownership

Only CoreActor may own or mutate the agent instance, public device state,
device state revisions, command records, deduplication, public command
phase/outcome, event sequence, and the single operational event subscriber.
Core serializes decisions about those values; other tasks report typed facts.
Core attaches public identity and ordering fields rather than trusting an
adapter to choose them.

ProtocolServer terminates HTTP and JSON at the boundary. Device adapters receive
typed semantic commands, not `serde_json::Value` or arbitrary wire objects.

| Component | Responsibility |
| --- | --- |
| ProtocolServer | Bounded strict parsing, peer checks, HTTP framing, typed Core requests, response serialization |
| CoreActor | Registry truth, acceptance arbitration, deduplication, command state, event sequence/subscriber |
| BindingManager | Bounded discovery and deterministic reconciliation of privileged logical slots |
| BindingRuntime | Lifetime of one binding, transport, executor, and observation task |
| CommandExecutor | Bounded FIFO serialization of one physical resource and supervised execution |
| ObservationTask | Bounded typed observations and explicit continuity failures |
| DeviceAdapter | Device protocol/I/O, device-specific validation, typed observations, sanitized driver facts/errors |

Adapters do not own HTTP, JSON, Racket logic, command identity, deduplication,
retry policy, sequencing, device authorization, or business persistence. They
cannot construct arbitrary wire events or alter another command/device.
Internal adapter isolation is an ownership and failure boundary, not a security
sandbox against arbitrary code execution inside the shared process.

Adapters are compiled into the executable/package. Configuration names a
supported compiled adapter; an unknown adapter fails closed. v1 has no
runtime-loaded shared-object plugins.

## Configuration and device authorization

Physical configuration will reside in root-controlled
`/etc/grocery-pos/edge.toml`, read-only to the daemon and not writable by
Racket or Flutter. Edge must never rewrite it automatically. Privileged
administration and an edge-service restart are required for a change; there is
no production live reload in v1. Restart creates a new agent epoch.

The configuration must declare:

```toml
schema_version = 1
```

M8.2 must supply strict, bounded configuration parsing and reject unsupported
versions, unknown fields/adapters, duplicate logical IDs, and invalid selectors
or capability declarations. This checkpoint does not invent the complete TOML
slot syntax.

| Edge configuration answers | Racket/register configuration answers |
| --- | --- |
| Which physical candidate may bind this logical device? | What business/register role does this logical device perform? |
| Which compiled adapter is allowed? | Which workflow requires it? |
| Which semantic capabilities are allowed? | What fallback is allowed if unavailable? |

USB/serial selectors must not enter business transaction configuration.
**Discovery is not authorization.** OS discovery may see many candidates; only
a unique match for an enabled privileged configuration slot may acquire a POS
role. Public Edge Protocol snapshots contain configured logical devices, not
arbitrary unconfigured USB enumeration. A future privileged installer or
maintenance tool may inspect candidates separately.

Published capabilities are exactly:

```text
configured allowed capabilities
  ∩ adapter implementation
  ∩ current physical hardware capability
```

For example, hardware/driver support for `receipt.print`, `drawer.open`, and
`firmware.update` publishes only `receipt.print` and `drawer.open` when those
two are configuration-allowlisted. An update cannot silently grant new
capabilities. There is no normal v1 raw/vendor command capability.

## Identity, selectors, and binding lifecycle

| Identity level | Meaning and lifetime |
| --- | --- |
| Logical device ID | Stable configured slot, such as `lane-01.receipt-printer`, `lane-01.scanner`, or `lane-01.scale`; survives hardware replacement |
| Physical candidate identity | Bounded bus, vendor/product, useful serial, topology, interface, and sysfs properties used for operational matching |
| Binding instance ID | Random opaque ID for one successful attachment/binding epoch; replaced after disconnect/reconnect, replacement, transport invalidation/rebind, or daemon restart |

Generic VID/PID/serial/topology matching is operational authorization, not
cryptographic device attestation. Kernel paths such as `/dev/ttyUSB0`,
`/dev/input/event7`, `/dev/hidraw3`, and `/dev/bus/usb/003/014` are current access
paths, never durable POS identities. Enumeration order must not determine
authorization.

Each logical slot has one deterministic selector:

```text
zero matches     → absent
exactly one      → candidate may bind after global uniqueness checks
multiple matches → ambiguous/faulted; never select the first
```

One physical candidate may back at most one logical device in v1. If two slots
claim it, reconciliation must fail closed rather than let order choose a
winner. Composite printer capabilities such as `receipt.print`,
`printer.status`, and `drawer.open` normally share one logical printer binding,
not duplicate bindings to the same hardware.

A serial-specific selector follows one physical unit. A physical-port/topology
selector follows a compatible replacement at that physical position and is
acceptable when reliable unique serial identity is unavailable. A near-match
must never silently weaken a serial-specific selector.

```text
OS device add
  → DiscoveryCandidate
  → BindingManager reconciliation
  → selector match
  → global uniqueness check
  → adapter bind
  → new binding_instance_id
  → Core device-state update
```

Core remains the public registry authority while BindingManager reports typed
binding facts. On remove or transport loss, invalidate the binding immediately,
stop accepting commands for it, and resolve queued/in-flight operations
conservatively. An old binding ID is permanently stale for new execution. The
logical slot moves to absent/connecting as appropriate. Replugging identical
hardware still creates a new binding instance. Delayed facts from an invalidated
binding cannot update its replacement.

## Command acceptance and bounded execution

Racket creates a fresh unpredictable edge `command_id` for each new semantic
physical-operation attempt. Transport retries preserve that ID, the same
semantic command, and the original `not_after_agent_uptime_ms`, with a new
per-request `request_id`. Racket must not recycle an old ID with changed
semantics or extended freshness to represent a new operation. These edge
identities are distinct from durable transaction-command receipts: an edge
command describes one physical attempt, not a sale mutation. Commands target
both agent and binding epochs; the submission deadline uses agent monotonic
uptime and cannot exceed a bounded maximum future horizon for new admission.
The initial horizon target is approximately 60 seconds, qualified separately
from the acceptance-relative execution timeout.

Core must preserve this logical acceptance order:

```text
parse + structural validation
  → agent-instance precondition
  → existing command_id lookup
  → submission freshness + maximum submission horizon check
  → device lookup
  → binding-instance precondition
  → capability/payload validation
  → cache capacity
  → reserve bounded executor-queue slot
  → CREATE COMMAND RECORD
  → enqueue
  → physical effect may begin
```

**A command record exists before its physical effect can begin.** Freshness,
submission-horizon, binding, cache-full, and queue-full failures precede
acceptance and effect.
Lookup/reservation/record creation must be arbitrated so concurrent requests
cannot bypass deduplication. Reservation or handoff failure must not start an
unrecorded effect. Detailed duplicate and retention semantics are normative in
[Edge Protocol v1](edge-protocol-v1.md).

Each underlying physical resource uses one bounded FIFO executor. Printer
output and a drawer pulse over that printer transport share its executor.
Different resources may execute concurrently. v1 has no priorities,
cancellation, or atomic multi-device command. An initial target is 32 queued
commands per resource, separately from the executing command; numerical bounds
require M8.2 qualification.

Before execution, the executor must recheck that the binding is still valid and
the acceptance-relative timeout has not elapsed. A command already queued for
an old binding must never migrate to replacement hardware. Commands without an
effect remain distinguishable from ones that might have affected the device.

## EffectTracker and failure isolation

The semantic effect classes are:

| Class | Examples | Implication |
| --- | --- | --- |
| `Observation` | Scale/status read | Reports facts; no business mutation |
| `ReplaceableState` | Future indicator/display state | Racket can reason about replacing desired state |
| `DiscreteEffect` | Receipt print, drawer open | Must not be blindly repeated once effect may have begun |

Core/Executor owns a monotonic EffectTracker:

```text
None → Possible → Confirmed
```

Adapters get only a restricted handle that advances the tracker. They must mark
`Possible` immediately before the first action after which the requested
semantic effect could have occurred. `Confirmed` requires the command-specific
success criterion. Adapters cannot reset evidence or own public outcomes.

Commands progress through accepted, executing, and immutable terminal state.
Public outcomes are `succeeded`, `rejected`, `failed`, or `unknown`, accompanied
by `none`, `possible`, or `confirmed` effect evidence. **Unknown is not failed.**
Core uses tracker evidence to classify disconnect, panic, or timeout
conservatively. A panic with `None` permits known non-effect failure; panic or
timeout with `Possible` requires `unknown` when success cannot be established.
Later observations cannot rewrite a terminal command.

Execution must be supervised per command. On timeout or panic after driver
execution begins, derive the terminal result from the tracker, invalidate the
binding, and close/discard the transport. Stop/fence the old executor before
rebinding; a timed-out task cannot keep issuing I/O concurrently with its
replacement. Rebinding creates a new binding ID rather than reusing potentially
corrupted driver state. A queue timeout before driver execution need not
invalidate an otherwise sound binding.

Terminalization must also fence the race between deadline handling and an
adapter's first I/O. A known `none` result requires evidence that old execution
cannot subsequently start the requested effect. Do not sample `None`, publish
failure, and leave an executor able to advance/send afterward. If safe fencing
cannot be established, preserve uncertainty and keep the binding invalid;
uncontainable execution/control failure requires process termination.

A CoreActor/control-plane invariant failure is more serious: terminate the
whole edge process so systemd creates a new agent epoch. M8.2 must qualify actual
panic supervision and transport shutdown; no framework choice is implied here.

## Ephemeral state and Racket recovery

Edge may retain only ephemeral device state, queues, bindings, command cache,
and event counters. It has no SQLite database, durable cache, receipt database,
barcode history, or second business store. It must not persist sales, payments,
cash movements, catalog, operator identity, shifts, or business retry policy.
If a fact matters after edge restart, it belongs to Racket/SQLite.

Every accepted nonterminal command record must remain retained. A terminal
record must remain until both its original submission freshness deadline has
passed and the terminal recovery minimum has elapsed, initially at least 120
seconds after completion. After both conditions hold, bounded policy may evict
the compact terminal record; it need not survive the entire agent epoch.
While retained, it supports metadata, private semantic fingerprint,
outcome/effect evidence, safe result/error, and timings without full receipt or
other sensitive payload content. Payload disposal cannot bypass required
compact-record retention.

Retained identities deduplicate identical commands and conflict on changed
semantics. After safe eviction, an exact replay carries an expired original
deadline and is rejected before effect. Deliberate recycling of an evicted ID
with extended freshness is prohibited client behavior; a bounded ephemeral
server cannot detect it indefinitely. Lookup may return 404 after eviction,
which never proves non-effect.

Cache capacity is a sliding bounded working set with reusable capacity, not a
process-lifetime identity count. Admission fails before acceptance when required
nonterminal/freshness/recovery retention leaves insufficient room; no protected
evidence may be evicted early. Safely expired terminal records may be reclaimed.
The detailed rules are in [Edge Protocol v1](edge-protocol-v1.md). M8.2 must
qualify capacity, command rate, recovery/freshness horizons, and memory use.

Future Racket integration will maintain a conceptual `EdgeSession` containing
agent ID, current event cursor, current device snapshots, stream health, and
outstanding commands. A new agent ID discards old binding assumptions, obtains
fresh state, and does not automatically replay old pending physical operations.
A lost cache or restart never proves non-effect.

M8.2's generic Racket client boundary will conceptually expose `edge-open`,
`edge-health`, `edge-status`, `edge-devices`, `edge-device`,
`edge-submit-command`, `edge-command-status`, and `edge-open-events`. Only that
layer knows UDS HTTP, JSON envelopes, epoch validation, wire errors, and event
framing. No client code is added in M8.1.

[ADR-0011](../adr/0011-use-durable-command-receipts-and-expected-stream-versions.md)
continues to govern durable business-command identity and expected stream
versions. Do not hold a SQLite writer transaction open around device I/O.
Future durable physical-operation intent/recovery belongs above edge; generic
ephemeral edge deduplication does not supply exactly-once physical effects.

## Peripheral meaning

The reference scanner path is:

```text
physical scanner → edge-owned hardware interface → normalized barcode observation
  → Racket catalog/business authority → transaction mutation → Flutter
```

Keyboard-wedge focus injection is not the reference design. Certification
should favor scanner modes permitting clean service ownership. Edge must not
capture the cashier's ordinary keyboard; a keyboard-like candidate is not
authorized merely because it looks like a scanner.

An [authoritative receipt](receipts.md) exists above the printer. Printing is a
derived physical effect: printer success is not sale success, failure does not
roll back a sale, and an unknown print outcome must not trigger automatic
duplicate printing. M8.4 will define durable print-job semantics; this document
defines only their generic edge foundation.

`drawer.open` is a physical effect requested after a Racket business decision.
Neither its result nor a drawer observation establishes tender or a cash-ledger
movement. [ADR-0017](../adr/0017-use-an-append-only-shift-cash-ledger-for-drawer-accountability.md)
remains the cash-accounting authority.

Weight is a device fact; money is a Racket decision. Rust may normalize scale
measurement and status, but never item price, tax, or monetary value. M8.6 may
specialize certified retail-scale behavior later.

## Availability and operational degradation

Generic availability states are `disabled`, `absent`, `connecting`, `ready`,
`degraded`, and `faulted`. Namespaced conditions such as `printer.paper_out`,
`printer.cover_open`, or `scale.unstable` carry details separately. Racket
decides whether a condition blocks a workflow.

The service may report healthy after configuration validates, Core initializes,
discovery initializes, BindingManager runs, and the protocol listener is
available. Every configured peripheral need not be present:

```text
edge healthy; printer absent; scanner ready; manual entry available
  → checkout potentially still available under Racket workflow policy
```

Edge `/v1/health` measures process/protocol liveness, `/v1/status` reports agent
metadata, and `/v1/devices` reports capabilities/state. None replaces POS Core
`/health` or its SQLite-oriented `/ready` contract under
[ADR-0020](../adr/0020-keep-pos-core-api-loopback-only-and-separate-liveness-from-readiness.md).
A missing printer must not automatically make POS Core globally unready.

## Linux identities and listener ownership

The future runtime authority matrix extends the
[M6 appliance isolation](../operations/kinoite-appliance.md):

| Identity | POS SQLite | Edge API | Raw POS peripherals | GUI |
| --- | --- | --- | --- | --- |
| `grocery-pos-kiosk` | No | No | No | Yes |
| `grocery-pos` | Yes | Client only | No | No |
| `grocery-pos-edge` | No | Server only | Selected nodes only | No |

Root/technician administration is outside this runtime model. The edge identity
must not join the POS database group; Racket and kiosk must not join the
hardware group. Runtime identity is an OS principal boundary, not proof of an
executable's integrity.

The deployment target is a systemd-owned listener:

```text
grocery-pos-edge.socket → /run/grocery-pos/edge.sock → grocery-pos-edge.service
socket owner: root; group: grocery-pos-edge-api; mode: 0660
```

The exact pathname may be machine-configurable. Production uses a filesystem
pathname socket, not an abstract socket, and Rust must consume the supervised
listener rather than create/chmod/unlink it. systemd's socket ownership and
mode controls support this target; see the
[upstream socket-unit documentation](https://raw.githubusercontent.com/systemd/systemd/main/man/systemd.socket.xml).
Socket activation need not imply lazy operation: the daemon may start eagerly
for discovery/hotplug.

`grocery-pos` may connect; kiosk may not. Socket group membership alone is
insufficient: Rust must verify the expected `grocery-pos` UID with `SO_PEERCRED`
on every accepted connection before protocol work. Failure to obtain or match
credentials denies the connection. Linux supplies peer credentials for connected
Unix stream sockets; see [unix(7)](https://man7.org/linux/man-pages/man7/unix.7.html).
The expected UID is resolved from privileged system identity, not a request
field. No bearer token or TLS is required for this private channel.

Later packaging must coordinate parent-directory traversal, ownership/labels,
and socket lifetime with the existing POS Core `RuntimeDirectory=`. A POS Core
restart must not remove or orphan the edge listener; socket permissions alone
do not settle directory lifecycle. This is a future Tier-B validation target,
not a change to the current service.

## Layered peripheral access and hardening target

No single layer suffices:

```text
systemd device cgroup → broad permitted device classes
udev/DAC              → concrete recognized nodes accessible to edge UID/group
SELinux               → mandatory access-control boundary
edge.toml selector    → one candidate authorized for one logical slot
capability allowlist  → semantic operations POS Core may request
```

Future udev rules should only recognize supported families, assign
service-controlled node permissions, and optionally attach bounded discovery
metadata. Prefer `grocery-pos-edge-hw`, used only by edge. Rules must not run
business commands, change configuration, dynamically assign a POS slot, print,
or invoke Racket. Do not grant desktop-session `uaccess` for POS peripherals.
udev supports node owner/group/mode assignment; see its
[upstream documentation](https://raw.githubusercontent.com/systemd/systemd/main/man/udev.xml).

The following is a design target excerpt, **not an existing unit**:

```ini
[Service]
User=grocery-pos-edge
SupplementaryGroups=grocery-pos-edge-hw
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=no
DevicePolicy=closed
# Adapter/device-family-specific DeviceAllow entries require qualification.
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
LockPersonality=yes
RestrictRealtime=yes
CapabilityBoundingSet=
AmbientCapabilities=
UMask=0077
Restart=on-failure
```

`PrivateDevices=no` permits a qualified subset of physical nodes to be visible;
it does not grant permission to use them. The device cgroup remains closed with
explicit family-specific allowances. Consult upstream
[execution sandboxing](https://raw.githubusercontent.com/systemd/systemd/main/man/systemd.exec.xml)
and [device access controls](https://raw.githubusercontent.com/systemd/systemd/main/man/systemd.resource-control.xml).
Exact directives and hotplug behavior must be validated on selected hardware.

Default design requires zero ambient Linux capabilities. Do not use
`CAP_SYS_ADMIN`, `CAP_SYS_RAWIO`, or `CAP_DAC_OVERRIDE` to make hardware work.
A future privilege addition requires explicit security review.

Generic locally attached edge needs no LAN/Internet access. `PrivateNetwork=yes`
or equivalent isolation is preferred where compatible. systemd documents that
private networking also affects host udev netlink delivery, so future
qualification must prove discovery/hotplug and inherited pathname-socket
operation while denying unintended networking; see
[upstream execution sandboxing](https://raw.githubusercontent.com/systemd/systemd/main/man/systemd.exec.xml).
A future Ethernet/network peripheral requires an explicit design review rather
than silently broadening this daemon. This target does not change POS Core's
existing host-loopback networking.

Fedora Kinoite qualification requires SELinux enforcing. Either existing
policy must work or a narrow Grocery POS edge policy must be packaged. Disabling
SELinux is not an integration method; Tier B must record enforcing state and
prove actual boundaries, not infer them from these proposed directives.

The cashier Flatpak must retain its narrow presentation grants and gain no raw
USB/input permissions or edge-socket filesystem exposure. Flatpak distinguishes
device exposure from presentation permissions; see
[upstream sandbox permissions](https://docs.flatpak.org/en/latest/sandbox-permissions.html).
These are future denial checks, not claims of hardware qualification.

## Deterministic simulation and later checkpoints

Every adapter interface must support a deterministic simulator implementation.
It goes through the real binding lifecycle, queue, cache, EffectTracker,
timeouts, event sequencing, and CoreActor; there is no special Core shortcut.
Future scenarios include connect/disconnect, barcode observations,
stable/unstable weight, paper-out, pre-effect failure, possible-effect crash,
success confirmation, adapter panic, timeout, and rebind.

Production configuration naming a simulated adapter must fail unless the daemon
is explicitly launched with simulation permission. Simulators must not activate
through device absence or an automatic fallback. Simulation evidence is Tier A,
never proof of a real device or appliance boundary.

M8.2 will implement and qualify the generic contract and client foundation;
later hardware checkpoints add command-specific schemas/adapters. M8.4 owns
durable print jobs and M8.6 may specialize scale certification. Tier A–D and
machine-readable future evidence are defined in the
[threat model](../security/edge-agent-threat-model.md). No acceptance ledger or
implementation evidence is created by M8.1.
