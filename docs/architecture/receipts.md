# Canonical Completed-Sale Receipts

## Purpose and authority

A canonical sales receipt is a read-only artifact derived from authoritative
transaction truth:

```text
SQLite transaction journal
  -> strict event decode
  -> deterministic Racket replay
  -> completed transaction projection + final stream version
  -> canonical receipt
```

There is no `receipts` or `receipt_lines` table. Receipt generation does not
query the current catalog, tax tables, or command receipts for merchandise
facts. The transaction journal remains the sole historical sale authority, as
recorded in [ADR-0015](../adr/0015-derive-canonical-receipts-from-completed-transaction-replay.md).

## Eligibility

A canonical customer sales receipt exists only when replay reports transaction
status `completed`.

- `open`: the sale is still mutable;
- `paid`: cash has been accepted, but the current lifecycle has not completed;
- `voided`: the open sale was cancelled and is not completed revenue.

Those states return `receipt_not_available`, not a partially fabricated sales
receipt. A void/correction audit record and a future refund receipt are separate
artifacts.

## Receipt Schema v1

The local API returns:

```json
{
  "schema_version": 1,
  "transaction_id": "txn_...",
  "transaction_version": 6,
  "line_items": [
    {
      "barcode": "049000001234",
      "description": "Test Apples",
      "unit_price_minor_units": 199,
      "tax_category_id": "development-standard",
      "tax_rate_millionths": 100000,
      "tax_amount_minor_units": 20
    }
  ],
  "subtotal_minor_units": 199,
  "tax_minor_units": 20,
  "total_minor_units": 219,
  "tendered_cash_minor_units": 500,
  "change_due_minor_units": 281
}
```

`transaction_id` is the durable sale and receipt reference in Schema v1. No
second random receipt ID exists. `transaction_version` is the final journal
stream version used to build the receipt, not a command outcome version.

All money is exact integer minor units. Tax rates are exact integer millionths.
Receipt generation uses the transaction projection's subtotal, tax, total,
tender, and change. It does not recalculate tax, infer tender, or query current
reference data.

Historical Transaction Event Schema v1 sale lines have no tax category or rate.
Their receipt lines contain JSON null for `tax_category_id` and
`tax_rate_millionths`, with `tax_amount_minor_units` equal to zero. No category
is invented retroactively.

## Corrections and line order

Receipt lines are the final retained transaction lines after replaying every
append-only correction event. For example:

```text
add Apples
add Bread
add Milk
remove Bread
add Eggs
complete
```

produces receipt lines `Apples`, `Milk`, `Eggs` in that order. The journal still
contains both the Bread add and removal facts for audit/replay. The ordinary
customer receipt does not include a removed-items section.

Repeated identical scans remain separate receipt lines. Schema v1 performs no
quantity grouping.

## Mutable catalog and tax data

Every retained line comes from its historical sale event. Description, barcode,
unit price, tax category, rate, and exact rounded tax therefore remain stable
after current catalog or tax activation changes. Receipt lookup works even when
current catalog lookup is unavailable.

This is distinct from an unresolved scan command. Until POS Core durably decides
that command, mutable reference data is not frozen; after the sale fact is
accepted, receipt replay always uses the stored fact.

## Exact lookup API

Receipt lookup is exact and read-only:

```text
GET /receipts/{transaction_id}
```

It has no command ID, expected version, mutation retry protocol, or Flutter
cashier recovery-store entry. Explicitly repeating a failed GET is safe.

The Flutter connected gateway exposes `Lookup Completed Sale`, and an
authoritative completed cashier state exposes `View Receipt`. Both use the
typed receipt query. Flutter does not copy its transaction snapshot into a
receipt or reconstruct monetary consistency.

## Deliberate timestamp and search limitation

The current journal contains no trustworthy completion timestamp. Receipt
Schema v1 therefore has no `completed_at`, date, or time field. It does not use
query time, SQLite row ID, filesystem metadata, or command retry time as a fake
sale timestamp.

Only exact transaction-ID lookup is implemented. Recent-sale, date-range,
cashier, amount, item, receipt-number, and paginated searches wait for durable
operational metadata and indexing.

## Deliberately deferred

The canonical on-screen artifact is not a claim of legal or fiscal receipt
compliance. This checkpoint does not implement:

- physical printing, ESC/POS, PDF, email, or SMS delivery;
- human receipt-number sequences;
- timestamps or store/register/cashier/shift metadata;
- refund/return receipts or void receipts;
- reprint audit counters;
- cloud receipt archives.
