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
2. A versioned **Transaction Event Schema JSON** value is the stable,
   language-independent encoding. Its exact schemas are documented in
   [Transaction Event Schemas](transaction-event-schema.md).
3. A **journal record** is a SQLite persistence envelope. It adds database row
   identity, transaction stream identity, and per-stream sequence to the event
   JSON.

`schema_version` and `event_type` appear both in the journal envelope and the
encoded JSON. This deliberate duplication supports database diagnostics and
future indexing. Append derives both copies from the same codec result, and
load rejects a record if the copies disagree.

## Schema and Migration

Database migration is explicit. `migrate-pos-database!` creates and uses:

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

Migration version 3, `create_catalog`, creates the persistent local catalog
item and barcode-assignment tables. The catalog answers new-scan lookup
questions; it is not transaction truth and is never consulted during replay.
Its schema and read contract are documented in
[Local Catalog](catalog.md).

Migration version 4, `create_tax_categories`, adds current tax categories and
exactly one item-category mapping per catalog item. Existing v3 items receive
an explicit zero-tax compatibility mapping. Migration-3-owned table definitions
and existing event/receipt rows remain unchanged.

The migration runner treats recorded history as an exact prefix of the known
ordered migration list. A fresh database applies versions 1 through 4. Real
v1/v2 databases upgrade through the remaining sequence, while a real v3
database preserves its merchandise rows and receives zero-tax mappings. A
correct v4 database is validated without schema mutation. Unknown, skipped, reordered,
renamed, or drifted migration state fails rather than being silently repaired.

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

All events are encoded with their declared Transaction Event Schema before
writes begin. Existing lifecycle events and legacy sale lines remain v1; new
taxed sale lines use v2.
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
are deliberately short. Runtime composition now supplies a bounded pool and a
thread-mapped virtual connection; automatic busy handling and higher-throughput
policy remain future concerns.

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
events and its final stream version. Each row is decoded through the strict
version-aware event codec. Load validates:

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

`make-transaction-service` receives an already-prepared SQLite connection value
and an injected catalog lookup. At runtime that value is a virtual connection
backed by a bounded pool of actual connections. The service neither owns a
global physical connection nor runs migrations on every command. The process
composition root opens a dedicated startup connection, migrates the configured
database once, disconnects that connection, and only then creates request-time
resources.

The service provides operations to:

- execute one of the six typed mutating transaction commands;
- load/recover current authoritative transaction state;
- derive a canonical receipt from a completed replay.

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

### Append-only Cashier Corrections

Open-sale corrections use the same command/receipt/unit-of-work boundary as
the other mutations. `remove_line_item` appends `sale_line_removed`; it never
deletes the earlier `sale_item_added` fact. The zero-based line index is
interpreted only after the caller's expected version matches, preventing a
stale selection from being applied to a newer basket. Replay removes exactly
that line's already-stored base-price and tax contribution and performs no
catalog lookup.

`void_transaction` appends `transaction_voided` only from open state. The
terminal voided projection retains the cancelled basket and its descriptive
subtotal, tax, and total. It is not completed revenue. Same-ID retries resolve
the original durable receipt, so a lost removal response cannot remove a
second line and a lost void response cannot append another void event. These
decisions are recorded in
[ADR-0014](../adr/0014-represent-cashier-corrections-as-append-only-transaction-events.md).

### Catalog Boundary and Restart Recovery

The service does not hard-code a catalog. Composition injects the current
catalog lookup when constructing the service. A fresh, version-matched scan
uses it through the live domain decision; an accepted Schema v2
`sale-item-added` event persists the sale-time barcode, description, exact unit
price, tax category, rate millionths, and calculated line-tax snapshot.
Known retries, command-ID reuse, missing transactions, stale commands, and
historical replay do not consult the catalog.

Schema v1 sale lines replay with zero tax. Schema v2 replay uses the stored tax
amount and never current tax reference data. Mixed v1/v2 streams are valid:
subtotal sums base prices, tax sums stored line tax, and total is their exact
sum. See
[ADR-0013](../adr/0013-snapshot-exact-line-tax-in-transaction-events.md).

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

### Canonical completed-sale receipts

A completed transaction replay plus its final stream version contains every
fact needed for Receipt Schema v1. POS Core maps final retained lines and the
transaction projection into an immutable canonical receipt. It does not query
current catalog/tax data or reconstruct merchandise through command receipts.
Open, paid, and voided streams are explicitly ineligible.

No materialized receipt table is added. This avoids a second historical sale
authority and projection-synchronization boundary. Exact lookup is exposed by
`GET /receipts/{transaction_id}` and remains deterministic after process
restart and current reference-data replacement. See
[Canonical Completed-Sale Receipts](receipts.md) and
[ADR-0015](../adr/0015-derive-canonical-receipts-from-completed-transaction-replay.md).

## Deliberately Deferred

The persistent service is exposed through the narrow command/query routes in
[Transaction HTTP API v1](transaction-http-api-v1.md), and the Flutter cashier
uses those routes for the current cash-sale workflow. The journal design still
does not add:

- authoritative snapshots or projections;
- timestamps or event UUIDs;
- hash chaining or integrity signatures;
- outbox or cloud synchronization tables;
- materialized sale-receipt, tender, inventory, or card-payment tables;
- partial/split tender or other new transaction behavior;
- post-payment refund/reversal behavior.

Persistence code does not hard-code `SQLITE_DB_PATH` and does not hide a global
mutable database connection. The runtime resolves the configured path once,
migrates with a dedicated startup connection, and gives request threads actual
connections through a bounded pool and virtual connection. See
[Racket POS Core Runtime Composition](racket-runtime.md). Automated tests use
isolated temporary databases rather than the developer's normal local
database. Automatic SQLite busy retry/backoff remains deferred; a lock failure
is currently an infrastructure failure, and tests establish that it cannot
produce a false durable success or partial command write.
