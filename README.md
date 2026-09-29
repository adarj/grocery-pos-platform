# Grocery POS Platform

A **pre-production, local-first single-register grocery POS foundation** for
small-to-medium stores. The implemented checkout path is cash: durable sales,
replay, idempotent command recovery, shift/cash accountability, and local
operator security are in place, alongside Fedora Kinoite appliance foundations.

This is **not suitable for production retail use**. M7 repository/Tier A security
qualification passed, but booted appliance, physical kiosk, and abrupt-power
qualification remain pending. Physical device I/O, the Rust edge daemon,
card payments, refunds, inventory integration, and cloud synchronization are
not implemented.

## Architecture and principles

```text
Flutter presents.
Racket decides.
SQLite remembers.
Rust talks to edges.
The cloud coordinates.
```

Flutter renders authoritative state and collects input; it does not decide
totals, tax, authorization, payment validity, or transaction lifecycle. Racket
owns POS meaning and normal authoritative writes. SQLite stores durable facts,
not business rules; Rust's intended role is system/device/protocol edges, not
transaction authority.

Supabase and DigitalOcean are intended cloud coordination/auxiliary components,
not prerequisites for ordinary local checkout. Validate remote commands locally;
do not silently add external services to the checkout-critical path.

Use exact integer money, explicit state transitions, and typed idempotent
commands. Retry a logical command with its original command ID and expected
version. Transaction events are business truth; command receipts retain original
outcomes. **An unknown payment outcome must never trigger a blind charge retry.**

Accepted decisions and future architecture are in the
[ADR index](docs/adr/README.md); the implemented Flutter ↔ Racket boundary is in
the [local API contract](docs/architecture/local-api.md).

## Current implementation

### Core transaction and checkout

- Flutter cashier flow: start, scan, remove line, cash tender, complete,
  approval-controlled open-sale void, canonical receipt display, and explicit
  next sale.
- Racket's exact-money/tax domain, deterministic replay, strict command/event
  codecs, durable idempotency, and expected-version checks.
- Explicit local catalog/tax activation with sale-time snapshots; later reference
  changes do not reinterpret historical transactions.

See [transaction commands](docs/architecture/transaction-command-schema.md),
[journal/replay](docs/architecture/transaction-journal.md), and
[receipts](docs/architecture/receipts.md).

### Persistence and recovery

- Current SQLite schema v12; WAL/FULL durability, foreign keys, bounded busy
  handling, and request connection ownership.
- Accepted events and command outcomes commit atomically. Flutter persists exact,
  operator-bound pending intent in recovery files, not bearer/PIN capabilities.
- Validated live backups, explicit offline restore preserving displaced state,
  and privacy-minimized local support bundles. Restore selects a historical
  security/business recovery point; it never merges newer displaced rows.

See [runtime](docs/architecture/racket-runtime.md),
[maintenance/backup](docs/operations/database-maintenance.md),
[restore](docs/operations/database-restore.md), and
[support diagnostics](docs/operations/support-diagnostics.md).

### Register, shift, and cash accountability

- Explicit register/cashier configuration, operator-owned shifts, and one active
  transaction slot.
- Append-only opening/completed-sale cash movements and immutable close
  reconciliation.
- Server-derived shift identity, manager-authorized foreign close, and
  blind-count-safe cashier summaries.

See [register operations](docs/architecture/register-operations.md) and
[cash accountability](docs/architecture/cash-accountability.md).

### Authentication and security

- Local operator identities, fixed cashier/supervisor/manager permissions,
  Argon2id PIN credentials, durable login throttling, and process-local bounded
  register sessions.
- Server-side ownership enforcement, durable command actor/approver evidence,
  and separately authenticated Supervisor / Manager Approval for fresh whole-sale
  voids. A requester cannot self-approve; approval does not switch the cashier.
- Separate hash-chained local security audit history with root-only inspection.
- Authenticated PIN change, explicit root recovery reset, credential revisions,
  grant revocation, and final-writer stale-credential rejection.
- Flutter starts locked and retains unresolved transaction recovery through
  reauthentication. No default manager, hidden credential, or master PIN exists.

See [security documentation](docs/security/) and M7 ADRs 0027–0032 in the ADR index.

### Appliance and operations

- Internal Fedora Core/appliance RPMs, loopback-only API, separate backend/kiosk
  Unix identities, and a source-pinned system Flatpak terminal.
- Fedora Kinoite 44 x86_64 provisioning/recovery foundations, windowed development
  and explicit fullscreen kiosk mode, and root-only auth-readiness diagnostics.

See [appliance operations](docs/operations/kinoite-appliance.md) and
[provisioning](docs/operations/appliance-provisioning.md). Built artifacts and
rootless package tests do not establish deployed appliance behavior.

### Rust edge protocol foundation

The Rust 2024 [edge workspace](rust/edge/Cargo.toml) now contains the
dependency-minimal `edge-protocol` library: distinct opaque IDs, exact time and
sequence domains, device snapshots, generic typed command submissions, semantic
command equality, lifecycle/outcome/effect evidence, safe errors, and generic
event values. Ordinary Serde tests protect the wire vocabulary. This implements
the M8.2.1 type foundation under [ADR-0033](docs/adr/0033-use-a-semantic-local-edge-protocol-for-pos-hardware.md).

The daemon, CoreActor, command cache/executors, simulator, real adapters, Racket
client, Linux deployment, and physical hardware I/O remain unimplemented.
M8.2.2 owns the strict untrusted-JSON codec, including duplicate-key rejection
and bounded decoding; these Serde tests do not establish M8 Tier A qualification.

### Testing and qualification

Racket, Flutter unit/widget, and isolated real-process integration tests protect
the checkout/security/recovery boundaries. Rust tests protect the edge protocol
type foundation. CI checks source, repository, and artifact contracts.
[M6 reliability](docs/acceptance/m6/README.md) and
[M7 security](docs/acceptance/m7/README.md) have separate evidence records.

M7's committed record has passing Tier A evidence, including x86_64 artifact
contracts, but its overall status remains **conditional**: booted Kinoite
(Tier B), physical kiosk (Tier C), and physical interruption (Tier D) have not
run. Repository-green or emulated/process-crash evidence is not physical
production qualification. Do not regenerate historical evidence for unrelated
developer-surface changes.

### Deferred major capabilities

Card/payment-terminal integration, refunds, promotions, inventory integration,
customer-display workflows, Rust hardware agents, cloud synchronization and
remote management remain separately scoped future work. The Rust protocol
library and development tools do not establish implemented hardware agents or
cloud infrastructure. There is no canonical cloud start/stop/plan workflow.

## Development environment

The repository-owned contract is a Linux development environment using the
pinned Nix flake toolchain. No particular editor, hypervisor, laptop, container
runtime, or host architecture is mandatory; target-specific artifact execution
still requires a capable builder.

```text
Linux development environment
  → Nix flake / optional direnv activation
      ├─ Racket
      ├─ Flutter / Dart
      ├─ Rust toolchain
      ├─ SQLite
      ├─ Supabase CLI
      ├─ OpenTofu
      └─ project utilities and language tooling
  → just: canonical project command interface
```

From the repository root, allow the checked-in direnv configuration:

```bash
direnv allow
```

Alternatively enter the same toolchain explicitly:

```bash
nix develop
```

The development shell prepares ignored local state and exports the development
database/listener settings. Optional `.env.local` configuration must stay
uncommitted. Inspect available commands and check the substrate with:

```bash
just --list
just doctor
```

Any editor can use that activated environment. The checked-in VS Code tasks
expose a small set of operational `just` recipes, not a separate command policy.

The [Flutter Linux VM notes](docs/development/flutter-linux-vm-notes.md)
describe one tested Apple Silicon/VMware/Fedora/Distrobox environment and its
nixGL workaround. That setup is not mandatory for other contributors.

## Running the local POS development stack

Use two terminals in the project development environment.

### Prepare development reference data and operator credentials

For a fresh development database, validate and activate the version-controlled
catalog and register/cashier fixtures:

```bash
just catalog-validate pos-backend-racket/fixtures/development/catalog-snapshot-v2.json
just catalog-activate pos-backend-racket/fixtures/development/catalog-snapshot-v2.json .local/sqlite/pos-dev.db
just register-config-validate fixtures/development/register-configuration-v1.json
just register-config-activate fixtures/development/register-configuration-v1.json .local/sqlite/pos-dev.db
```

Activation replaces current reference data in the explicitly selected database.
The development shell prepares its parent directory; other parents must already
exist. Runtime startup never implicitly seeds reference data or credentials.

Configuration activation can create same-ID cashier operator stubs, but no PINs.
Before the terminal can unlock, a usable active operator must be explicitly
enrolled; register operations require same-ID active cashier configuration.
Fresh whole-sale voids require a different approval-capable supervisor/manager.

See [operator identity/bootstrap](docs/security/operator-identity-and-pin-credentials.md)
and [credential lifecycle](docs/security/credential-lifecycle-and-recovery.md).
The packaged root bootstrap tool targets the installed appliance's canonical
database, not the development database above. Real-process integration fixtures
separately establish isolated synthetic credentials; never use store credentials
as development fixtures.

### Terminal 1 — POS Core

```bash
just run-racket
```

The development listener is `http://127.0.0.1:7340`. Check liveness and
persistence readiness separately:

```bash
curl http://127.0.0.1:7340/health
curl http://127.0.0.1:7340/ready
```

`/health` is process liveness. `/ready` verifies the lightweight current
SQLite/runtime contract, not staffing, credential bootstrap, or full database
integrity. Ordinary listener configuration permits only literal `127.0.0.1`
or `::1`, with no remote-listener mode.

### Terminal 2 — Flutter POS terminal

Use the ordinary Linux launcher when graphics work normally:

```bash
just run-pos-plain
```

In environments requiring the documented nixGL graphics bridge:

```bash
just run-pos
```

Both launch the same terminal. The nixGL variant remains the existing
VM-specific workaround; it is not a universal requirement. The terminal starts
locked and requires operator authentication before protected checkout navigation.

## Validation and package development

Use the narrowest relevant existing recipe:

| Command | Purpose |
| --- | --- |
| `just test-racket` | Backend tests |
| `just test-flutter` | Flutter unit/widget tests |
| `just test-pos-integration` | Isolated Flutter ↔ Racket ↔ SQLite process tests |
| `just analyze-flutter` | Flutter analysis |
| `just fmt-rust` | Format the Rust workspace |
| `just check-rust-format` | Verify Rust formatting |
| `just clippy-rust` | Locked workspace Clippy, with warnings denied |
| `just test-rust` | Locked Rust workspace tests |
| `just check-rust` | Rust formatting check, Clippy, and tests |
| `just test` | Racket, Flutter, and Rust tests, without real-process integration |
| `just check` | Flutter analysis, Rust format/Clippy, all three test suites, and real-process integration |

The integration suite starts/owns its backend and temporary state; no separately
started server or cloud service is needed. See the
[integration guide](docs/development/integration-testing.md).
Acceptance commands have qualification/evidence semantics and are not routine
extra validation for small edits.

Build and inspect native host packages without installing them:

```bash
just build-pos-core-rpm
just build-pos-appliance-rpm
just check-pos-core-package
just check-pos-appliance
```

The x86_64 terminal/bundle targets require a capable build environment:

```bash
just build-pos-terminal-flatpak
just build-appliance-bundle
```

These commands do not provision a register or mutate the host deployment.
See the [Core service contract](docs/operations/pos-core-service.md) and appliance
runbooks. `just --list` is the live command inventory; no aggregate multi-language
formatter or cloud orchestration recipe exists.

## Repository and deeper guidance

Production application code lives under `pos-backend-racket/` and
`flutter/apps/pos_terminal/`, with Rust protocol source under `rust/edge/`;
`packaging/` contains appliance delivery and
`scripts/` contains developer/qualification helpers.

- [ADRs](docs/adr/README.md): accepted architecture and rationale.
- [Architecture contracts](docs/architecture/): domain, persistence, and API truth.
- [Security](docs/security/): identity, sessions, ownership, approval, audit, and recovery.
- [Operations](docs/operations/): appliance, database, backup/restore, and support.
- [Development notes](docs/development/): environment-specific guidance and integration.
- [Agent constitution](AGENTS.md) and [Codex workflow](docs/development/codex-workflow.md):
  focused scope, learning-first collaboration, context routing, and proportional validation.

Use TDD where practical, small reviewable changes, ADRs for consequential choices,
and signed Conventional Commits after human review. Generated local state,
credentials, secrets, databases, and support archives must not be committed.
