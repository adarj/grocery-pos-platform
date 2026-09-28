# ADR-0033: Use a semantic local edge protocol for POS hardware

Status: Accepted

Date: 2026-09-28

## Context

[ADR-0005](0005-use-rust-for-system-edge-agents.md) chooses Rust for system
edges and requires that agents never become a second transaction authority.
Milestone 8 now needs a concrete device contract for scanners, receipt
printers, drawers, and scales. Direct Flutter hardware access or raw-device
tunneling would bypass Racket's business decisions and security policy.

Physical effects have ambiguous failure semantics: a lost response, disconnect,
or crash does not prove that printing or a drawer pulse did not happen.
[ADR-0011](0011-use-durable-command-receipts-and-expected-stream-versions.md)
already distinguishes durable business-command idempotency from external
effects. Hardware must preserve that distinction rather than participate in a
SQLite writer transaction or claim exactly-once physical execution.

## Decision

M8 v1 will use one supervised lane-local Rust daemon, `grocery-pos-edge`, with
independent internal adapters and resource executors. Only Racket POS Core may
call its production API; Flutter has presentation authority and no direct edge
or raw peripheral authority.

The versioned semantic Edge Protocol uses HTTP/1.1 and UTF-8 JSON over a private
pathname `AF_UNIX SOCK_STREAM` socket. There is no production TCP listener,
browser CORS surface, bearer-token requirement, or TLS requirement on this
channel. The deployment target combines socket/filesystem DAC, expected Racket
UID verification through Linux peer credentials, and SELinux. systemd will own
the listener; device access will also require narrow udev permissions and
device-cgroup restrictions under a separate edge service identity.

Commands name a semantic capability, logical device, agent epoch, binding
epoch, stable command ID, and monotonic submission deadline. A command record
must exist before its physical effect can begin. Same-ID transport retries
return existing state; changed semantics conflict. Compact command identity
remains for the agent epoch; payloads need not. Outcomes distinguish known
failure from `unknown`, and effect evidence guides Racket's retry decision.
Rust does not decide business retry policy or automatically repeat uncertain
discrete effects.

Privileged, restart-only configuration binds each logical slot through one
deterministic selector. Discovery is not authorization; ambiguous matches fail
closed. Published capabilities are the intersection of configuration,
adapter, and hardware. There is no generic raw/vendor command escape hatch or
runtime-loaded adapter plugin.

Edge queues, caches, bindings, device state, and events are bounded and
ephemeral. Edge owns no SQLite database, receipt business store, or financial
history. Racket/SQLite retain business authority, including canonical receipts,
cash facts, authorization, and durable recovery intent. Printers cannot commit
or roll back sales. Generic Edge Protocol v1 excludes card-payment execution;
payment terminals require a future specialized financial architecture.

Qualification will distinguish deterministic repository behavior (Tier A),
Linux appliance security (Tier B), selected physical devices (Tier C), and an
integrated lane (Tier D). Simulation must use the real internal paths and must
require explicit permission outside production operation.

## Relationship to ADR-0005

ADR-0005 remains accepted. This decision specializes and operationalizes its
hardware boundary; it does not replace its broader choice of Rust for system
edges. Its mention of payment terminals does not make this generic protocol a
payment abstraction. A normal second-monitor customer display remains a
presentation projection; a legacy serial pole display may need an edge adapter.

## Consequences

### Positive

- One stable Racket-to-Rust contract centralizes command identity, ordering,
  resource bounds, and physical-device security policy.
- Epoch checks, record-before-effect, freshness, and explicit uncertainty
  prevent stale or transport-retried commands from silently repeating effects.
- Device replacement and availability remain separate from business truth.
- Deterministic simulation supports ordinary CI without claiming hardware
  qualification; tiered evidence keeps deployment claims honest.

### Negative

- Linux identity, socket, sandbox, and hotplug behavior need real appliance
  qualification in addition to protocol tests.
- Bounded ephemeral records constrain recovery; restart can leave physical
  outcomes unresolved, requiring Racket-owned recovery and human decisions.
- Preserving ID conflicts throughout an epoch consumes bounded cache capacity;
  admission stops when evidence cannot be retained, so sizing needs qualification.
- A shared daemon makes Core failure a lane-wide edge restart. Future hardware
  may justify out-of-process adapter isolation through a separate decision.
- Semantic adapters and command-specific success criteria cost more design work
  than passing arbitrary hardware bytes through the API.

## Specification and implementation boundary

[Edge-agent architecture](../architecture/edge-agent.md),
[Edge Protocol v1](../architecture/edge-protocol-v1.md), and the
[edge threat model and acceptance contract](../security/edge-agent-threat-model.md)
define the detailed requirements. M8.1 records architecture only. Rust code,
client code, packaging, Linux policy, dependencies, and qualification evidence
are future checkpoint work.
