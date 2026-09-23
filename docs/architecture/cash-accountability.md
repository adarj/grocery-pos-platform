# Shift Cash Accountability

## Authority and purpose

POS Core owns drawer-accounting meaning. Flutter accepts exact human-entered
opening and closing counts and renders backend results; it never calculates
expected cash or over/short.

The transaction journal and shift cash ledger have different authority:

```text
transaction journal
  -> what was sold, paid, corrected, voided, and completed

shift cash ledger
  -> expected physical cash movement attributable to the shift
```

A completed cash sale movement is derived from authoritative transaction truth
and committed in the same SQLite writer transaction as completion. The cash
ledger is not an alternative receipt, revenue, or transaction database.

## Migration v6 and durable records

Migration `6`, `create_shift_cash_accountability`, adds the append-only
`shift_cash_movements` table and immutable
`shift_cash_reconciliations` table. Current movement types are deliberately
limited to:

- `opening_float`, with sequence 1 and no transaction ID;
- `cash_sale`, with an exact transaction ID.

Movement amounts are exact nonnegative integer minor units. Sequence is unique
within a shift. Partial unique indexes enforce at most one opening movement per
shift and at most one cash-sale movement per transaction. Type/transaction-ID
shape is also constrained in SQLite.

One reconciliation row per shift stores exact expected and counted cash plus a
signed `over_short_minor_units`. It does not duplicate the shift close time;
`register_shifts.closed_at_epoch_ms` remains the operational close instant.

Migration v6 never fabricates financial facts. A frozen v5 database containing
an open shift fails migration with operational guidance to close that shift
under the pre-v6 software. Closed v5 shifts upgrade without synthetic movements
or reconciliation and return `cash_accounting_unavailable` when queried.

## Opening a tracked shift

`POST /shifts/open` requires only exact nonnegative
`opening_cash_minor_units`; POS Core derives the cashier ID from the
authenticated operator and active same-ID cashier configuration. One
`BEGIN IMMEDIATE` creates the shift row and its sequence-1 opening movement
with the same POS-Core-recorded epoch-millisecond timestamp. Either both become
durable or neither does.

A repeated same-cashier open resolves the existing shift; its HTTP cash-summary
view remains permission-scoped. It neither appends another opening movement nor
changes the first accepted opening amount, even when the repeated request
supplies a different value. Opening cash is immutable in this checkpoint.

## Completed sale movements

No movement is recorded for an open or paid transaction. Completion remains
the finalized cash-sale boundary. For a context-bearing current transaction,
one writer transaction commits:

```text
transaction_completed event
+ cash_sale movement
+ release exact shift active-transaction slot
+ durable command receipt
```

The movement amount is authoritative `transaction-total`, including tax and
after retained-line corrections. It is not tendered cash. For example, a
`219` total tendered with `500` and returning `281` change grows the drawer by
`219`. The movement uses the same exact `completed_at_epoch_ms` as the terminal
event; the clock is not called twice.

A void appends no cash movement and releases the slot atomically with its event
and command receipt after its separate Supervisor / Manager Approval has been
validated and consumed inside the same writer transaction. The cashier remains
the command actor; see [Scoped Approval](../security/scoped-manager-approval.md).
A zero-total completed sale appends a zero-valued movement
and therefore still counts as one completed cash sale. Durable same-command
completion retry returns the original command receipt before operational
effects and cannot append a second movement; transaction-linked uniqueness is
additional defense.

## Expected cash and strict recovery

For a tracked shift:

```text
cash_sales    = sum(cash_sale movement amounts)
expected_cash = opening_float + cash_sales
sale_count    = count(cash_sale movements)
```

Loading a summary validates one opening movement, contiguous sequences,
supported types, unique transaction links, and each sale movement against its
completed transaction journal, shift context, total, and completion timestamp.
A stored reconciliation must agree with the ledger and its shift lifecycle.
Corrupt financial state fails closed; it is never repaired or treated as zero.

`GET /shifts/{shift_id}/cash-summary` exposes exact backend values. Open
summaries have null counted/variance fields. Closed summaries contain the
immutable reconciliation.

## Reconcile and close

Close requires an independently observed exact nonnegative physical count:

```json
{ "counted_cash_minor_units": 14194 }
```

Inside one `BEGIN IMMEDIATE`, POS Core verifies the shift is idle, validates the
ledger, calculates exact expected cash, records:

```text
over_short = counted_cash - expected_cash
```

Before a cashier submits that independent count, Racket returns only a limited
open-own-shift view containing shift identity and status. It does not send
opening cash, sale totals, expected cash, counted cash, or over/short. A
supervisor or manager with read-any may receive the full open summary. After
close, the owner may receive the full immutable reconciliation. This blind-count
boundary is enforced by serialization, not by hiding already-returned fields in
Flutter. See [Authorization and Ownership](../security/authorization-and-ownership.md).

then inserts the reconciliation and closes the shift. All changes commit or
roll back together. A nonzero variance is preserved honestly and does not
block closure. Repeated close returns the first durable reconciliation without
rewriting it, even if the repeated request supplies another count.

Open/close are operational resource writes, not Transaction Command Schema
commands. After an uncertain response Flutter explicitly reads register state
and the exact shift cash summary; it does not automatically retry the write or
persist a second financial truth.

## Current limits

The formula covers only opening float plus completed cash sales. Cash drops,
paid-outs, refunds, manual additions/removals, manager variance approval,
drawer hardware, inventory accounting, reports, deposits, general-ledger
export, employee authentication, and statutory cash-control compliance are not
implemented. Each future physical-cash operation needs its own explicit
durable movement semantics.
