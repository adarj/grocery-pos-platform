# ADR-0013: Snapshot exact line tax in transaction events

Status: Accepted

Date: 2026-08-22

## Context

Checkout tax must work from local reference data when cloud services are
unavailable. Tax categories and rates can change, but historical transaction
totals must not change when they do. Rounding must be deterministic, Flutter
must not become tax authority, and existing journals already contain
Transaction Event Schema v1 sale lines with no tax fields.

The current catalog supplies one base unit price for each item. This checkpoint
needs a deliberately bounded tax model, not a universal jurisdiction engine.

## Decision

The local SQLite catalog supplies each current item with one opaque tax category
and an exact integer rate in millionths of one. Valid rates are from `0` through
`1,000,000` inclusive. Racket calculates tax for each scanned line using exact
integer half-up rounding:

```text
line_tax_minor_units =
  quotient(price_minor_units * rate_millionths + 500000, 1000000)
```

Transaction tax is the sum of stored line tax amounts. Transaction subtotal is
the sum of base line prices, and transaction total is subtotal plus tax. Tender
sufficiency and change therefore use the tax-inclusive total.

New taxed scans produce `sale_item_added` events using Transaction Event Schema
v2. The event snapshots sale-time barcode, description, unit price, tax category
ID, rate millionths, and exact calculated tax amount. The v2 decoder validates
the stored tax against this fixed algorithm. Replay uses the stored tax amount
and never queries current catalog or tax tables.

Existing Schema v1 `sale_item_added` events retain their exact representation
and mean zero tax. A stream may contain both legacy v1 lines and new v2 lines.
Other existing event types remain Schema v1.

Racket owns tax decisions. The transaction query exposes authoritative tax as
integer minor units, and Flutter only parses and renders that value.

## Mutable Reference Data and Command Retry

ADR-0011 receipt recovery still precedes replay and catalog lookup. Retrying an
already resolved scan with the same command ID returns its original receipt,
does not re-evaluate current price or tax, and cannot append another line.

If no durable outcome exists yet, the command's first eventual Racket decision
uses the price, tax category, and rate active when Racket evaluates it. Command
identity does not freeze mutable reference data in Flutter. Operators should
prefer catalog/tax activation between customer transactions.

## Consequences

### Positive

- Tax is exact, local, deterministic, and restart-safe.
- Current tax changes cannot rewrite historical sale totals.
- Old untaxed journals remain valid without migration or catalog lookup.
- Per-line rounding is explicit and supports different categories per line.
- Flutter remains a presentation client rather than tax authority.

### Negative

- Individually rounded lines can differ by a cent from aggregate rounding.
- The v2 formula is a durable compatibility rule; a different algorithm needs
  deliberate event-schema evolution.
- One combined category/rate does not model multiple or compounded taxes.
- An unresolved scan does not carry a frozen catalog/tax generation.

## Alternatives Considered

### Calculate tax in Flutter

Rejected because clients must not become pricing or transaction authority.

### Calculate historical tax from the current catalog at query time

Rejected because mutable reference data would rewrite old sale meaning and
make replay depend on current catalog availability.

### Store only the rate and recalculate on replay

Rejected because the exact rounded monetary decision is the historical fact.

### Round one transaction-level rate

Rejected because lines can have different tax categories and the result would
not preserve the current per-scan decision boundary.

### Use floating-point rates or money

Rejected because binary floating point cannot provide the required exact
monetary semantics.

### Rewrite Schema v1 events

Rejected because persisted history is append-only and its existing meaning
must remain stable.

## Scope

This decision does not establish statutory compliance for any jurisdiction. It
does not implement tax-inclusive shelf pricing, multiple stacked jurisdictions,
compound tax, tax holidays, effective dates, customer exemptions, overrides,
returns/refunds tax, weighted-item tax, promotions, or discounts.
