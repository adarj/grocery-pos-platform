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
and validates that the expected table and unique index still exist. Unknown or
inconsistent migration histories fail rather than being silently adopted.

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

## Deliberately Deferred

This checkpoint does not connect the journal to live transaction commands. It
also does not add:

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
