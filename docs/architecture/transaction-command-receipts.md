# Transaction Command Receipts

## Status and purpose

Migration v2 implements durable transaction-command receipt storage. A receipt
associates one fully typed
[Transaction Command Schema v1](transaction-command-schema.md) command with
its original deterministic outcome metadata.

Receipts provide persistence groundwork for later retry deduplication. The
transaction service does not yet write or consult them, and this checkpoint
does not yet atomically commit a receipt with transaction events.

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

This checkpoint validates and persists these fields but does not yet produce
them from service operations.

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
autocommit context. This is groundwork for a later unit of work that can append
transaction events and insert the receipt inside one caller-owned
`BEGIN IMMEDIATE` transaction. That event-plus-receipt atomicity is not yet
implemented.

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

- duplicate-first service processing;
- same-ID/same-command outcome replay;
- same-ID/different-command rejection;
- service expected-version enforcement;
- atomic event append plus receipt insert;
- HTTP command routes or responses;
- receipt expiration or cleanup.
