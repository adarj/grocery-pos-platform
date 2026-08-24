# ADR-0015: Derive canonical receipts from completed transaction replay

Status: Accepted

Date: 2026-08-23

## Context

The append-only transaction journal already owns historical sale truth.
Catalog and tax reference data are mutable, corrections change the final sold
basket through events, and completed transaction state is terminal. Persisting
another receipt snapshot would introduce synchronization and competing-authority
questions.

The current journal contains sale-time line facts, tender, completion, and
deterministic ordering, but it does not contain a trustworthy transaction
timestamp or store/register/cashier/shift context. Flutter must not derive
authoritative receipt truth from its presentation snapshot.

## Decision

Canonical customer sales receipts exist only for completed transactions. POS
Core derives them from authoritative transaction replay plus the final journal
stream version.

No materialized receipt table is introduced. Receipt lines are the final
retained transaction lines after correction events. Each line preserves its
sale-time barcode, description, exact unit price, nullable historical tax
category/rate, and exact stored line tax. Receipt subtotal, tax, total, cash
tender, and change come directly from the transaction projection.

Receipt Schema v1 uses the exact transaction ID as its durable lookup reference
and includes the final transaction stream version. It contains no generated
receipt ID, status field, fabricated timestamp, or store/register/cashier/shift
metadata.

`GET /receipts/{transaction_id}` provides exact read-only lookup. Open, paid,
and voided transactions have no canonical customer sales receipt. Flutter uses
the typed query and renders the returned fields; it does not copy its cashier
snapshot into a receipt.

## Consequences

### Positive

- Journal replay remains the single source of historical transaction truth.
- Old receipts survive catalog and tax replacement without current reference
  lookup.
- Removed lines are absent from the customer receipt while correction history
  remains in the journal.
- Receipt lookup remains deterministic across POS Core restart.
- No receipt-projection synchronization or migration is required.
- Exact transaction-ID lookup is available immediately.
- Physical delivery can evolve independently from canonical receipt truth.

### Negative

- Receipt reads currently replay the transaction stream rather than using a
  query projection.
- Exact IDs are not a cashier-friendly receipt-number sequence.
- Recent/date-based search is unavailable without trustworthy indexed
  operational metadata.
- Receipt Schema v1 cannot display a sale date, register, or cashier.

## Alternatives Considered

### Materialize a receipt table at completion

Rejected because it duplicates facts already owned by the journal and creates
a second state that must remain synchronized with transaction truth.

### Derive the receipt in Flutter

Rejected because Flutter owns presentation, not historical pricing, tax,
tender, correction, or receipt meaning.

### Re-query current catalog and tax data

Rejected because mutable reference data would rewrite historical sale facts.

### Issue a sales receipt at paid state or for a void

Rejected because the current sale lifecycle completes only after
`transaction_completed`, while a void is a cancelled pre-payment basket.

### Fabricate a query-time timestamp

Rejected because it would describe receipt lookup time rather than sale time.

### Add broad transaction search/indexing now

Deferred until register, cashier, shift, trustworthy temporal metadata, and
real search requirements exist.

## Scope

This decision does not define physical printing, receipt number sequences,
date/time, store identity/address, cashier/register/shift identity, refunds or
returns, reprint audits, electronic delivery, cloud archives, or legal/fiscal
receipt compliance.

## Subsequent evolution

[ADR-0016](0016-snapshot-register-cashier-shift-and-operational-time.md) later
introduced explicit operational event facts for new transactions. Completed
context-bearing transactions now derive Receipt Schema v2 with their recorded
register, cashier, shift, start time, and completion time. This does not revise
the original v1 decision: legacy transactions retain the exact context-free
Receipt Schema v1, and both versions are still derived from replay without a
materialized receipt table.
