# Transaction Command Receipts

## Status and purpose

Migration v2 implements durable transaction-command receipt storage. A receipt
associates one fully typed
[Transaction Command Schema v1](transaction-command-schema.md) command with
its original deterministic outcome metadata.

Receipts provide persistence groundwork for later retry deduplication. The
transaction-command unit of work now resolves duplicate identities and can
atomically commit accepted events plus their receipt, or a receipt-only
deterministic outcome. The transaction service does not yet use that unit of
work, so end-to-end retry-safe application behavior remains a later checkpoint.

## Boundary from transaction truth

The two durable records have different meanings:

```text
transaction_events
    = accepted transaction facts and authoritative transaction history

transaction_command_receipts
    = request identity and original deterministic outcome metadata
```

A receipt stores no line items, totals, status, tender state, transaction
snapshot, or emitted event payload. Transaction replay reads only
`transaction_events` and remains independent of command receipts.

## Receipt value

The immutable Racket receipt contains:

- the fully typed transaction command;
- one closed outcome kind;
- a non-empty language-independent outcome code;
- the original outcome stream version as an exact nonnegative integer.

Supported v1 outcome kinds are:

```text
accepted
domain_rejected
not_found
already_exists
version_conflict
```

Outcome codes are not constrained to a hard-coded list of business rejection
codes. Values such as `unknown_barcode`, `insufficient_tender`, or
`stale_expected_version` can be stored without teaching SQLite every domain or
application rejection.

The outcome stream version means:

- accepted: the newly committed stream version;
- domain rejected: the unchanged version used for the decision;
- not found: zero;
- already exists: the observed existing version;
- version conflict: the actual observed version.

The unit of work also receives a `decision_stream_version`: the actual stream
version against which the application made its provisional decision. This is
distinct from the caller-supplied `expected_version` stored in the command.
For example, a start command can expect version zero while an already-existing
outcome was decided against actual version four.

## Migration v2 schema

Migration history records:

```text
1 create_transaction_events
2 create_transaction_command_receipts
```

Migration 2 creates:

```sql
CREATE TABLE transaction_command_receipts (
  command_id TEXT PRIMARY KEY NOT NULL
    CHECK (
      typeof(command_id) = 'text'
      AND length(command_id) > 0
    ),
  transaction_id TEXT NOT NULL
    CHECK (
      typeof(transaction_id) = 'text'
      AND length(transaction_id) > 0
    ),
  command_schema_version INTEGER NOT NULL
    CHECK (
      typeof(command_schema_version) = 'integer'
      AND command_schema_version > 0
    ),
  command_type TEXT NOT NULL
    CHECK (
      typeof(command_type) = 'text'
      AND length(command_type) > 0
    ),
  expected_version INTEGER NOT NULL
    CHECK (
      typeof(expected_version) = 'integer'
      AND expected_version >= 0
    ),
  command_json TEXT NOT NULL
    CHECK (
      typeof(command_json) = 'text'
    ),
  outcome_kind TEXT NOT NULL
    CHECK (
      typeof(outcome_kind) = 'text'
      AND outcome_kind IN (
        'accepted',
        'domain_rejected',
        'not_found',
        'already_exists',
        'version_conflict'
      )
    ),
  outcome_code TEXT NOT NULL
    CHECK (
      typeof(outcome_code) = 'text'
      AND length(outcome_code) > 0
    ),
  outcome_stream_version INTEGER NOT NULL
    CHECK (
      typeof(outcome_stream_version) = 'integer'
      AND outcome_stream_version >= 0
    )
);
```

`command_id` is globally unique in the local database. It is not scoped by
transaction ID. Receipts have no TTL in v1 and are retained for as long as the
corresponding transaction-journal history is retained.

## Insert contract and transaction ownership

`insert-transaction-command-receipt!` accepts a typed receipt and derives all
command envelope columns plus `command_json` from the Transaction Command
Schema v1 codec. Callers cannot independently supply duplicated metadata.

Insertion never overwrites an existing command ID. A primary-key collision
returns a stable `command-id-conflict` result and leaves the original row
unchanged.

The low-level insert deliberately does **not** start or commit a SQLite
transaction. It executes inside the caller's current transaction or SQLite
autocommit context. `commit-transaction-command-outcome!` is the higher-level
persistence operation that supplies the required transaction ownership when a
command outcome is committed.

## Atomic command-outcome unit of work

The immutable `transaction-command-commit-plan` contains:

- the fully typed command;
- the decision stream version;
- the provisional outcome kind and code;
- a non-empty ordered event list for an accepted outcome, or no events for a
  non-accepted outcome.

Those shape rules prevent accepted commands without facts and prevent rejected
commands from smuggling events into transaction truth.

For an accepted plan, event serialization finishes before the SQLite writer
transaction begins. The unit of work then owns one `BEGIN IMMEDIATE` and:

1. looks up the global command ID before inspecting the stream;
2. returns the original receipt for the same structurally equal typed command;
3. rejects the same ID with a different typed command without writing;
4. fails closed if an existing receipt is corrupt;
5. re-reads the current stream version and compares it with
   `decision_stream_version`;
6. atomically appends accepted events and inserts their receipt, or inserts a
   receipt-only deterministic outcome.

If the final stream version changed after the application made its provisional
decision, the obsolete outcome and any provisional events are discarded. The
unit of work instead records `version_conflict / stream_version_conflict` at
the newly observed version. It never reloads or re-decides the command.

An event-append rejection or receipt-insert conflict takes an abnormal rollback
path so SQLite cannot commit only one half. Genuine SQLite exceptions also
propagate through `call-with-transaction`, which rolls back the whole unit.
Transaction events remain authoritative facts; the receipt contains no
transaction state and replay remains independent of it.

## Load and corruption handling

Lookup by global command ID returns found, not-found, or failed. Not-found is a
normal successful lookup outcome.

For an existing row, load:

1. validates SQLite storage classes and envelope value shapes;
2. strictly decodes `command_json` through Transaction Command Schema v1;
3. derives canonical metadata from the decoded typed command;
4. validates agreement for command ID, transaction ID, schema version, command
   type, and expected version;
5. validates outcome kind, code, and stream version;
6. reconstructs the immutable receipt only after every check succeeds.

Detected corruption returns no partial receipt. Stable failure codes are:

```text
invalid-envelope
command-decode-failure
command-id-mismatch
transaction-id-mismatch
command-schema-version-mismatch
command-type-mismatch
expected-version-mismatch
invalid-outcome-kind
invalid-outcome-code
invalid-outcome-stream-version
```

Malformed JSON and unsupported command schema versions appear as
`command-decode-failure` with the underlying stable codec code as diagnostic
detail. Genuine SQLite connection, disk, or schema-availability failures remain
infrastructure exceptions, consistent with the transaction event store.

## Deliberately deferred

This persistence contract does not yet implement:

- transaction-service use of duplicate-first processing;
- service expected-version enforcement;
- conditional catalog/domain decision avoidance for known retries;
- HTTP command routes or responses;
- receipt expiration or cleanup.
