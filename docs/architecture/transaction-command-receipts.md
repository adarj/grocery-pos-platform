# Transaction Command Receipts

## Status and purpose

Migration v2 implements durable transaction-command receipt storage. A receipt
associates one fully typed
[Transaction Command Schema v1](transaction-command-schema.md) command with
its original deterministic outcome metadata.

Receipts provide durable retry deduplication metadata. The transaction-command
unit of work resolves duplicate identities and can
atomically commit accepted events plus their receipt, or a receipt-only
deterministic outcome. The transaction service now uses that unit of work and
performs an early durable receipt lookup before transaction recovery or domain
decision, making its typed-command mutation boundary retry-safe.

The architectural decision and its tradeoffs are recorded in
[ADR-0011](../adr/0011-use-durable-command-receipts-and-expected-stream-versions.md).

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

## Application service behavior

`transaction-service-execute-command` is the only public transaction mutation
entry point. It accepts an immutable typed Transaction Command Schema v1 value.
The prior identity-free start, scan, tender, and completion functions are no
longer exported.

For every mutation, the service first loads the durable receipt by global
command ID:

- the same structurally equal typed command returns the original receipt before
  journal load, replay, catalog lookup, or domain decision;
- a different typed command with the same ID returns command-ID reuse without
  transaction work;
- corrupt receipt data returns a recovery failure and stops processing;
- only an unused command ID proceeds to transaction recovery and decision.

For a genuinely new non-start command, the caller's `expected_version` must
equal the recovered journal version. A mismatch produces the deterministic
`stale_expected_version` outcome without domain or catalog work. Start commands
require expected version zero; a nonzero value produces
`invalid_expected_version` after the real stream version has been observed.

Fresh commands delegate transaction validity to the existing pure domain
operations. The application explicitly maps their closed rejection symbols to
stable snake-case receipt codes. Every deterministic accepted or rejected
decision becomes a commit plan and is passed to the atomic unit of work. The
service does not append events or insert receipts independently.

Mutation success contains only the durable original receipt. It does not expose
a transaction snapshot or whether the receipt was newly committed versus found
for a retry. Current authoritative state remains available separately through
`transaction-service-load-transaction`, which reads only the event journal.

## Concurrent submissions and uncertain caller observations

The service's early receipt lookup is optimistic. Two simultaneous first
submissions can both observe an unused command ID, recover the same stream
version, and form provisional decisions. The atomic unit of work remains the
authoritative boundary:

- the same ID and same typed command converge on one receipt and one set of
  accepted facts;
- the same ID with a different typed command preserves the winner and returns
  command-ID reuse for the loser;
- different command IDs decided at the same stream version cannot both append
  their provisional facts;
- a provisional rejection based on a stream that later changes is replaced by
  `stream_version_conflict`, not frozen against obsolete state.

Because both simultaneous first submissions can finish optimistic application
work before either receipt exists, a side-effect-free catalog lookup can occur
twice. Once a receipt is durable, later retries resolve before catalog lookup,
journal recovery, or domain decision. This contract does not claim exactly-once
execution for payment or device effects; those edges require persisted intent
and explicit unknown-outcome recovery.

A caller-observed exception after the unit of work returns does not prove that
SQLite failed to commit. The recovery protocol is to retry the **same** typed
command with the same command ID. If the original commit landed, receipt lookup
returns its original outcome and version without another business action. If a
failure occurred before the atomic unit of work, no receipt or event exists and
the same command ID remains eligible for execution.

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

This persistence contract does not implement:

- whole-command retry after SQLite contention (the connector's bounded
  per-operation busy retry is defined by ADR-0018);
- exactly-once external payment or device effects and `PaymentUnknown`
  recovery;
- receipt expiration or cleanup.

The process-level SQLite ownership model is now implemented separately through
the bounded pool and thread-mapped virtual connection described in
[Racket POS Core Runtime Composition](racket-runtime.md). Transaction routes
use the receipt outcome through the transport mapping documented in
[Transaction HTTP API v1](transaction-http-api-v1.md); HTTP does not change the
receipt's persistence meaning.
