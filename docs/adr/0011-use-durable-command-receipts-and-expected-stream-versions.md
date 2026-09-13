# ADR-0011: Use durable command receipts and expected stream versions for idempotent transaction commands

Status: Accepted

Date: 2026-08-17

## Context

A mutating client can submit a command, the POS Core can durably apply it, and
the response can be lost. Without durable logical command identity, retrying
the request can apply the business action again:

```text
client submits scan
  -> POS Core commits sale_item_added
  -> response is lost
  -> client retries
  -> scan can be applied a second time
```

Optimistic stream concurrency alone does not solve this problem. If the retry
is treated as a new command after the service reloads current state, its old
intent can be decided again against the newer transaction.

This risk extends beyond scanning. Future tender, refund, payment, drawer, and
remote-management actions can have more serious consequences when duplicated.
The local command boundary therefore needs both stable retry identity and
explicit concurrency intent while preserving the event journal as transaction
truth.

## Decision

Every consequential transaction mutation crosses the application boundary as
a strict typed command. Transaction Command Schema v1 contains:

- an explicit schema version;
- a `command_id` that is globally unique within the local register database;
- the target `transaction_id`;
- a caller-supplied `expected_version`;
- a command type;
- a typed command-specific payload.

The fully decoded typed command defines logical request identity. Raw JSON
bytes, whitespace, object-member order, and equivalent escape spellings do not.

`command_id` answers, "Is this the same logical intent being retried?"
`expected_version` independently answers, "Against which transaction state was
this genuinely new intent made?" The service must not silently replace a new
command's expected version with the latest stream version.

Durable command-receipt lookup precedes stream-version validation. Therefore,
a delayed retry of a command originally resolved at version 2 still returns
that original result after other commands advance the transaction to version
5; it does not become a new stale-version result.

The duplicate rules are:

- same command ID and same typed command: return the original durable receipt;
- same command ID and different typed command: reject command-ID reuse and
  execute no business action;
- never overwrite the original receipt.

Known durable duplicates do not repeat journal recovery, catalog lookup,
domain decision, event append, or future external work. The meaningful command
outcome is the same whether its receipt was newly committed or recovered for a
retry.

Deterministic accepted, business-rejected, not-found, already-existing, and
version-conflict outcomes can be stored as durable receipts. Infrastructure or
recovery failures are not invented as deterministic business outcomes.

For an accepted command, its transaction events and receipt commit in one
SQLite `BEGIN IMMEDIATE` transaction. The final writer transaction repeats the
command-ID lookup and stream-version validation before writing. An event may
not commit without its receipt, and a receipt claiming acceptance may not
commit without its events.

Application and persistence coordination distinguishes:

- `expected_version`: the caller's concurrency precondition for a new command;
- `decision_stream_version`: the actual stream version against which the
  provisional application outcome was determined.

`decision_stream_version` is internal coordination metadata, not a client API
field. If the stream changes before final commit, the obsolete provisional
outcome and events are discarded and a durable `stream_version_conflict` is
recorded at the newly observed version. The service does not automatically
reload or re-decide the command. Acting on the new state requires a client to
load that state and issue a new logical command with a new command ID.

If a caller cannot know whether final persistence completed, it retries the
same typed command with the same command ID. A landed commit is resolved by its
receipt. A failure before durable commit leaves no receipt, so the same command
remains eligible for execution. The caller must not generate a replacement ID
merely because the original response was uncertain.

Command receipts are not transaction truth:

```text
transaction_events
    = accepted authoritative transaction facts

transaction_command_receipts
    = request identity and original outcome metadata
```

Transaction replay ignores receipts. Receipts contain no authoritative
transaction snapshot.

## Relationship to ADR-0004

[ADR-0004](0004-use-sqlite-for-local-register-state.md) selects SQLite as the
local register database. This decision uses SQLite transactionality for atomic
event-and-receipt persistence in the current implementation.

The command semantics are not inherently tied to SQLite forever. ADR-0011
records the required identity, concurrency, and atomic-outcome behavior; a
future persistence technology would need to preserve those invariants.

## Relationship to ADR-0010

[ADR-0010](0010-use-append-only-event-journal-for-transaction-truth.md)
answers, "How is authoritative transaction business state persisted and
reconstructed?" It selects an append-only event journal and deterministic
Racket replay.

ADR-0011 answers, "How can mutating command submission and retry safely
interact with that journal?" It adds durable global command identity,
caller-supplied expected stream versions, and atomic command-receipt/event
persistence.

ADR-0011 supplements ADR-0010. It does not replace event-sourced transaction
truth with command receipts.

## Concurrency Guarantee

Two simultaneous first submissions of the same previously unseen command can
both finish optimistic pure application work before either receipt exists. For
a scan, both can perform the side-effect-free catalog lookup.

The final atomic persistence boundary guarantees that they cannot create two
durable receipts for one command ID or append duplicate accepted transaction
facts for that command. Identical submissions converge on the winner's original
receipt. The same ID with different typed commands preserves one winner and
rejects the loser as command-ID reuse.

For distinct command IDs decided against one transaction stream version, at
most one can commit its provisional transaction facts at that version. A loser
receives a durable final version conflict rather than automatic redecision.

This is a local command/journal concurrency guarantee, not generic distributed
exactly-once execution.

## External-Effect Limitation

Command receipts do not guarantee exactly-once execution of payment-terminal,
printer, drawer, network, or other device effects. The local SQLite writer
transaction must not be held open around a future external call; a long-lived
database lock would not resolve an uncertain external outcome.

Future payment and device workflows need their own safety design, such as
persisted intent, external operation correlation, inquiry/recovery, and an
explicit unknown-outcome state. In particular, `PaymentUnknown` remains a
critical future payment concept: an unknown charge outcome must never be
resolved by blindly submitting another charge.

## Failure and Retention Rules

- A deterministic business or concurrency result may be durably receipted.
- An infrastructure or recovery failure before a known durable outcome does
  not receive a fabricated business receipt; retrying the same ID remains
  allowed.
- A caller-observed error around or after commit does not prove the commit
  failed; retrying the same ID resolves durable state.
- SQLite busy or writer contention must not appear as durable success.
  ADR-0018 later established bounded connector-level retry; it does not permit
  automatically rerunning the transaction command.
- Command receipts are retained at least as long as their corresponding
  transaction journal history. Schema v1 has no TTL or cleanup mechanism.

## Scope

This decision governs transaction-command idempotency and retry/concurrency
semantics. It does not require every future subsystem to use the exact current
receipt schema. Payment, remote-command, drawer, and other command families may
reuse these principles where appropriate, but each requires its own safety
analysis.

## Consequences

### Positive

- Lost-response retries do not duplicate accepted transaction facts.
- Command identity and its original outcome survive process restart.
- Stale distinct commands are not silently re-decided against newer state.
- Deterministic rejection outcomes remain stable across retries.
- Transaction event truth remains separate from command metadata.
- Concurrent submissions have an explicit final arbitration point.
- The boundary provides safer groundwork for later consequential commands.

### Negative

- Receipt storage grows with retained transaction history.
- Command schema and outcome compatibility become long-lived contracts.
- Clients must maintain stable command IDs and observed stream versions.
- Conflicts require explicit client reload and new-intent behavior.
- Optimistic pure work can execute more than once before the first receipt is
  durable.
- Persistence orchestration is more complex than naive load/decide/append.
- This design does not resolve external-effect ambiguity by itself.

## Alternatives Considered

### Use optimistic stream versions only

Rejected because a lost-response retry could be treated as a new command
against the now-current state.

### Keep command deduplication only in memory

Rejected because command identity and outcomes would be lost across POS Core
restart.

### Scope command IDs by transaction

Rejected in favor of one database-global namespace, which detects accidental
reuse across transactions and simplifies lookup and investigation.

### Persist the command receipt and transaction events in separate commits

Rejected because a crash between commits would create retry ambiguity or a
receipt that falsely claims an accepted outcome.

### Return current transaction state for a duplicate command

Rejected because a delayed duplicate must preserve its original outcome and
version. Current state is obtained through a separate transaction query.

### Automatically reload and re-decide stale or racing commands

Rejected because it changes the state against which the caller's original
intent was made and can turn one logical command into a different decision.

### Store full transaction snapshots in command receipts

Rejected because receipts would become a competing authoritative transaction
state store.

### Freeze infrastructure failures as durable command outcomes

Rejected because a transient failure should remain retryable when no
deterministic outcome was durably established.

### Hold the SQLite transaction open around future external effects

Rejected as a future architecture direction because long-held writer locks do
not solve uncertain external outcomes and would couple local persistence to
device or network latency.

## Notes

Detailed current contracts are documented in:

- [Transaction Command Schema v1](../architecture/transaction-command-schema.md)
- [Transaction Command Receipts](../architecture/transaction-command-receipts.md)
- [SQLite Transaction Journal](../architecture/transaction-journal.md)
- [Local POS API Contract](../architecture/local-api.md)
