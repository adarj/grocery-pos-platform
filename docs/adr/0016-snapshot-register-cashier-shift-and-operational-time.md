# ADR-0016: Snapshot register, cashier, shift, and operational time in transaction history

Status: Accepted

Date: 2026-08-24

## Context

Store operation must identify the register, selected cashier, and shift that
produced a sale. Current register/cashier references can later be renamed or
deactivated, so querying current configuration cannot provide historical
attribution. Receipt Schema v1 deliberately omitted fabricated context and
time because earlier events did not contain them.

The single-register workflow also needs an enforceable coordination boundary:
a shift must not close through an active sale, and two transactions must not
claim the same register shift. These rules must compose with durable command
idempotency rather than being enforced only by Flutter.

Cashier identity selection in this milestone is attribution, not proof of a
human identity. Adding a weak PIN mechanism would create unjustified security
claims.

## Decision

- Persist one current configured register, a current cashier directory, and
  durable register shifts in SQLite.
- A shift snapshots the current register/cashier IDs and display names when it
  opens and records exact POS-Core-observed UTC epoch milliseconds.
- Enforce at most one open shift per register and one active transaction slot
  per shift.
- Require a configured register and open idle shift for every new transaction
  start. Flutter does not send operational context in Transaction Command
  Schema v1.
- Use Transaction Event Schema v2 forms to snapshot register, cashier, shift,
  start time, and new completion/void times. Legacy event forms remain valid
  with absent context/time.
- Atomically commit a start event, durable command receipt, and shift-slot
  claim. Atomically commit completion/void event, receipt, and exact slot
  release.
- Recheck the slot under the same `BEGIN IMMEDIATE` writer boundary and fail
  closed if a context-bearing transaction and shift row disagree.
- Preserve command-receipt lookup precedence so a durable same-ID retry returns
  its original result even after operational state changes.
- Derive Receipt Schema v2 for new completed transactions from replayed
  operational context/time. Keep Receipt Schema v1 unchanged for legacy sales.
- Treat Flutter cashier selection as identity attribution, not authentication.

## Consequences

- Historical identities survive current configuration renames and cashier
  deactivation.
- New receipts have durable register/cashier/shift and recorded start/complete
  times without a receipt table.
- Shift close cannot cross an active transaction, including after POS Core
  restart.
- Start/terminal transaction facts and shift coordination cannot commit only
  partially.
- New transactions cannot run anonymously; an unconfigured register or missing
  shift is a safe durable start rejection.
- Legacy transactions remain replayable and may finish without invented
  attribution.
- Local system clock accuracy remains an operational dependency; the recorded
  time is not cryptographically trusted or a fiscal certification.
- Durable shifts provide the basis for later cash-accountability work.
- Authentication and authorization remain separate future designs.

## Alternatives considered

### Let Flutter send register, cashier, shift, and time

Rejected because it would make presentation state authoritative for
operational transaction meaning and permit stale or fabricated attribution.

### Resolve old transaction attribution from current configuration

Rejected because renames and deactivation would rewrite history.

### Store context only in a receipt table

Rejected because transaction replay, not a duplicate receipt store, is the
historical authority and shift coordination is required before completion.

### Update shift state outside the command transaction

Rejected because event/receipt and slot state could diverge across a crash or
failure.

### Permit closing a shift with an active transaction

Rejected because the transaction would lose its single-register operational
owner and cash-accountability boundaries would be ambiguous.

### Add a casual cashier PIN

Rejected because identity selection is not authentication and secure employee
authentication requires a deliberate threat model, credential lifecycle, and
authorization policy.

## Scope

This decision does not define PIN/password authentication, roles, manager
approval, store/address identity, payroll/timeclock behavior, breaks, opening
cash, drawer counts, expected cash, over/short, cash drops, receipt numbering,
broad transaction search, refunds, or cloud employee synchronization.
