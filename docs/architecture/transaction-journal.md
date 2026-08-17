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

The authoritative event-history decision is recorded in
[ADR-0010](../adr/0010-use-append-only-event-journal-for-transaction-truth.md).
The command retry and concurrency decision that safely coordinates with this
journal is recorded in
[ADR-0011](../adr/0011-use-durable-command-receipts-and-expected-stream-versions.md).

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
`create_transaction_events`.

Migration version 2 creates `transaction_command_receipts`, the durable store
for typed command identity and original deterministic outcome metadata. Its
full schema and persistence contract are documented in
[Transaction Command Receipts](transaction-command-receipts.md). These
receipts are not transaction facts and are never replayed as transaction
state.

The migration runner treats recorded history as an exact prefix of the known
ordered migration list. A fresh database applies versions 1 and 2. A real v1
database validates and preserves its event schema and rows before applying only
version 2. A correct v2 database is validated without schema mutation. Unknown,
skipped, reordered, renamed, or drifted migration state fails rather than being
silently repaired. This ordered-prefix mechanism can extend to migration 3
without adding another historical-version conditional.

Table creation is not hidden inside append or load. Application composition is
responsible for running migrations explicitly before using the store.

No recorded timestamp is present in either current table. A future timestamp
would be persistence metadata only; it must never determine event order or
affect replay.

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

### Internal transaction ownership split

The public append operation is implemented as:

```text
validate arguments and reject an empty list
  -> prepare and serialize the complete event batch
  -> BEGIN IMMEDIATE
  -> transaction-scoped version/identity checks and inserts
  -> COMMIT
```

`prepare-transaction-events` accepts only a non-empty list of domain events and
returns an opaque prepared batch. Its constructor and encoded fields are not
public, so persistence composition code cannot supply arbitrary schema
versions, event types, or event JSON. Preparation performs no database access
or transaction management.

`append-prepared-transaction-events/in-transaction!` performs the final stream
version read, identity checks, sequence allocation, and inserts without
starting, committing, or rolling back a transaction. Its explicitly internal
composition contract requires an active caller-owned database transaction and
is enforced using Racket DB's transaction-state predicate.

The public `append-transaction-events!` remains the normal standalone API and
continues to own one `BEGIN IMMEDIATE` transaction. Persistence composition can
prepare first and invoke the same transaction-scoped mechanics
inside a larger caller-owned transaction.

The transaction-command unit of work now uses that composition seam. It
serializes accepted events before reserving the writer, then uses one
`BEGIN IMMEDIATE` for the final command-ID lookup, stream-version check, event
append, and receipt insertion. A receipt-only deterministic outcome uses the
same writer transaction without appending a transaction fact. If the receipt
cannot be inserted after events were written, the callback aborts so the event
inserts roll back rather than committing alone.

`transaction-stream-version/in-transaction` exposes the same current-version
query to this persistence composition and requires an active caller-owned
transaction. The event append core repeats the final expected-version check
before its inserts; both checks therefore occur under the same SQLite writer
reservation.

The transaction service uses this unit of work for every mutation. It performs
an optimistic early receipt lookup to avoid repeating work for a known command,
while the unit of work repeats identity and version validation inside the final
writer transaction to close races.

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
connection and an injected catalog lookup. It neither owns a global connection
nor runs migrations on every command. Bootstrap composition remains
responsible for opening the configured database and migrating it once.

The service provides operations to:

- execute one of the four typed mutating transaction commands;
- load/recover current authoritative transaction state.

### Duplicate, Recover, Decide, Commit

A mutation follows this sequence:

```text
load receipt by command_id
  -> known equal command: return original receipt
  -> known different command: reject command-ID reuse
  -> corrupt receipt: fail recovery
  -> unused ID:
       load and replay ordered journal stream
         -> enforce caller expected_version
         -> decide through the pure domain when fresh
         -> create accepted or receipt-only commit plan
         -> atomically commit through the command unit of work
```

The unit of work repeats command-ID and stream-version checks under
`BEGIN IMMEDIATE`. A final race can replace any provisional outcome with a
durable `stream_version_conflict`; the service does not reload, retry, or
re-decide automatically.

Deterministic two-connection tests force two services to complete optimistic
recovery and decision before either final commit. They establish that
simultaneous same-command submissions converge on one durable receipt and one
set of facts, same-ID/different-command submissions preserve only the winner,
and distinct commands at the same expected version cannot both append their
provisional facts. A losing deterministic rejection is likewise not frozen if
the stream changes before its final receipt commit.

The application never silently substitutes the latest stream version for a
new command's caller-supplied expected version. A stale command becomes a
receipt-only `stale_expected_version` outcome without domain or catalog work.

### Result Classes

Mutation results distinguish:

- resolved command containing its durable original receipt;
- command-ID reuse;
- stable command persistence failure;
- receipt/journal/replay recovery failure.

Mutation results never contain provisional transaction state or a duplicate
flag. A deterministic domain rejection is represented by its durable receipt
and writes no transaction event.

Transaction queries retain their separate result classes for recovered state,
not-found, and recovery failure. Querying transaction state does not read
command receipts, preserving the journal as transaction truth.

Journal decoding/corruption failures identify the load stage and retain stable
journal diagnostics. A syntactically valid journal whose events violate the
domain lifecycle fails at the replay stage. Neither failure path invokes the
requested domain command or returns partial state as success. Genuine SQLite
operational exceptions continue to propagate as infrastructure failures.

### Catalog Boundary and Restart Recovery

The service does not hard-code a catalog. Composition injects the current
catalog lookup when constructing the service. A fresh, version-matched scan
uses it through the live domain decision; an accepted `sale-item-added` event
persists the sale-time barcode, description, and exact unit price snapshot.
Known retries, command-ID reuse, missing transactions, stale commands, and
historical replay do not consult the catalog.

Process restart recovery opens the same SQLite database using a new connection,
loads and decodes the stream, and replays it from the first event. No mutable
in-memory transaction snapshot is required. File-backed tests cover creation
and scan on one connection, tender after a first restart, completion after a
second restart, and final recovery after a third restart.

File-backed tests also simulate a caller-observed exception immediately after
the real command unit of work has committed. After closing that connection, a
new service resolves the same command ID from its durable receipt and does not
append the fact or consult the catalog again. Conversely, a simulated failure
before the unit of work leaves no event or receipt, so retrying that same ID can
execute normally. This is a retry-based recovery protocol for uncertain caller
observation; it is not a claim of arbitrary distributed exactly-once execution.

## Deliberately Deferred

The persistent service is not yet exposed through HTTP or Flutter. This
checkpoint also does not add:

- authoritative snapshots or projections;
- timestamps or event UUIDs;
- hash chaining or integrity signatures;
- outbox or cloud synchronization tables;
- sale-receipt, tender, inventory, or card-payment tables;
- partial/split tender or other new transaction behavior;
- HTTP or Flutter integration.

Connection paths and ownership remain composition concerns. Persistence code
does not hard-code `SQLITE_DB_PATH` and does not hide a global mutable database
connection. Automated tests use isolated temporary databases rather than the
developer's normal local database. Runtime HTTP composition must still choose
and test a connection-ownership model. Automatic SQLite busy retry/backoff is
also deferred; a lock failure is currently an infrastructure failure, and
tests establish that it cannot produce a false durable success or partial
command write.
