# Local Catalog Foundation

## Purpose

The local catalog answers one checkout-time question:

> What should this new barcode scan mean now?

It does not answer what a historical sale meant. An accepted
`sale-item-added` transaction event snapshots the scanned barcode, description,
and exact unit price at decision time. Transaction replay uses those stored
facts and never queries the current catalog.

```text
new scan
  -> current catalog lookup
  -> sale-time facts in transaction event

historical replay
  -> stored transaction events only
```

This preserves the append-only transaction journal as authoritative sale
truth while allowing current merchandise data to change independently.

## Persistent Model

Database migration 3, `create_catalog`, adds two normalized tables:

```sql
catalog_items
-------------
item_id                    TEXT PRIMARY KEY
description                TEXT
unit_price_minor_units     INTEGER
active                     INTEGER

catalog_barcodes
----------------
barcode                    TEXT PRIMARY KEY
item_id                    TEXT
```

`item_id` is a non-empty opaque internal merchandise identifier. It is not
derived from a barcode and has no required UUID syntax. A barcode is a
non-empty, opaque, exact scannable identifier. It is stored as text, so leading
zeroes and every other character remain significant. One item can have more
than one assigned barcode, while each barcode maps to at most one item.

The separation prevents barcode identity from becoming merchandise identity.
It also leaves room for later barcode assignment changes without redefining
historical transaction facts.

## Price and Activation

`unit_price_minor_units` is the item's one current checkout price. SQLite must
store it as an exact nonnegative integer. The repository converts that integer
directly to the existing Racket `money` value; it performs no floating-point or
decimal-text conversion. Zero is a valid deliberate price.

There is no price-history or effective-date model yet. Historical prices do not
need the current catalog to retain meaning because sale events already contain
their sale-time price.

`active` is a strict SQLite integer with value `0` or `1`:

- `1`: an assigned barcode can resolve for a new checkout scan;
- `0`: checkout lookup returns `#f`, with the same transaction behavior as an
  unknown barcode.

Inactive items therefore continue to produce the existing durable
`unknown_barcode` domain rejection rather than adding a second transaction
outcome solely for catalog administration state.

## Checkout Repository

The SQLite adapter exposes one read operation:

```racket
(lookup-catalog-item-by-barcode connection barcode)
```

It accepts an existing database connection or virtual connection. It does not
open a connection per scan and performs no catalog or transaction write. A
known active barcode returns a domain `catalog-item` containing:

- the exact barcode supplied by the scan;
- the current stored description;
- the current exact unit price.

An unknown barcode or a barcode assigned to an inactive item returns `#f`.
Database failures, missing tables, invalid stored primitives, and an orphan
barcode assignment are integrity/infrastructure failures and are allowed to
propagate. The repository never turns corruption into a free item or an
ordinary catalog miss.

## Referential Integrity at This Checkpoint

Ordinary Racket SQLite connections currently report
`PRAGMA foreign_keys = 0`, and runtime composition does not yet enable that
connection-local setting consistently. Migration 3 therefore does not declare
a foreign key that would appear enforced while actually being disabled.

The read repository uses an integrity-sensitive left join so an orphan barcode
assignment fails closed instead of behaving like an unknown barcode. The
catalog population/runtime-cutover checkpoint must establish a consistent
write-time referential-integrity policy before exposing catalog writes.

## Runtime Status

Checkpoint 1 supplies the database schema, strict migration validation, and
authoritative read repository. The production runtime intentionally continues
to inject `fake-catalog-lookup`, including the Test Apples development fixture.
Persistent catalog rows do not affect live checkout yet.

The next checkpoint will add controlled catalog population/activation, define
the write-time integrity policy, switch runtime checkout to the SQLite lookup,
and update cross-stack fixtures accordingly.

## Deliberately Deferred

This foundation does not implement:

- catalog administration or HTTP routes;
- CSV import or cloud synchronization;
- departments, categories, brands, sizes, suppliers, or costs;
- inventory quantities or movements;
- tax categories or promotion data;
- PLUs or weighted-item metadata;
- price history or scheduled pricing.

No catalog foreign reference is added to historical transaction events.
