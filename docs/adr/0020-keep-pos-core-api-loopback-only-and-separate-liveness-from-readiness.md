# ADR-0020: Keep the POS Core API loopback-only and separate liveness from readiness

Status: Accepted

Date: 2026-09-03

## Context

The ordinary local POS API currently relies on loopback as its transport trust
boundary and has no network authentication or authorization layer. The
`RACKET_API_HOST` setting previously accepted any nonempty string, so a simple
configuration change could expose transaction and register operations on a LAN
or public interface without establishing a new security architecture.

`GET /health` reports cheap process/listener liveness. The Flutter real-process
fixture previously used that response as a proxy for operational startup even
though the authoritative SQLite database can become unavailable after the
listener starts. Racket's web server also provides native request and resource
safety limits, but the project had not frozen an explicit policy or body-size
boundary.

## Decision

Ordinary API configuration accepts only the literal loopback addresses
`127.0.0.1` and `::1`. It does not accept wildcard addresses, LAN/public
addresses, or the hostname `localhost`, and it does not resolve DNS names to
decide trust. There is no unauthenticated remote-listener mode.

The server uses one `make-safety-limits` value with these explicit overrides:

- maximum concurrent connections: 64;
- maximum waiting connections: 64;
- request-read timeout: 10 seconds;
- maximum request body: 64 KiB (65,536 bytes);
- response timeout: 30 seconds; and
- response-send timeout: 10 seconds.

Racket's safe defaults remain authoritative for request lines, headers,
multipart data, and safety fields not listed above. The shared value is passed
to `serve/servlet` with `#:safety-limits`, so oversized ordinary bodies are
rejected by the request reader before application handlers call
`request-post-data/raw`.

`GET /health` remains a persistence-free liveness probe. A separate
`GET /ready` endpoint reports whether the active runtime can currently
establish the production database contract. Readiness requires:

- a runtime that has not been stopped;
- the authoritative database path to name an existing regular file;
- a fresh Checkpoint 1 production connection in `read/write` mode;
- a successful lightweight SQLite query; and
- canonical migration history classified as exactly current at the supported
  schema version.

The fresh connection verifies WAL, `synchronous=FULL`, foreign-key enforcement,
the 1000-page WAL autocheckpoint setting, and the existing bounded Racket busy
policy. It is always closed after the probe. Readiness does not create a
database, establish WAL, run migrations, run full schema/application
validation, perform `quick_check` or `integrity_check`, validate a backup, or
attempt recovery.

A ready response is HTTP 200. A functioning listener whose runtime cannot
establish this boundary returns HTTP 503 with one sanitized stable reason:
`runtime_stopped`, `database_missing`, `database_unavailable`, or
`database_schema_not_current`. Raw paths, SQLite errors, SQL, exception details,
and business data are never included. Unsupported methods on both probes return
405 with `Allow: GET`.

Production application composition must supply a readiness probe explicitly.
The real-process Flutter fixture waits for `/ready` under its existing bounded
startup deadline while `/health` remains independently tested as liveness.

## Rationale

Loopback is the only trust boundary currently designed for the API. Rejecting
unsafe host values during configuration prevents accidental unauthenticated
network exposure before database initialization or listener creation.

Native server limits bound input and connection resources before application
decoding. Liveness and readiness answer different operational questions: a
process may answer HTTP while its authoritative persistence boundary is no
longer usable. A fresh production connection tests the contract normal POS work
depends on without creating or normalizing the database.

Whole-database integrity work is too expensive and too broad for every probe.
Checkpoint 2's explicit maintenance commands remain the mechanism for deeper
inspection and integrity certification.

## Consequences

### Positive

- Accidental wildcard, LAN, public, and hostname binding fails before runtime
  startup.
- Oversized request bodies are rejected before transaction command decoding or
  durable receipt/event handling.
- Clients and service supervisors can distinguish process liveness from local
  persistence readiness.
- Readiness failures expose stable automation-friendly categories without
  leaking SQLite or filesystem diagnostics.
- The real-process test harness proceeds only after POS Core can establish its
  production database contract.

### Negative

- Remote clients cannot use the ordinary API.
- Every readiness request opens and closes one production-policy SQLite
  connection.
- Readiness is intentionally weaker than whole-file integrity certification; a
  problem in an untouched database page may not be detected.
- A 503 readiness state requires operator or service remediation rather than
  automatic recovery.

## Rejected or deferred alternatives

### Wildcard, LAN, public, or DNS-name listeners

`0.0.0.0`, `::`, LAN/public addresses, and `localhost` are rejected. Resolving
names or adding a permissive environment flag would obscure the actual trust
boundary.

### Bolt a token onto the current listener for remote access

Rejected as insufficient justification for exposing transaction mutation.
Authenticated remote management requires its own authorization, transport,
audit, and threat-model decisions.

### Use `/health` for readiness

Rejected because a cheap process probe must remain useful even when persistence
is unavailable.

### Run full integrity checking per readiness request

Rejected because `integrity_check`, `quick_check`, and the deeper Grocery POS
schema/application validators are explicit maintenance or startup work, not
per-probe request work.

### Automatically recreate, migrate, repair, or restore the database

Rejected. Readiness observes failure and fails closed; it does not select a
recovery point or perform a financial-data mutation.

### Implement a custom HTTP parser or body limiter

Rejected because Racket's native safety limits enforce the boundary before the
servlet receives the request.

### Use unlimited Racket safety limits

Rejected because an unauthenticated local peer can still be faulty or hostile,
and the current API requires only small bounded JSON bodies.

## Deferred work

Authenticated remote access, TLS, service supervision, readiness integration
with systemd, appliance packaging, service-user/filesystem policy, restore and
recovery procedures, and broader load/power-loss qualification remain later
milestones or Milestone 6 checkpoints.
