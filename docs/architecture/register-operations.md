# Register Operations and Shift Context

## Boundary

POS Core owns the operational context for this single-register MVP. Flutter
presents the authenticated operator and shift actions, but it does not choose
a cashier identity, supply register identity to transaction commands, or bind
transactions to shifts. POS Core derives the shift cashier from the
authenticated same-ID operator and current cashier configuration.

Current configuration and historical attribution are deliberately separate:

```text
operational configuration snapshot
  -> current register + current cashier directory

open shift
  -> immutable register/cashier name snapshot + open time

new transaction start
  -> immutable register/cashier/shift/start-time event snapshot
```

Renaming or deactivating a current cashier therefore cannot rewrite an old
shift, transaction, or receipt.

## SQLite schema and migration v5

Migration `5`, `create_register_operations`, adds:

```text
register_configuration
  singleton_id = 1
  register_id
  display_name

cashiers
  cashier_id
  display_name
  active (strict integer 0/1)

register_shifts
  shift_id
  register_id
  register_display_name
  cashier_id
  cashier_display_name
  opened_at_epoch_ms
  closed_at_epoch_ms nullable
  active_transaction_id nullable
```

The migration inserts no default register or cashier. A newly upgraded
database is legitimately unconfigured until an operator activates a snapshot.
SQLite partial unique indexes enforce at most one open shift per register and
prevent one non-null transaction ID from occupying multiple shift rows.

`active_transaction_id` coordinates register operation; it does not replace
the transaction journal as transaction truth.

## Operational Configuration Snapshot Schema v1

The strict full snapshot is:

```json
{
  "schema_version": 1,
  "register": {
    "register_id": "register-front-01",
    "display_name": "Front Register 1"
  },
  "cashiers": [
    {
      "cashier_id": "cashier-001",
      "display_name": "Alice",
      "active": true
    }
  ]
}
```

IDs and names are non-empty exact strings. They are not trimmed, normalized,
or parsed for meaning. Duplicate fields, unexpected fields, wrong primitive
types, unsupported schema versions, and duplicate cashier IDs fail strict
decode.

Activation replaces the one current register and the current cashier
directory atomically. It is rejected while any shift is open, leaves
historical shifts untouched, and rolls back completely on failure. Flutter has
no configuration-write API.

Migration 7 relates this operational directory to, but does not merge it with,
the security identity domain. Each configured cashier must have a same-ID
operator. Activation creates a cashier-role, no-credential operator stub only
for a genuinely new ID. An existing operator's display name, active state,
role, credential, and credential revision are preserved. Operators and their
credentials are not deleted when a cashier disappears from a later snapshot;
re-adding the exact ID reconnects to the same principal.

Operator commands are explicit about the file and target database:

```text
just register-config-validate fixtures/development/register-configuration-v1.json
just register-config-activate fixtures/development/register-configuration-v1.json /absolute/path/to/pos.db
```

The development fixture is test data, not a production identity seed. POS Core
never activates it automatically at startup.

## Shift lifecycle

`POST /shifts/open` accepts only the exact nonnegative integer
`opening_cash_minor_units`. POS Core derives the cashier ID from the
authenticated operator, resolves the current register and active same-ID
cashier, generates a cryptographically random `shift_...` ID, records an exact
UTC Unix epoch-millisecond open time, and snapshots the current display names.
The shift and immutable sequence-1 opening movement commit atomically. An
operator without a configured active same-ID cashier cannot open a shift.

Repeating open for the same cashier returns the existing open shift without
changing the opening amount; the HTTP summary remains limited or full according
to the caller's current read permission. An open shift for a different cashier
returns `shift_already_open`. This resource idempotence supports lost-response
recovery without adding Transaction Command Schema receipts to shift
operations.

`POST /shifts/{shift_id}/close` accepts exact nonnegative integer
`counted_cash_minor_units`. Closing an idle shift validates its cash ledger,
derives expected cash, and records signed over/short atomically with
`closed_at_epoch_ms`. Repeating close returns the first durable reconciliation
without changing it. A shift with an active transaction returns
`shift_has_active_transaction` and is not changed.

Open/close transport uncertainty is recovered by explicitly reading
`GET /register-context` and `GET /shifts/{shift_id}/cash-summary`. Flutter never
puts shift writes into its transaction command recovery file and never labels
them `Retry Command`. See [Shift Cash Accountability](cash-accountability.md).

## Active transaction slot and atomicity

An open idle shift has `active_transaction_id = NULL`. A new transaction may
start only in that state. The transaction command unit of work uses one
`BEGIN IMMEDIATE` transaction to commit:

```text
start:    transaction_started v2 + command receipt + claim shift slot
complete: transaction_completed v2 + cash_sale movement + command receipt + release shift slot
void:     transaction_voided v2 + command receipt + release shift slot
```

The slot condition is rechecked inside that writer boundary. Two provisionally
planned starts cannot both claim one shift. Release verifies that the shift
still points to the exact transaction and otherwise fails closed as operational
state corruption. Any event, receipt, or slot failure rolls the whole unit back.

Duplicate command-receipt lookup remains first. A same-ID accepted start,
completion, or void retry returns its original durable receipt even after the
slot is released or the shift closes.

## Transaction context and time

New `transaction_started` Schema v2 events snapshot register ID/name, cashier
ID/name, shift ID, and `started_at_epoch_ms`. New completion and void Schema v2
events snapshot their terminal epoch milliseconds. All timestamps are exact
nonnegative UTC Unix epoch milliseconds recorded from one injected POS Core
clock. Replay never calls the clock.

These are trustworthy recorded operational facts, not a claim that the local
machine clock is tamper-proof, correctly configured, or legally certified.

Legacy Schema v1 starts and terminal events continue to replay with absent
operational context/time. A legacy open or paid transaction can finish without
retroactive attribution. New starts require a configured register and an open,
idle shift.

## HTTP and Flutter workflow

The operational API is deliberately narrow:

```text
GET  /register-context
GET  /cashiers
POST /shifts/open
POST /shifts/{shift_id}/close
GET  /shifts/{shift_id}/cash-summary
```

The connected Flutter home renders unconfigured, configured/no-shift, and
active-shift states only after authentication. With no shift it shows the safe
authenticated operator identity, accepts exact opening cash, and offers
`Open Shift`; it no longer fetches a cashier roster or allows another cashier
to be selected. `POST /shifts/open` contains only opening cash. Racket derives
the cashier ID from the authenticated operator and requires a matching active
cashier configuration.

An active shift owned by another operator is shown as register-in-use and is
not adopted for transaction work. Cashiers and supervisors close only their
own shifts; managers have an explicit close-any grant. For an open cashier-owned
shift, cash-summary serialization is limited and omits every financial value
that could reveal expected drawer cash. Read-any supervisors/managers and
closed reconciliations use the full representation. Backend enforcement remains
authoritative if Flutter presentation permissions are stale. See
[Authorization and Ownership](../security/authorization-and-ownership.md).

## Deliberately deferred

This model does not define manager approval, editable permission policy,
store/address identity, cash drops, paid-outs, refunds, manager variance
approval, drawer hardware, breaks, payroll/timeclock behavior, receipt
numbering, broad transaction search, or cloud employee synchronization.
