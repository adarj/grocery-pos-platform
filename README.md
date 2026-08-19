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
transaction state. Persistence for the other listed concerns remains future
work.

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
* `GET /health` local API endpoint;
* RackUnit backend tests;
* exact-money, immutable cash-sale transaction domain behavior;
* transaction domain events and deterministic replay;
* strict, language-independent Transaction Event Schema v1 JSON;
* strict, language-independent Transaction Command Schema v1 with typed logical
  request identity and caller-supplied expected stream versions;
* append-only SQLite transaction journal with migration v1, per-stream
  sequencing, atomic batch append, and optimistic stream-version checks;
* migration v2 durable command receipts with database-global command IDs and
  atomic accepted-event/command-outcome persistence;
* idempotent persistent transaction application service with deterministic
  two-connection concurrency and file-backed restart/retry coverage;
* Racket runtime composition with startup migration, a bounded SQLite pool,
  thread-mapped virtual request connections, and explicit shutdown ownership;
* Transaction HTTP API v1 with one strict idempotent command route and one
  authoritative transaction-state query route;
* Flutter Linux ARM64 POS terminal;
* typed Flutter POS Core client models for transaction commands, durable command
  outcomes, authoritative transaction snapshots, and safe failures;
* Flutter widget tests;
* Flutter-to-Racket local health connection;
* nixGL-based Flutter GUI launch in the current VM environment;
* GitHub Actions workflow definitions for scaffold/Nix validation, Racket
  tests, and Flutter analysis/tests;
* Architecture Decision Records under `docs/adr/`.

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

Run Flutter static analysis:

```bash
just analyze-flutter
```

Run the combined project test suite:

```bash
just test
```

Run the complete local quality gate, including Flutter static analysis and both test suites:

```bash
just check
```

The canonical development command surface is the repository `justfile`; prefer adding reusable commands there rather than relying on undocumented shell invocations.

## Repository Layout

```text
.
├── docs/
│   ├── adr/
│   ├── architecture/
│   └── development/
├── flutter/
│   └── apps/
│       └── pos_terminal/
├── pos-backend-racket/
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

This transaction workflow is now exposed through the narrow Transaction HTTP
API v1 command and query routes. A full Flutter checkout interface remains a
separately scoped and tested future milestone.

## Status

This repository is under active development and is **not suitable for production retail use**.
