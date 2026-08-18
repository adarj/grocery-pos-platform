# Racket POS Core Runtime Composition

## Purpose

`pos-backend-racket/main.rkt` is the process composition root. Before the HTTP
listener starts, it constructs the durable transaction application boundary
and establishes explicit ownership for SQLite request connections.

The runtime composition is intentionally separate from transaction meaning:

```text
environment configuration
  -> startup schema initialization
  -> bounded request connection pool
  -> thread-mapped virtual connection
  -> transaction service
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

## Startup schema lifecycle

The HTTP listener does not begin accepting requests until SQLite startup has
succeeded:

```text
open dedicated SQLite connection in create mode
  -> run and validate transaction-journal migrations through v2
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
SQLite `read/write` mode. If the initialized file disappears, request handling
fails instead of silently creating an empty replacement database.

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

## Application and catalog composition

The runtime passes the shared virtual connection and the current catalog lookup
to `make-transaction-service`. The only implemented catalog is presently the
development `fake-catalog-lookup`; a durable catalog subsystem remains future
work. Historical replay still uses sale-time event snapshots and never queries
that catalog.

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
```

`GET /health` remains a liveness endpoint and does not perform a database or
peripheral readiness probe. Startup proves that the configured database could
be opened and migrated before the listener began; it does not imply that every
future checkout dependency is ready.

## Tested lifecycle

Focused file-backed tests establish:

- fresh runtime migration through schema v2;
- idempotent startup against an existing v2 database without history loss;
- migration corruption preventing runtime construction;
- failure on a missing database parent directory;
- startup-connection cleanup on success and failure;
- correct command arbitration through one virtual connection from two request
  threads;
- runtime stop followed by restart, transaction recovery, and same-command-ID
  receipt recovery without duplicate events;
- read/write request connections refusing to recreate a missing database;
- unchanged `/health` and unknown-route behavior through `make-app`.

## Deliberately deferred

This runtime composition and HTTP adapter do not add:

- a readiness endpoint;
- authentication or authorization;
- a persistent catalog;
- automatic SQLite busy retry or backoff;
- a generic service container or component framework;
- payment, device, drawer, or receipt integration;
- exactly-once external-effect guarantees.

Future external effects still require persisted intent and explicit
unknown-outcome recovery; they must not be placed inside a long-lived SQLite
writer transaction.
