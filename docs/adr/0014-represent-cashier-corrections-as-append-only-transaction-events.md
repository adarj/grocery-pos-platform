# ADR-0014: Represent cashier corrections as append-only transaction events

Status: Accepted

Date: 2026-08-23

## Context

Cashiers need to correct accidental scans and cancel an open sale. The
transaction journal is append-only truth, so a correction cannot delete or
rewrite an accepted `sale_item_added` fact. Flutter cannot edit the
authoritative basket. Repeated identical items also make barcode-based removal
ambiguous, while correction commands must retain the same crash-safe,
idempotent retry behavior as every other transaction mutation.

Pre-payment cancellation is distinct from reversing or refunding a paid sale.
The current system has no employee/manager authorization model for either
operation.

## Decision

Transaction Command Schema v1 includes two additional typed commands:

- `remove_line_item` carries a zero-based `line_index` and caller-supplied
  expected stream version;
- `void_transaction` carries an empty payload.

Line position refers to the authoritative transaction state at the expected
version. POS Core verifies stream version before interpreting the index, so an
old selection cannot be retargeted against a newer basket. An accepted removal
appends a Schema v1 `sale_line_removed` event. Applying it removes exactly that
position and its already-stored base-price and tax contribution while
preserving remaining order. It performs no catalog or current-tax lookup.

An accepted void is allowed only from open state and appends a Schema v1
`transaction_voided` event. Applying it produces the terminal `voided` status.
The cancelled line list, subtotal, tax, and total remain in the authoritative
projection for inspection; tender and change remain absent. Those descriptive
totals are not completed revenue.

No correction deletes or rewrites an earlier event. Both commands use the
existing durable command receipt, expected-version check, atomic unit of work,
and exact same-ID retry protocol. Flutter persists the exact command before
POST and waits for authoritative GET before changing the visible basket or
status. Backend-reported `completed` and `voided` are both safe local-session
endpoints from which an explicit Next Sale can clear the old recovery record
and create a new start intent.

## Consequences

### Positive

- The complete correction history remains auditable and replayable.
- Same-ID removal retry cannot remove the line that shifted into the old index.
- Expected-version enforcement makes a positional selector unambiguous.
- Catalog and tax changes cannot alter a correction to stored sale-time facts.
- Flutter remains presentation/orchestration rather than transaction truth.
- A cancelled basket remains inspectable after restart.

### Negative

- Zero-based indices are safe only when coupled to expected stream version.
- A cashier must reselect after any authoritative state change while a
  confirmation is open.
- Voided totals require future reporting to distinguish descriptive cancelled
  value from revenue.
- Pre-payment correction currently has no manager authorization or reason code.

## Alternatives Considered

### Delete or rewrite `sale_item_added` events

Rejected because it would violate append-only transaction truth and erase the
accepted history needed for deterministic replay and audit.

### Remove a row optimistically in Flutter

Rejected because only POS Core can accept the correction and only an
authoritative transaction read can establish the resulting basket and totals.

### Address removal by barcode or product values

Rejected because identical repeated scans are distinct lines and such a
selector could remove the wrong occurrence.

### Add synthetic historical line IDs now

Deferred because expected-version-bound position provides an unambiguous,
minimal selector without retrofitting existing event schemas.

### Allow void after payment

Rejected for this correction workflow. Reversals and refunds have distinct
payment, cash-accountability, tax, receipt, inventory, authorization, and
unknown-external-effect requirements.

### Clear the basket when voiding

Rejected because the cancelled merchandise and monetary projection are useful
authoritative context and the journal should not pretend the scans never
occurred.

## Scope

This decision does not define quantity adjustment, manager approval, correction
reason codes, post-payment void, refund/return, receipt void markers, inventory
movement reversal, cloud synchronization, or accounting/reporting treatment
beyond retaining an explicit voided status and descriptive projection.
