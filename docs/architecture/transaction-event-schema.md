# Transaction Event Schema v1

## Status

Transaction Event Schema v1 defines the stable JSON representation of the
currently implemented cash-sale transaction domain events.

It covers event payload serialization only. It does not define a SQLite
journal table or persisted journal-record envelope.

## Purpose

The local POS Core uses immutable Racket structs for domain behavior and
deterministic replay. Durable event data must use an explicit,
language-independent representation instead of Racket printed or prefab struct
syntax.

The boundary is:

```text
Racket transaction domain event
    -> Transaction Event Schema v1 JSON
    -> SQLite persisted journal record
```

On recovery the direction reverses:

```text
persisted JSON
    -> strict schema validation
    -> Racket transaction domain event
    -> pure transaction replay
```

JSON object field order is not significant. Field names, field presence,
field types, event-type strings, and schema-version numbers are significant.

## Domain events and journal records

A domain event records an accepted business fact such as an item being added
or sufficient cash being tendered. This document defines the serialized type
and payload for those facts.

The SQLite journal record wraps that serialized event with storage metadata.
The implemented envelope contains a SQLite row identifier, transaction stream
key, per-stream sequence, and duplicated schema-version and event-type fields.
Event identifiers, recording timestamps, command identifiers, and integrity
information remain deferred. Envelope values are not domain-event payload
fields and are not part of Schema v1.

The `transaction_started` payload contains `transaction_id` because the domain
fact needs it to reconstruct transaction identity. The journal envelope also
contains the transaction stream key and validates that the two identifiers
agree.

## Common shape

Every Schema v1 event is a JSON object with exactly these fields:

```json
{
  "schema_version": 1,
  "event_type": "event_type_name",
  "payload": {}
}
```

- `schema_version` is the exact JSON integer `1`.
- `event_type` is one of the four strings defined below.
- `payload` is an object with the exact shape defined for that event type.
- Persisted names use `snake_case`; Racket domain identifiers use hyphens.

## Event types

### `transaction_started`

```json
{
  "schema_version": 1,
  "event_type": "transaction_started",
  "payload": {
    "transaction_id": "txn-001"
  }
}
```

Payload fields:

- `transaction_id`: string containing the externally supplied transaction
  identifier.

### `sale_item_added`

```json
{
  "schema_version": 1,
  "event_type": "sale_item_added",
  "payload": {
    "barcode": "049000001234",
    "description": "Test Apples",
    "unit_price_minor_units": 199
  }
}
```

Payload fields:

- `barcode`: string preserving identifier and leading-zero semantics;
- `description`: string containing the accepted sale-time description;
- `unit_price_minor_units`: exact nonnegative integer sale-time unit price.

The sale-time snapshot makes replay independent of the current catalog.

### `cash_tendered`

```json
{
  "schema_version": 1,
  "event_type": "cash_tendered",
  "payload": {
    "amount_minor_units": 500
  }
}
```

Payload fields:

- `amount_minor_units`: exact nonnegative integer accepted cash amount.

The payload does not store total or change due. Those remain derived domain
values during replay.

### `transaction_completed`

```json
{
  "schema_version": 1,
  "event_type": "transaction_completed",
  "payload": {}
}
```

The payload must be empty. Completion status is derived by applying this event
to a paid transaction.

## Money representation

All money uses exact integer minor units:

```text
$1.99 -> 199
$5.00 -> 500
```

Binary floating-point values, decimal major-unit values, negative amounts,
fractional minor units, numeric strings, and implicit coercions are invalid.

Schema v1 does not introduce currency conversion or multiple-currency
semantics.

## Strict decoding

Persisted event data is untrusted. The Schema v1 decoder rejects:

- malformed or invalid UTF-8 JSON;
- a non-object top-level value;
- missing or extra top-level fields;
- a missing, non-integer, or unsupported `schema_version`;
- a missing, non-string, or unknown `event_type`;
- a missing or non-object `payload`;
- missing or extra event-specific payload fields;
- non-string transaction IDs, barcodes, or descriptions;
- negative, inexact, fractional, or incorrectly typed money fields;
- a non-empty `transaction_completed` payload.

The decoder does not ignore unknown fields or coerce values. Semantic evolution
must use an explicit schema version instead of changing the meaning of Schema
v1 data in place.

Decoding returns either a domain event or a codec failure with a stable code and
diagnostic message. Current failure codes are:

```text
malformed-json
expected-object
missing-field
unexpected-field
unsupported-schema-version
unknown-event-type
invalid-field-type
invalid-money
```

Low-level JSON parser or hash exceptions are not exposed as persisted-data
diagnostics.

## Compatibility and versioning

Schema v1 field names, event-type strings, required fields, and value types are
durable compatibility commitments.

A reader that does not support a record's `schema_version` must reject it. A
future incompatible payload change requires a new schema version and an
explicit decoding or migration strategy. Existing Schema v1 records must remain
decodable according to the rules in this document.

## Deliberately deferred metadata

Schema v1 does not contain:

- SQLite row IDs or table definitions;
- transaction stream keys;
- stream sequence numbers;
- event IDs;
- recorded timestamps;
- previous or current hashes;
- command IDs;
- filesystem paths or other storage locations.

The current SQLite journal supplies its row identity, transaction stream key,
and stream sequence outside Schema v1. The remaining metadata stays
deliberately deferred. See [SQLite Transaction Journal](transaction-journal.md).
