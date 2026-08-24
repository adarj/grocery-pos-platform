# Racket POS Core Runtime Composition

## Purpose

`pos-backend-racket/main.rkt` is the process composition root. Before the HTTP
listener starts, it constructs the durable transaction application boundary
and establishes explicit ownership for SQLite request connections.

The runtime composition is intentionally separate from transaction meaning:

```text
environment configuration
  -> startup SQLite operating policy + schema initialization
  -> bounded request connection pool
  -> thread-mapped virtual connection
  -> transaction + register-operations services
  -> HTTP application
```

The transaction domain remains pure, the transaction service continues to
coordinate command decisions, and the persistence modules continue to own
journal and receipt mechanics.

## Configuration

The process reads:

```text
RACKET_API_HOST
RACKET_API_PORT
SQLITE_DB_PATH
```

The default host is `127.0.0.1`, the default port is `7340`, and the default
database path is `.local/sqlite/pos-dev.db`. Host and database path must be
non-empty. The port must be an exact integer from 1 through 65535.

`main.rkt` resolves a relative database path against the repository root once
at startup. All later connections use that complete path, so request behavior
does not depend on a changed working directory. The configured parent
directory must already exist; runtime startup does not silently create an
arbitrary directory hierarchy for a mistyped storage path. The development
shell provisions the normal `.local/sqlite` directory.

## SQLite connection operating policy

All production runtime and administrative database connections are constructed
through `pos/persistence/sqlite-connection.rkt`. The shared constructor passes
Racket's `sqlite3-connect` an explicit busy retry limit of `10` and retry delay
of `0.1` seconds. It then returns a connection only after the required SQLite
policy has been established and verified.

The create-capable initialization connection establishes and verifies
`journal_mode=WAL`. Normal `read/write` connections only verify that the
database is already WAL; they fail closed instead of converting journal mode
during request or administrative work. Every production connection also
establishes and verifies:

```text
synchronous:       FULL (2)
foreign_keys:      ON (1)
wal_autocheckpoint: 1000 pages
```

If policy setup or verification fails after the underlying connection opens,
the constructor disconnects it before propagating the failure. This policy is
separate from schema migration history and adds no migration after v6. See
[ADR-0018](../adr/0018-use-wal-with-full-synchronous-durability.md).

## Startup schema lifecycle

The HTTP listener does not begin accepting requests until SQLite startup has
succeeded:

```text
open dedicated SQLite connection in create mode
  -> establish and verify WAL
  -> establish and verify per-connection durability policy
  -> run and validate POS database migrations through v6
  -> disconnect dedicated startup connection
  -> construct request-time database resources
  -> construct HTTP application
  -> start listener
```

The create-capable connection exists only for explicit startup migration. It
is disconnected on both successful migration and migration failure. Database
or migration failure propagates and prevents construction of a usable runtime;
the process does not start in a partially durable mode.

Request connections do not run migrations and open the initialized database in
SQLite `read/write` mode. Each physical pool connection verifies WAL and its
per-connection policy before use. If the initialized file disappears, request
handling fails instead of silently creating an empty replacement database.

## Request connection ownership

The runtime builds one Racket `connection-pool` with:

```text
maximum physical connections: 4
maximum idle connections:     4
idle lifetime:                300 seconds
```

One `virtual-connection` backed by that pool is passed to the transaction
service. A virtual connection maps each calling request thread to a distinct
actual pool lease and keeps that actual connection for the thread's database
work. When a servlet request thread terminates, its lease is released to the
pool. Consequently, unrelated request threads do not share one physical
SQLite transaction context even though they use one shared transaction-service
value.

The pool factory uses the same production connection constructor as startup,
but opens in `read/write` mode. The connector's bounded SQLITE_BUSY handling
does not add a process-global lock or retry a whole command or domain decision.
If contention remains after the connector exhausts its limit, the existing
persistence/error boundary reports the failure or uncertain outcome.

This runtime ownership model complements the command unit of work's
`BEGIN IMMEDIATE`, final command-ID check, and final stream-version check. It
does not change command semantics, introduce a process-global command lock, or
promise that SQLite writers never contend.

## Resource lifetime and shutdown

The pool, virtual connection, and physical connections are created under a
dedicated runtime custodian. `stop-pos-runtime!` shuts down that custodian and
is safe to call repeatedly. `main.rkt` wraps the servlet lifetime with
`dynamic-wind`, so normal or exceptional listener exit triggers runtime
shutdown.

The pool connector creates physical request connections under the same runtime
custodian. Shutting down the runtime therefore closes its database resources
rather than relying on a hidden global connection or process termination.

## Application, catalog, and register composition

The runtime passes the shared virtual connection and a SQLite catalog lookup to
`make-transaction-service`. New scans resolve active merchandise through the
persistent normalized catalog created by migration 3. The lookup uses the same
bounded pool/virtual connection and does not open one physical connection per
scan.

Runtime startup migrates but never seeds or activates catalog data. A fresh
database has an empty catalog until an operator explicitly activates a strict
full snapshot. Focused tests can still inject a catalog lookup override, but
the development fake is no longer a production default. Historical replay
continues to use sale-time event snapshots and never queries current catalog
data. See [Local Catalog](catalog.md).

The runtime also constructs `register-operations-service` over the same virtual
connection. Production composition injects a UTC epoch-millisecond clock and a
cryptographically random 128-bit `shift_` identifier generator. The same clock
is injected into transaction service planning so new operational start and
terminal events record one consistent POS-Core-owned time source. Replay never
calls it.

Runtime migration creates but does not populate register/cashier tables. New
transaction starts safely reject until an operator activates configuration and
opens a shift. Focused tests may inject deterministic clocks/IDs. See
[Register Operations and Shift Context](register-operations.md).

Migration v6 adds shift cash movements and reconciliation. Runtime uses the
same virtual connection for cash-summary reads, opening/close writes, and the
completion unit of work. It never auto-seeds an opening float or rewrites
drawer state at startup. See [Shift Cash Accountability](cash-accountability.md).

`make-app` requires the constructed transaction service and returns the servlet
handler. The service is captured explicitly rather than stored in a global.
Transaction routes delegate to that service through the transport-only adapter
documented in [Transaction HTTP API v1](transaction-http-api-v1.md).

## Current HTTP surface

The implemented routes are:

```text
GET /health
POST /transaction-commands
GET /transactions/{transaction_id}
GET /receipts/{transaction_id}
GET /register-context
GET /cashiers
POST /shifts/open
POST /shifts/{shift_id}/close
GET /shifts/{shift_id}/cash-summary
```

`GET /health` remains a liveness endpoint and does not perform a database or
peripheral readiness probe. Startup proves that the configured database could
be opened and migrated before the listener began; it does not imply that every
future checkout dependency is ready.

## Tested lifecycle

Focused file-backed tests establish:

- fresh initialization establishing WAL before migration and applying the
  exact per-connection durability policy;
- conversion of a compatible existing database to WAL without migration or
  transaction-history loss;
- normal `read/write` production opening rejecting a non-WAL database;
- policy failure disconnecting the newly opened connection;
- fresh runtime migration through schema v6;
- an empty persistent catalog rejecting the former development barcode rather
  than falling back to a fake;
- active/inactive/unknown persistent catalog lookup behavior and exact
  sale-time event values;
- idempotent startup against an existing v3 database without history loss;
- migration corruption preventing runtime construction;
- failure on a missing database parent directory;
- startup-connection cleanup on success and failure;
- correct command arbitration through one virtual connection from two request
  threads;
- runtime stop followed by restart, transaction recovery, and same-command-ID
  receipt recovery without duplicate events;
- read/write request connections refusing to recreate a missing database;
- unchanged `/health` and unknown-route behavior through `make-app`;
- operational configuration/shift composition, active-transaction slot
  persistence, atomic net cash-sale movement plus slot release on completion,
  and movement-free slot release on void.

## Deliberately deferred

This runtime composition and HTTP adapter do not add:

- a readiness endpoint;
- employee authentication, PINs/passwords, or authorization;
- catalog HTTP administration, patch updates, or cloud synchronization;
- application-level busy retry/backoff or whole-command retry;
- custom checkpoint scheduling, manual checkpoint tooling, or WAL metrics;
- backup, restore, corruption-recovery tooling, or integrity-check commands;
- a generic service container or component framework;
- external payment/device integration, physical cash-drawer control, or
  receipt-printer integration;
- exactly-once external-effect guarantees.

Future external effects still require persisted intent and explicit
unknown-outcome recovery; they must not be placed inside a long-lived SQLite
writer transaction.
