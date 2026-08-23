# Local Catalog

## Purpose

The local catalog answers one checkout-time question:

> What should this new barcode scan mean now?

It does not answer what a historical sale meant. An accepted
`sale-item-added` transaction event snapshots the scanned barcode, description,
exact unit price, and (for new Schema v2 lines) the exact tax decision at
decision time. Transaction replay uses those stored facts and never queries the
current catalog.

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

tax_categories
--------------
tax_category_id            TEXT PRIMARY KEY
description                TEXT
rate_millionths            INTEGER

catalog_item_tax_categories
---------------------------
item_id                    TEXT PRIMARY KEY
tax_category_id            TEXT
```

`item_id` is a non-empty opaque internal merchandise identifier. It is not
derived from a barcode and has no required UUID syntax. A barcode is a
non-empty, opaque, exact scannable identifier. It is stored as text, so leading
zeroes and every other character remain significant. One item can have more
than one assigned barcode, while each barcode maps to at most one item.

The separation prevents barcode identity from becoming merchandise identity.
It also leaves room for later barcode assignment changes without redefining
historical transaction facts.

## Price and Checkout Availability

`unit_price_minor_units` is the item's one current checkout price. SQLite must
store it as an exact nonnegative integer. The repository converts that integer
directly to the existing Racket `money` value; it performs no floating-point or
decimal-text conversion. Zero is a valid deliberate price.

There is no price-history or effective-date model yet. Historical prices do not
need the current catalog to retain meaning because sale events already contain
their sale-time price.

Migration 4, `create_tax_categories`, layers one current tax category onto each
item without changing migration-3-owned tables. Category IDs are opaque
non-empty text. Rates are exact integer millionths of one from `0` through
`1,000,000`; no floating-point or jurisdiction-specific rate is embedded in
production code. A zero-rate category is explicit exempt/untaxed treatment.

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
- the current exact unit price;
- the current tax category ID and exact typed rate.

An unknown barcode or a barcode assigned to an inactive item returns `#f`.
Database failures, missing tables, invalid stored primitives, orphan barcode
assignments, missing item-tax mappings, and missing categories are
integrity/infrastructure failures and are allowed to propagate. The repository
never turns corruption into a free or zero-tax item or an ordinary catalog
miss.

## Catalog Snapshot Schemas v1 and v2

Catalog activation accepts one strict, versioned JSON document:

```json
{
  "schema_version": 1,
  "items": [
    {
      "item_id": "item-apples",
      "description": "Test Apples",
      "unit_price_minor_units": 199,
      "active": true
    }
  ],
  "barcodes": [
    {
      "barcode": "049000001234",
      "item_id": "item-apples"
    }
  ]
}
```

This is a complete current-catalog snapshot, not a patch. Its root, item, and
barcode objects accept exactly the documented fields. The strict decoder
rejects malformed JSON, duplicate object members, unsupported schema versions,
wrong primitive types, empty identifiers/descriptions, negative or noninteger
prices, duplicate item IDs/barcodes, and barcode references to items outside
the same staged document. It preserves strings exactly and requires JSON
booleans for `active`.

The successfully decoded value is a purpose-built immutable staged model.
Schema v1 remains supported with permanent compatibility semantics: all of its
items normalize to the reserved `__legacy_zero_tax__` category at rate zero.
It is never reinterpreted using a later default tax rate.

Schema v2 adds exact `tax_categories` at the root and a required
`tax_category_id` on every item:

```json
{
  "schema_version": 2,
  "tax_categories": [
    {
      "tax_category_id": "development-standard",
      "description": "Development Standard Tax",
      "rate_millionths": 100000
    }
  ],
  "items": [
    {
      "item_id": "item-apples",
      "description": "Test Apples",
      "unit_price_minor_units": 199,
      "active": true,
      "tax_category_id": "development-standard"
    }
  ],
  "barcodes": [
    {"barcode": "049000001234", "item_id": "item-apples"}
  ]
}
```

V2 rejects duplicate categories, invalid rates, and item references to missing
categories. Unused categories remain valid. The concise summary includes item,
active-item, inactive-item, barcode, and tax-category counts. Development
fixture rates are test data, not legal tax configuration.

## Atomic Activation and Referential Integrity

The production write boundary is:

```racket
(activate-catalog-snapshot! connection snapshot)
```

It receives only a fully validated typed snapshot. One SQLite
`BEGIN IMMEDIATE` transaction deletes barcode and tax assignments, items, and
categories in dependency order; inserts categories, items, item-tax mappings,
and barcodes; verifies counts, one mapping per item, and the absence of
orphans; and commits. Any
failure rolls the whole operation back, so the previous catalog remains live.
After commit, the database catalog is exactly the supplied snapshot; omitted
rows are gone.

SQLite readers observe a consistent state from before or after the commit, not
a half-replaced set. A scan that already read the old catalog can finish its
decision after activation commits. Its accepted event records the merchandise
facts that Racket actually observed for that decision.

Write-time reference integrity is currently application-enforced by complete
staged validation plus the single atomic activation boundary. All items are
inserted before assignments, and activation verifies that no orphan or unmapped
item exists. The lookup path independently fails closed on corrupt merchandise
or tax data.

Ordinary Racket SQLite connections currently report
`PRAGMA foreign_keys = 0`, and runtime composition does not yet enable that
connection-local setting consistently. Migration 3 therefore does not declare
a foreign key that would appear enforced while actually being disabled.

No arbitrary row-at-a-time production catalog write API is exposed. Enabling
foreign keys consistently on every connection and adding a corresponding
enforcing migration remains separate database hardening work.

## Runtime Composition

The production runtime uses `lookup-catalog-item-by-barcode` over its existing
bounded pool and virtual SQLite connection. It does not open a connection per
scan, seed catalog data on startup, or fall back to the development fake
catalog. A fresh migrated database therefore has an empty checkout catalog
until an operator explicitly activates a snapshot.

`fake-catalog-lookup` remains only as focused test support. The versioned Test
Apples JSON snapshot is a development/integration fixture, not a production
default.

## Operator Workflow

From the repository root:

```bash
just catalog-validate path/to/catalog.json
just catalog-activate path/to/catalog.json /explicit/path/to/pos.db
```

Validation performs no database work and prints concise counts. Activation
strictly decodes and validates the complete file before opening the explicitly
selected database, runs the normal database migration path, then replaces the
catalog atomically. The database parent directory must already exist. Runtime
startup never activates or rewrites a catalog automatically.

Because activation replaces mutable checkout reference data, operators should
prefer doing it between customer transactions where practical.

## Catalog Changes and Command Retry

A same-ID retry of a scan with an existing durable command receipt returns its
original outcome before transaction replay or catalog lookup. Activating a new
catalog cannot reprice, redescribe, or retax that known command, and its
accepted event exists exactly once.

A different boundary applies when Flutter preserved a scan command but POS
Core never durably decided it. No sale-time price/tax facts exist yet. Its
same-ID retry can perform the command's first catalog lookup later and is
decided using the price, category, and rate active when Racket evaluates it.
This preserves
at-most-once command application, but command identity does not freeze mutable
reference data before the backend makes a durable decision.

Flutter does not send price, category, or rate and never becomes catalog or
transaction authority. Catalog generations/effective pricing require a future
explicit design if stronger timing semantics become necessary.

## Deliberately Deferred

This foundation does not implement:

- catalog administration or HTTP routes;
- CSV import or cloud synchronization;
- departments, categories, brands, sizes, suppliers, or costs;
- inventory quantities or movements;
- promotions or discounts;
- multiple/compound jurisdictions or statutory tax configuration;
- PLUs or weighted-item metadata;
- price history or scheduled pricing.

No catalog foreign reference is added to historical transaction events.

See [ADR-0012](../adr/0012-use-atomic-local-catalog-snapshot-for-checkout-reference-data.md)
and [ADR-0013](../adr/0013-snapshot-exact-line-tax-in-transaction-events.md)
for the durable architectural decisions.
