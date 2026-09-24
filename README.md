# Grocery POS Platform

A local-first retail point-of-sale platform for small-to-medium grocery stores.

The project is an early-stage implementation of a grocery POS system designed around reliable local checkout, explicit transaction state, test-driven development, hardware interoperability, and a cloud control plane that coordinates without becoming a hard dependency for ordinary register operation.

The project is currently in the **walking-skeleton / early domain-development phase**. It is not production-ready.

## Project Goals

The platform is being designed to provide:

* fast and reliable grocery checkout;
* local-first operation during internet or cloud outages;
* durable transaction, payment, receipt, and drawer state;
* cashier-facing touchscreen and customer-facing display workflows;
* interoperability with existing grocery inventory systems;
* clean manager, technician, and support workflows;
* test-driven development and explicit domain invariants;
* reproducible development and deployment tooling;
* infrastructure-as-code and GitOps-based change management;
* controlled software updates and support tooling;
* strong security boundaries around payments, authorization, remote operations, and sensitive data.

## Architecture

```text
Fedora Kinoite POS Terminal
  ├── Flutter Cashier UI
  ├── Flutter Customer Display
  ├── Racket POS Core
  ├── SQLite Local Store
  ├── Rust System/Device Agents
  ├── Supabase Sync/Control-Plane Integration
  └── KDE/Kinoite Appliance Layer

Cloud Platform
  ├── Supabase
  │   ├── PostgreSQL
  │   ├── Auth
  │   ├── RLS policies
  │   ├── register health snapshots
  │   ├── remote command coordination
  │   └── reporting/control-plane data
  │
  └── DigitalOcean
      ├── support services
      ├── update artifact distribution
      ├── support bundle storage
      └── auxiliary platform services
```

### Responsibility Boundaries

| Component            | Primary responsibility                                            |
| -------------------- | ----------------------------------------------------------------- |
| Flutter              | Human-facing applications and presentation                        |
| Racket               | POS domain semantics, transaction state, rules, and orchestration |
| SQLite               | Durable local register state and recovery data                    |
| Rust                 | Hardware, protocol, system, update, and support edges             |
| Supabase             | Primary cloud database and control plane                          |
| DigitalOcean         | Auxiliary cloud services and artifact infrastructure              |
| Fedora Kinoite / KDE | Atomic POS appliance substrate                                    |

The central design rule is:

```text
Flutter presents.
Racket decides.
SQLite remembers.
Rust talks to edges.
The cloud coordinates.
```

## Core Principles

### Local-First Checkout

Normal checkout must not require Supabase, DigitalOcean, or another cloud service to be reachable.

Cloud outages may reduce synchronization, reporting, management, or support capabilities, but should not prevent local checkout when the required local hardware and payment path remain available.

### Racket Owns POS Meaning

Flutter clients may request actions and render the resulting state, but they are not authoritative for:

* transaction totals;
* tax calculations;
* promotion eligibility;
* payment completion;
* refunds;
* manager authorization;
* receipt truth;
* transaction-state transitions.

Those decisions belong to the local Racket POS Core.

### Durable Explicit State

Transaction, tender, payment, receipt, drawer, synchronization, and recovery state should be represented explicitly rather than inferred from UI state.

For the implemented cash-sale slice, SQLite is now the durable local journal
of accepted transaction facts, and Racket replay reconstructs authoritative
transaction state and canonical completed-sale receipts. A second materialized
receipt store is not required. SQLite also persists cashier command recovery,
shift cash movements, and immutable drawer reconciliation. Card-payment,
synchronization, and external-device recovery remain future work.

### Specialized Rust Edges

Rust is intended for components where low-level system integration, protocol handling, concurrency, hardware access, or robust native binaries provide clear value.

Rust agents must not independently become authorities over transaction truth.

## Current Implementation Status

The initial development environment and walking skeleton are operational.

Verified capabilities currently include:

* Fedora Kinoite development VM on Apple Silicon through VMware Fusion;
* a Fedora-based `dev` Distrobox development environment;
* native VSCodium inside the `dev` Distrobox as the primary editor;
* Nix flakes with `direnv` / `nix-direnv`;
* `just` as the canonical development command interface;
* Racket POS Core process;
* separate `GET /health` process liveness and `GET /ready` authoritative
  SQLite readiness endpoints;
* strict literal-loopback API binding and native bounded HTTP request/resource
  safety limits, including a 64 KiB request-body ceiling;
* RackUnit backend tests;
* exact-money, immutable cash-sale transaction domain behavior;
* transaction domain events and deterministic replay;
* strict, language-independent Transaction Event Schema v1/v2 JSON with
  backward-compatible untaxed history and exact sale-time line-tax snapshots;
* strict, language-independent Transaction Command Schema v1 with typed logical
  request identity, caller-supplied expected stream versions, and append-only
  open-sale remove/void corrections;
* append-only SQLite transaction journal with migration v1, per-stream
  sequencing, atomic batch append, and optimistic stream-version checks;
* migration v2 durable command receipts with database-global command IDs and
  atomic accepted-event/command-outcome persistence;
* migration v3/v4 persistent local catalog and tax-reference tables with strict
  Catalog Snapshot v1/v2 validation, atomic full replacement, SQLite runtime
  checkout lookup, and sale-time price/tax snapshot isolation;
* migration v5 current register/cashier configuration and durable shifts with
  one active-transaction slot, POS-Core-recorded epoch-millisecond times, and
  historical identity snapshotting;
* migration v6 append-only opening/completed-sale cash movements and immutable
  shift close reconciliation with exact signed over/short;
* migration v7 local operator principals, fixed cashier/supervisor/manager
  roles, same-ID cashier compatibility, and optional Argon2id PIN credentials
  with no default identities or credentials;
* root-only packaged operator bootstrap administration with no-echo PIN entry,
  a fixed canonical database target, and no HTTP enrollment escape hatch;
* schema v12 credential-revision-bound void grants, authenticated Change PIN,
  interactive root PIN reset, final-writer stale-credential rejection, and
  root-only appliance authentication-readiness reporting;
* migration v8 durable per-known-operator login throttling, process-local
  single-register bearer sessions, five-minute idle/twelve-hour absolute
  expiry, credential-revision binding, and generic anti-enumeration failures;
* authenticated local business routes plus a Flutter register lock with
  memory-only bearer state, manual/inactivity locking, and exact-command
  recovery preserved across reauthentication and POS Core restart;
* migration v9 atomic transaction-command actor attribution plus fixed,
  deny-by-default cashier/supervisor/manager permissions and durable
  transaction/shift ownership enforcement;
* server-derived shift identity, manager-only close-any, blind-count-safe open
  cash summaries, and operator-bound Flutter transaction recovery;
* idempotent persistent transaction application service with deterministic
  two-connection concurrency and file-backed restart/retry coverage;
* explicit SQLite WAL/FULL connection policy with foreign-key enforcement,
  bounded connector busy handling, a bounded SQLite pool, thread-mapped virtual
  request connections, and explicit shutdown ownership;
* read-only SQLite inspection and migration/schema reporting, explicit quick
  and full integrity checks, and validated live `VACUUM INTO` backups with
  same-directory partial staging and atomic non-overwriting publication;
* an internal noarch Fedora RPM for POS Core source, systemd/sysusers policy,
  isolated persistent state, rootless package inspection, and extracted-package
  SIGTERM/restart durability testing without an appliance Nix dependency;
* explicit double-validated offline database restore with displaced
  DB/WAL/SHM/journal evidence preservation, plus privacy-minimized local support
  bundles built from allowlisted operational metadata;
* a Fedora Kinoite 44 x86_64 appliance contract with transactional local-RPM
  bootstrap, resumable first provisioning, separate backend/kiosk identities,
  Plasma Login Manager lifecycle, and a source-pinned system Flatpak terminal;
* an evidence-tiered Milestone 6 reliability acceptance framework with
  deterministic repository qualification and explicitly pending booted,
  hardware, and destructive-power campaigns;
* Transaction HTTP API v1 with one strict idempotent command route,
  authoritative transaction-state reads, and exact completed-sale canonical
  receipt lookup derived from journal replay, plus narrow register/shift
  operations;
* Flutter Linux POS terminal with ordinary windowed development and explicit
  fullscreen kiosk mode;
* typed Flutter POS Core client models for transaction commands, durable command
  outcomes, authoritative transaction snapshots, Receipt Schemas v1/v2,
  register/shift context, authoritative shift cash summaries, and safe failures;
* Flutter cashier session orchestration and a
  start/scan/remove/void/cash-tender/complete interface rendering authoritative
  basket, subtotal, tax, total, payment, and change;
* Flutter widget tests;
* isolated Flutter-to-Racket real-process integration tests covering complete
  cash sales, restart recovery, uncertain transport, durable same-command
  receipt resolution, net drawer movements, shift reconciliation, and mixed
  one-shift endurance;
* Flutter-to-Racket public health/readiness plus local operator authentication;
* nixGL-based Flutter GUI launch in the current VM environment;
* GitHub Actions workflow definitions for scaffold/Nix validation, Racket
  tests, and Flutter analysis/tests;
* Architecture Decision Records under `docs/adr/`.

Milestone 6 acceptance evidence and the current deliberately conservative
status are documented under [`docs/acceptance/m6`](docs/acceptance/m6/README.md).
Repository-side green tests do not by themselves qualify a booted appliance or
physical power-loss behavior.

## Development Environment

The current primary environment is:

```text
Apple Silicon host
  ↓
VMware Fusion
  ↓
Fedora Kinoite aarch64 VM
  ↓
Distrobox: dev
  ├── Native VSCodium
  │   └── project extensions / language servers
  └── Nix flake development environment
      ├── Racket
      ├── Flutter / Dart
      ├── Rust
      ├── SQLite
      ├── Supabase CLI
      ├── OpenTofu
      └── nixd
```

VSCodium, its project extensions, the integrated terminal, and Codex run in
the same `dev` Distrobox and observe the project toolchain activated by
Nix/direnv.

Enter the project normally through the native VSCodium terminal or:

```bash
cd ~/Projects/grocery-pos-platform
direnv allow
```

Run the environment preflight check with:

```bash
just doctor
```

## Running the Walking Skeleton

Use two terminals.

### Prepare development reference data

For a fresh development database, validate and atomically activate the small
version-controlled catalog fixture first:

```bash
just catalog-validate pos-backend-racket/fixtures/development/catalog-snapshot-v2.json
just catalog-activate pos-backend-racket/fixtures/development/catalog-snapshot-v2.json .local/sqlite/pos-dev.db
```

Activation replaces the complete current catalog in the explicitly selected
database. The development shell provisions `.local/sqlite`; other database
parents must already exist. POS Core startup never seeds or rewrites catalog
data automatically.

Also validate and activate the development register/cashier attribution
fixture into the same explicit database:

```bash
just register-config-validate fixtures/development/register-configuration-v1.json
just register-config-activate fixtures/development/register-configuration-v1.json .local/sqlite/pos-dev.db
```

POS Core does not auto-seed identities or credentials. Before the Checkpoint 2
terminal can unlock, an administrator must explicitly create/enroll at least
one active operator through the root-only appliance bootstrap tool described in
[Operator Identity and PIN Credentials](docs/security/operator-identity-and-pin-credentials.md).
Cashier selection and shift attribution remain distinct from authentication;
the authenticated operator now supplies shift identity, while Racket enforces
the fixed role and resource-ownership policy documented in
[Authorization and Ownership](docs/security/authorization-and-ownership.md).
Fresh whole-sale voids now require a different supervisor/manager's local PIN
approval, scoped to the exact command without replacing the cashier's register
session. See [Supervisor / Manager Approval](docs/security/scoped-manager-approval.md).
Security-sensitive local activity now has a separate hash-chained audit ledger,
inspectable through a root-only CLI and validated with database backups; it is
not transaction replay input or a Flutter/HTTP audit feed. See
[Local Security Audit Ledger](docs/security/security-audit-ledger.md).

### Terminal 1 — POS Core

Start the Racket backend:

```bash
just run-racket
```

The development server listens on:

```text
http://127.0.0.1:7340
```

The current health endpoint is:

```text
GET http://127.0.0.1:7340/health
```

It can also be tested manually:

```bash
curl http://127.0.0.1:7340/health
```

A healthy development response currently resembles:

```json
{
  "environment": "dev",
  "ok": true,
  "service": "grocery-pos-core",
  "version": "0.0.0-dev"
}
```

Operational readiness is separate:

```text
GET http://127.0.0.1:7340/ready
```

`/ready` returns 200 only while POS Core can establish its current production
SQLite contract; a live process returns a sanitized 503 state when that
boundary is unavailable. The ordinary API accepts only literal `127.0.0.1` or
`::1` listener configuration and does not support remote access.

### Terminal 2 — Flutter POS Terminal

In the current Fedora Kinoite / VMware / Distrobox / Nix environment:

```bash
just run-pos
```

This launches Flutter through nixGL to provide the graphics-driver bridge required by the development VM.

On systems that do not require that workaround:

```bash
just run-pos-plain
```

When the backend is healthy, the Flutter application should report:

```text
POS Core Connected
```

If the backend becomes unavailable and the client retries, it should report:

```text
POS Core Unavailable
```

## Testing

Run backend tests:

```bash
just test-racket
```

Run Flutter tests:

```bash
just test-flutter
```

Run the isolated real POS Core integration suite (it starts and owns the Racket
process automatically):

```bash
just test-pos-integration
```

Run Flutter static analysis:

```bash
just analyze-flutter
```

Run the combined project test suite:

```bash
just test
```

Run the complete local quality gate, including Flutter static analysis, the
fast Racket/Flutter suites, and the real-process POS integration suite:

```bash
just check
```

Canonical database inspection, integrity-check, and live-backup commands are
documented in [Local POS Database Maintenance](docs/operations/database-maintenance.md).
Explicit recovery is documented in the
[Offline POS Database Restore](docs/operations/database-restore.md) runbook;
automatic backup selection/fallback remains intentionally absent. See
[POS Support Diagnostics](docs/operations/support-diagnostics.md) for the local,
non-uploading diagnostic bundle contract.

On Linux, build and validate the internal Fedora POS Core artifact with:

```bash
just build-pos-core-rpm
just check-pos-core-package
```

These rootless commands do not install, enable, or start the package. See
[POS Core Fedora Service](docs/operations/pos-core-service.md) for its
filesystem/service contract. The x86_64 appliance artifacts are exposed through:

```bash
just build-pos-appliance-rpm
just build-pos-terminal-flatpak
just build-appliance-bundle
just check-pos-appliance
```

See [Fedora Kinoite Grocery POS Appliance](docs/operations/kinoite-appliance.md)
and [Appliance Provisioning](docs/operations/appliance-provisioning.md). These
commands build/test artifacts rootlessly; they do not mutate the developer's
host deployment or provision a register.

The canonical development command surface is the repository `justfile`; prefer adding reusable commands there rather than relying on undocumented shell invocations.

## Repository Layout

```text
.
├── docs/
│   ├── adr/
│   ├── architecture/
│   ├── development/
│   └── operations/
├── flutter/
│   └── apps/
│       └── pos_terminal/
├── pos-backend-racket/
├── packaging/
│   ├── fedora/
│   └── tests/
├── scripts/
│   └── dev/
├── .github/
│   └── workflows/
├── flake.nix
├── flake.lock
├── justfile
└── README.md
```

Some directories describe the intended project organization and will grow as their corresponding subsystems are implemented.

## Documentation

Architecture decisions are recorded under:

```text
docs/adr/
```

Development-environment notes are stored under:

```text
docs/development/
```

Architecture and interface contracts are stored under:

```text
docs/architecture/
```

Operational procedures are stored under:

```text
docs/operations/
```

Documentation should evolve in the same change as the behavior or architectural decision it describes.

## Development Practices

The project follows:

* test-driven development where practical;
* small, independently testable changes;
* Conventional Commits;
* signed Git commits;
* architecture decision records for consequential choices;
* reproducible development environments;
* explicit security and recovery invariants;
* Git-based review and CI before changes become production candidates.

Generated local state, credentials, secrets, databases, support bundles, and other environment-specific data must not be committed.

## Implemented Transaction Milestones

The first cash-sale vertical slice now includes the pure in-memory Racket
transaction domain and its durable local transaction journal. Accepted live
commands emit domain events, SQLite stores those events in ordered per-
transaction streams, and deterministic replay recovers state after a process
or connection restart.

Mutations now enter through strict typed commands carrying durable command
identity and caller-observed stream versions. SQLite command receipts preserve
the original deterministic outcome across retries, while accepted events remain
the authoritative transaction facts. Concurrent and lost-response tests prove
that retrying the same command cannot duplicate the current cash-sale facts.

This transaction workflow is exposed through the narrow Transaction HTTP API
v1 command and query routes. Flutter now implements the current cash-sale
cashier slice through authoritative completion or pre-payment void, persists
exact pending command identity before mutation POSTs for process-restart
recovery, and starts the next sale only through an explicit terminal-session
action. Corrections append durable facts; Flutter never deletes a basket row or
marks a sale voided optimistically. Post-payment refund/reversal and broader
production checkout capabilities remain separately scoped work.

## Status

This repository is under active development and is **not suitable for production retail use**.
