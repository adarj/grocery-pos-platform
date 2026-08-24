# ADR-0012: Use an atomic local catalog snapshot for checkout reference data

Status: Accepted

Date: 2026-08-22

## Context

Checkout must interpret merchandise locally when the cloud is unavailable.
The development fake catalog cannot serve as register reference data, while
direct row-at-a-time updates could expose a partially imported catalog.

Current merchandise descriptions and prices are mutable reference data. They
are not historical transaction truth. Replaying an accepted sale must retain
the barcode, description, and price observed when that sale was decided even
after the current catalog changes. Internal merchandise identity also differs
from scannable barcode identity: one item can have multiple barcodes, and a
barcode assignment can change without redefining old sales.

## Decision

SQLite's normalized `catalog_items` and `catalog_barcodes` tables are the local
checkout-time authority for current merchandise. Racket production runtime
looks up active barcode assignments from those tables through its existing
bounded connection pool. Flutter neither supplies merchandise facts nor owns
catalog interpretation.

Catalog Snapshot Schema v1 is a strict JSON full-snapshot format. The decoder
rejects malformed or ambiguous JSON, unexpected/missing fields, invalid
primitive values, duplicate identities, and references to items outside the
same snapshot. A valid document becomes an immutable staged model before any
database work occurs.

Activation replaces both current catalog tables in one SQLite
`BEGIN IMMEDIATE` transaction. It deletes assignments and items, inserts all
validated items before assignments, verifies counts and the absence of
orphans, and commits. Any failure rolls back to the previous complete catalog.
This is a full replacement, not a patch protocol.

Write-time referential integrity is enforced by complete staged validation and
the single activation boundary. The read repository independently fails closed
if external/manual corruption creates an orphan. We do not declare a SQLite
foreign key while connection-wide foreign-key enforcement is disabled.

Accepted `sale-item-added` events continue to snapshot the scanned barcode,
description, and exact integer price. Transaction replay never queries the
current catalog and stores no catalog foreign reference in place of those
facts.

## Command Identity and Mutable Reference Data

ADR-0011's durable same-ID retry semantics remain unchanged. If a scan already
has a durable receipt, retry returns the original outcome before any current
catalog lookup and cannot duplicate or reinterpret the accepted sale fact.

If a scan command has not been durably decided, a later same-ID retry can
perform its first real catalog lookup after a catalog activation. It is then
decided using the reference data active when Racket evaluates it. Command
identity guarantees at-most-once application; it does not freeze mutable
catalog facts before the backend has durably made a decision. Operators should
prefer activation between customer transactions where practical.

## Consequences

### Positive

- Checkout reference data is local and does not require cloud availability.
- An invalid or failed import leaves the previous complete catalog usable.
- Current descriptions/prices can change without rewriting sale history.
- Item identity and barcode assignment remain separate.
- Durable command retries remain stable across catalog replacement.
- The production runtime no longer embeds development merchandise.

### Negative

- Initial catalog import is full replacement rather than incremental update.
- Catalog activation must be operationally coordinated; an already-started
  decision may observe the prior snapshot.
- Application-enforced references rely on catalog writes staying behind the
  narrow activation boundary until connection-wide foreign keys are designed.
- An unresolved command does not carry a catalog generation or frozen price.

## Alternatives Considered

### Keep the fake/in-memory catalog in production

Rejected because it is not durable or operationally configurable.

### Make Flutter own or send catalog merchandise facts

Rejected because Racket owns pricing and transaction meaning, and clients must
not become authoritative for sale facts.

### Apply row-at-a-time live updates

Rejected because readers could observe a partial import and failed imports
would require complex repair semantics.

### Store only `item_id` in transaction events

Rejected because historical replay would depend on mutable current reference
data and could silently change old sales.

### Declare a foreign key without enabling enforcement on every connection

Rejected because it would document an invariant SQLite was not actually
enforcing.

## Scope

This decision covers current local item/barcode reference data and exact
current prices. It does not decide inventory quantities, tax categories,
promotions, effective-dated pricing, catalog generations, weighted items,
cloud synchronization, or catalog administration APIs.

Tax categories and sale-time tax snapshotting were subsequently decided in
[ADR-0013](0013-snapshot-exact-line-tax-in-transaction-events.md) without
changing this full-snapshot/reference-data boundary.
