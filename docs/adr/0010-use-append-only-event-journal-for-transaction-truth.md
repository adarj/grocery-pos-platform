# ADR-0010: Use an append-only event journal for transaction truth

Status: Accepted

Date: 2026-08-16

## Context

Transactions must survive POS Core and application restarts, and live execution
and recovery must reconstruct the same authoritative business state. Mutable UI
state cannot be transaction truth.

Storing only a mutable current-transaction row would discard the accepted facts
that led to the current state. That would weaken recovery and auditability and
make it harder to determine whether live execution and restart recovery apply
the same transaction rules.

Racket owns transaction semantics, while SQLite owns local durability. Accepted
transaction commands already produce domain events representing business facts,
which provides a natural durable boundary between those responsibilities.

## Decision

Persist accepted transaction business facts in SQLite as an append-only,
per-transaction event stream with explicit ordered sequence numbers.

Authoritative transaction state is reconstructed by decoding the stored events
and replaying them through the Racket transaction reducer. Normal live state
transitions and recovery use the same event-application semantics. Replay does
not re-execute catalog lookups, commands, or external effects.

Persisted sale-item events contain the accepted sale-time barcode, description,
and exact unit price needed for reconstruction without consulting the current
catalog.

Mutable projections or snapshots may be introduced later for query or
performance needs, but they are derived data and are not authoritative
transaction truth.

## Relationship to ADR-0004

[ADR-0004](0004-use-sqlite-for-local-register-state.md) answers: "Which local
database technology do we use?"

This ADR answers: "How is authoritative transaction truth represented and
recovered within that database?"

ADR-0010 supplements rather than replaces ADR-0004.

## Scope

This decision governs authoritative transaction history. It does not require
every future local subsystem or durable register concern to use event sourcing.

## Consequences

### Positive

- Restart recovery is deterministic.
- Live execution and replay share one state-transition model.
- Historical accepted transaction facts remain explicit.
- The journal provides a strong audit, debugging, and recovery basis.
- Historical replay requires no catalog lookup or external side effect.
- Racket semantics remain separate from SQLite durability.

### Negative

- Event-schema compatibility must be maintained.
- Malformed or corrupt streams require explicit recovery handling.
- Efficient read and reporting workloads may eventually need projections.
- Event streams and database migrations require disciplined versioning.
- Correcting historical facts cannot be modeled as arbitrary row mutation.
- Event sourcing does not solve every local persistence concern.

## Alternatives Considered

### Store only a mutable current transaction snapshot

Rejected as authoritative truth because historical accepted facts and
deterministic event replay would be lost.

### Mutate live state independently and retain events only as audit records

Rejected because live execution and recovery could drift semantically.

### Re-run original commands during recovery

Rejected because command decisions may depend on current catalog state or
future external effects that must not be repeated during replay.

## Notes

The detailed journal schema, append/load behavior, corruption handling, and
service contract are documented in the
[SQLite Transaction Journal](../architecture/transaction-journal.md).
