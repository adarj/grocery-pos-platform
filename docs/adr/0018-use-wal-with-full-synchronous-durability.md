# ADR-0018: Use WAL with FULL synchronous durability for the local POS database

Status: Accepted

Date: 2026-08-24

## Context

SQLite now owns substantial authoritative financial and operational register
durability: transaction events, command receipts, current catalog and tax
reference data, register configuration, shifts, active transaction ownership,
shift cash movements, immutable reconciliation, and migration history.

The application-level event, command, and cross-domain transaction boundaries
are explicit, but production connection construction previously inherited
important SQLite and Racket connector defaults. That left the effective journal
mode, synchronous durability, foreign-key enforcement, checkpoint threshold,
and busy handling insufficiently visible and allowed runtime and administrative
writers to drift apart.

One local register has modest write concurrency. Financial durability and a
predictable operating contract matter more than maximizing write throughput.

## Decision

All production Racket connections to the authoritative POS database use one
central connection constructor with this policy:

- `PRAGMA journal_mode = WAL` is established and verified by the dedicated
  create-capable initialization connection before migrations run;
- normal `read/write` connections verify that the effective journal mode is
  already WAL and never attempt normal request-time conversion;
- every production connection establishes and verifies
  `PRAGMA synchronous = FULL`;
- every production connection establishes and verifies
  `PRAGMA foreign_keys = ON`;
- every production connection establishes and verifies
  `PRAGMA wal_autocheckpoint = 1000`;
- Racket `sqlite3-connect` receives `#:busy-retry-limit 10` and
  `#:busy-retry-delay 0.1` explicitly; and
- a connection is disconnected before a policy establishment or verification
  failure propagates.

The runtime startup connection, runtime connection-pool factory, catalog
activation CLI, and register-configuration activation CLI use this shared
constructor. The startup connection remains `create` mode and is disconnected
before request resources are built. Runtime and administrative operational
connections remain `read/write` mode, so they cannot recreate a missing
database.

WAL and connection PRAGMAs are operating policy, not business schema history.
The global migration chain remains v1 through v6. Migration definitions are
unchanged and no migration is added for this decision.

`BEGIN IMMEDIATE` remains the transaction-command writer arbitration boundary.
The Racket connector's bounded busy handling does not reload or retry domain
decisions, retry whole commands, or add a process-global write mutex. Exhausted
contention continues through the existing persistence and unknown-outcome
error model.

## Rationale

WAL improves reader/writer coexistence for the bounded local request pool.
`FULL` synchronous durability preserves the strongest selected committed-data
protection across power loss; the current single-register write rate does not
justify choosing `NORMAL` before target-appliance measurements exist.

The 1000-page automatic checkpoint threshold intentionally retains SQLite's
conservative default strategy while making it project policy. Explicit Racket
busy parameters remove reliance on connector defaults without introducing a
second SQLite busy handler. Central construction prevents runtime and
administrative writers from acquiring different durability behavior.

## Rejected or deferred alternatives

### Use `synchronous = NORMAL`

Deferred until target-appliance measurements demonstrate a need and a later
decision explicitly accepts the weaker power-loss durability behavior.

### Retain DELETE journal mode

Rejected for the production operating contract because it provides less useful
reader/writer coexistence for the bounded request pool.

### Add a process-global write mutex

Rejected because SQLite's `BEGIN IMMEDIATE` boundary already arbitrates writers
where final command identity, stream version, events, receipts, and operational
effects are committed.

### Add `PRAGMA busy_timeout`

Rejected because the Racket connector already owns bounded SQLITE_BUSY handling
through its explicit retry limit and delay. A second competing busy handler
would obscure the effective policy.

### Retry whole commands or domain decisions

Rejected because automatic redecision could apply an intent against newer
transaction state and weaken command identity and `expected_version` semantics.

### Add custom or per-sale checkpointing

A checkpoint daemon, checkpoint thread, periodic TRUNCATE checkpoint, and
checkpoint per sale are deferred. The explicit 1000-page automatic threshold
is sufficient for this checkpoint pending measurements.

### Record connection settings in migration v7

Rejected because these settings govern how a connection and database operate;
they do not change the business schema.

## Consequences

### Positive

- Production database paths share one explicit, testable operating policy.
- Request and administrative writers cannot silently drift from runtime
  durability settings.
- WAL compatibility and all per-connection settings are verified rather than
  assumed.
- Short ordinary contention receives the connector's explicit bounded handling
  without changing transaction-command semantics.

### Negative

- `FULL` can make commits slower than `NORMAL`.
- Automatic checkpoints can occasionally add latency to the commit that
  triggers them.
- A database on storage that cannot enter or retain WAL mode fails closed.
- Every future production connection path must use the shared constructor.

## Deferred work

Backup/restore, corruption recovery tooling, integrity-check policy, manual or
scheduled checkpoint control, checkpoint metrics, appliance filesystem policy,
and power-loss qualification remain later Milestone 6 work.

