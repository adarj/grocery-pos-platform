# SQLite Transaction Journal

## Purpose

The transaction journal is the durable local record of accepted transaction
facts. It is append-only and stores one independently ordered event stream per
transaction.

The journal does not store an authoritative mutable transaction snapshot.
Racket reconstructs transaction state by loading, decoding, and replaying the
ordered domain events through the pure transaction reducer.

In short:

```text
SQLite journal = durable accepted facts
Racket replay   = authoritative transaction-state reconstruction
```

This keeps transaction meaning in the Racket domain and durability in SQLite,
consistent with the repository's architecture boundaries.

## Three Representations

The implementation deliberately separates three related representations:

1. A **domain event** is an immutable Racket business fact such as
   `sale-item-added`.
2. **Transaction Event Schema v1 JSON** is the stable, language-independent
   encoding of that domain event. Its exact schema is documented in
   [Transaction Event Schema v1](transaction-event-schema.md).
3. A **journal record** is a SQLite persistence envelope. It adds database row
   identity, transaction stream identity, and per-stream sequence to the Schema
   v1 JSON.

`schema_version` and `event_type` appear both in the journal envelope and the
encoded JSON. This deliberate duplication supports database diagnostics and
future indexing. Append derives both copies from the same codec result, and
load rejects a record if the copies disagree.

## Schema and Migration

Schema migration is explicit. `migrate-transaction-journal!` creates and uses:

```sql
CREATE TABLE pos_schema_migrations (
  version INTEGER PRIMARY KEY,
  name TEXT NOT NULL
);
```

Migration version 1 creates:

```sql
CREATE TABLE transaction_events (
  id INTEGER PRIMARY KEY,
  transaction_id TEXT NOT NULL,
  stream_sequence INTEGER NOT NULL CHECK (stream_sequence > 0),
  schema_version INTEGER NOT NULL CHECK (schema_version > 0),
  event_type TEXT NOT NULL,
  event_json TEXT NOT NULL
);

CREATE UNIQUE INDEX transaction_events_stream_sequence_unique
ON transaction_events (transaction_id, stream_sequence);
```

The implementation also uses `typeof(...)` checks so values are stored with
the intended SQLite storage classes. Migration 1 is recorded as
`create_transaction_events`. Re-running migration against version 1 is safe
and validates the exact recorded `(version, name)` migration identity, the
expected table, and an actually unique stream index over exactly
`(transaction_id, stream_sequence)`. Unknown or inconsistent migration
histories and drifted index definitions fail rather than being silently
adopted.

Table creation is not hidden inside append or load. Application composition is
responsible for running migrations explicitly before using the store.

No recorded timestamp is present in version 1. A future timestamp would be
persistence metadata only; it must never determine event order or affect
replay.

## Stream Sequence and Identity

Each `transaction_id` names an independent stream. Its first event has
`stream_sequence = 1`, and every subsequent event increments that sequence by
one. Loads always use:

```sql
ORDER BY stream_sequence ASC
```

SQLite row IDs never determine business order. The unique stream/sequence
index is a last-line integrity constraint, while load also checks for gaps or
nonconsecutive positions defensively.

A new stream obeys these rules:

- its expected version is `0`;
- its first event is `transaction-started`;
- the ID inside `transaction-started` equals the journal stream ID;
- no later event in the stream is another `transaction-started`.

These are basic stream-envelope integrity rules. Other transaction lifecycle
semantics remain the responsibility of the pure domain reducer during replay.

## Atomic Append and Optimistic Concurrency

The append API is:

```racket
(append-transaction-events!
 connection transaction-id expected-version events)
```

`events` is a non-empty ordered list of domain events. A successful result
contains the new stream version. An empty list is rejected rather than treated
as a successful no-op.

`expected-version` is the last stream sequence the caller believes is already
stored. Append compares it with the actual maximum stream sequence inside a
SQLite `BEGIN IMMEDIATE` transaction. The immediate transaction reserves the
SQLite writer before the version read, preventing a competing writer from
committing between the check and the batch inserts.

If the versions differ, append returns a stable `stream-version-conflict`
result with the actual version and writes nothing. The caller must reload and
make a new domain decision; it must not blindly overwrite or infer a merge.

All events are encoded with Transaction Event Schema v1 before writes begin.
The batch is then inserted at consecutive sequence numbers in one SQLite
transaction. If any insert fails, SQLite rolls back every insert from that
batch and preserves the earlier stream unchanged.

The initial design relies on SQLite's local writer serialization, optimistic
stream versions, and the unique index. It does not introduce a process-global
lock or a larger distributed-concurrency framework. SQLite permits one active
writer, so appends to different transaction streams can briefly contend even
though their expected versions are independent. The batches in this milestone
are deliberately short; connection-pool and higher-throughput policy remain
future composition concerns.

## Ordered Load and Corruption Detection

The load API is:

```racket
(load-transaction-events connection transaction-id)
```

A missing stream is a successful empty result with version `0`. This makes the
store contract compose directly with creation at expected version `0`; a
higher service layer may later translate an empty stream into a not-found API
response.

A successful non-empty load contains only the requested stream's ordered domain
events and its final stream version. Each row is decoded through the existing
strict Schema v1 codec. Load validates:

- consecutive sequences beginning at 1;
- envelope `schema_version` agreement with `event_json`;
- envelope `event_type` agreement with `event_json`;
- `transaction-started` as the first event;
- no later duplicate `transaction-started`;
- agreement between the start event's transaction ID and the stream ID.

Malformed journal-envelope values, malformed or unsupported event JSON,
metadata mismatches, sequence corruption, and stream-identity corruption return
a stable journal-load failure containing a failure code, stream sequence,
detail, and safe diagnostic message. A later bad record never produces a
partial successful stream.

Connection failures, missing migrations, disk errors, and other genuine SQLite
infrastructure failures may still raise database exceptions. Those conditions
are operational failures, not persisted-data validation results.

After a successful load, `replay-transaction` checks the complete business
lifecycle and reconstructs the transaction. Replay remains pure: it performs
no SQLite access, catalog lookup, clock read, ID generation, or network call.

## Persistent Transaction Service

The persistent transaction service is the application-layer coordinator
between pure domain decisions and the SQLite journal. It depends on both
layers, while neither the domain nor the journal depends on it:

```text
                 transaction service
                    /          \
          pure transaction    SQLite journal
               domain         and event codec
```

`make-transaction-service` receives an already-open, already-migrated SQLite
connection. It neither owns a global connection nor runs migrations on every
command. Bootstrap composition remains responsible for opening the configured
database and migrating it once.

The service provides operations to:

- start a transaction;
- load/recover a transaction;
- scan a barcode;
- tender sufficient cash;
- complete a paid transaction.

### Load, Replay, Decide, Append

An existing-transaction command follows this sequence:

```text
load ordered journal stream
  -> decode and validate journal records
  -> replay domain events
  -> decide command against recovered state
     -> rejected: append nothing
     -> accepted: append emitted events at loaded stream version
        -> append succeeds: report committed state
        -> append fails/conflicts: report failure, not provisional state
```

Starting a transaction uses the corresponding empty-stream flow. It verifies
that load reports no existing stream, asks the domain for the
`transaction-started` decision, and appends at expected version 0. An existing
stream is never overwritten or reset.

The state produced by an accepted domain command is **provisional** until the
exact emitted event list has been committed. The service returns that state as
success only after append succeeds. It is safe to avoid a redundant post-write
reload because the domain already produced the state by applying those exact
events through the same reducer used for replay. Tests separately prove that a
fresh load and replay returns an equal transaction.

### Result Classes

Explicit service results distinguish:

- committed success, containing transaction state and committed stream
  version;
- domain rejection, containing the business rejection code, unchanged
  recovered state, and unchanged version;
- transaction not found;
- transaction already exists;
- optimistic stream-version conflict;
- non-conflict persistence rejection;
- journal-load or replay recovery failure.

A domain rejection means the command was understood and business rules refused
it; no domain event is appended. Corrupt data, invalid replay history, and
concurrent writes are not presented as business rejections.

When append reports `stream-version-conflict`, the service exposes the expected
and actual versions without the provisional accepted transaction. It does not
silently reload or rerun the command. The caller must explicitly recover and
decide what to do next. This rule prevents future commands involving external
effects or user-visible choices from being repeated automatically.

Journal decoding/corruption failures identify the load stage and retain stable
journal diagnostics. A syntactically valid journal whose events violate the
domain lifecycle fails at the replay stage. Neither failure path invokes the
requested domain command or returns partial state as success. Genuine SQLite
operational exceptions continue to propagate as infrastructure failures.

### Catalog Boundary and Restart Recovery

The service does not hard-code a catalog. A scan receives a current catalog
lookup function explicitly. The lookup is used once by the live domain
decision; an accepted `sale-item-added` event persists the sale-time barcode,
description, and exact unit price snapshot. Historical load and replay have no
catalog dependency.

Process restart recovery opens the same SQLite database using a new connection,
loads and decodes the stream, and replays it from the first event. No mutable
in-memory transaction snapshot is required. File-backed tests cover creation
and scan on one connection, tender after a first restart, completion after a
second restart, and final recovery after a third restart.

## Deliberately Deferred

The persistent service is not yet exposed through HTTP or Flutter. This
checkpoint also does not add:

- authoritative snapshots or projections;
- timestamps, event UUIDs, or command IDs;
- hash chaining or integrity signatures;
- command idempotency;
- outbox or cloud synchronization tables;
- receipt, tender, inventory, or card-payment tables;
- partial/split tender or other new transaction behavior;
- HTTP or Flutter integration.

Connection paths and ownership remain composition concerns. Persistence code
does not hard-code `SQLITE_DB_PATH` and does not hide a global mutable database
connection. Automated tests use isolated temporary databases rather than the
developer's normal local database.
