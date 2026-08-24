# Transaction Command Schema v1

## Status

Transaction Command Schema v1 defines the stable JSON representation of the
six mutating commands supported by the current cash-sale transaction slice.

It defines transport-independent command values and their logical identity. The
persistent transaction application service accepts these typed values through
one idempotent mutation boundary, and
[Transaction HTTP API v1](transaction-http-api-v1.md) reuses this codec as its
request-body contract rather than defining another command representation. The
separate [Transaction Command Receipts](transaction-command-receipts.md)
contract uses this schema as its durable command representation. The governing
identity and retry decision is recorded in
[ADR-0011](../adr/0011-use-durable-command-receipts-and-expected-stream-versions.md).

## Purpose and boundary

A command describes one caller intent. It belongs at the application boundary,
not in authoritative transaction state:

```text
untrusted JSON
    -> strict Transaction Command Schema v1 decoding
    -> immutable typed Racket command
    -> idempotent application command processing
```

Transaction events remain the accepted business facts from which authoritative
transaction state is reconstructed. Commands are requests and do not become
transaction truth merely because they decode successfully.

## Common envelope

Every Schema v1 command is a JSON object containing exactly these fields:

```json
{
  "schema_version": 1,
  "command_id": "cmd-001",
  "transaction_id": "txn-001",
  "expected_version": 2,
  "command_type": "scan_barcode",
  "payload": {}
}
```

- `schema_version` is the exact JSON integer `1`.
- `command_id` is a non-empty opaque string identifying one logical intent. The
  application/persistence contract treats it as globally unique within the
  local register database.
- `transaction_id` is a non-empty opaque string naming the target transaction.
- `expected_version` is an exact nonnegative integer supplied by the caller.
- `command_type` is one of the six strings defined below.
- `payload` has the exact command-specific object shape defined below.

The codec does not trim, case-fold, generate, or otherwise reinterpret command
IDs, transaction IDs, or barcodes. The current HTTP adapter does not claim a
network-level streaming/body-size limit; such transport hardening remains
separate from command value semantics.

## Command types

### `start_transaction`

```json
{
  "schema_version": 1,
  "command_id": "cmd-start",
  "transaction_id": "txn-001",
  "expected_version": 0,
  "command_type": "start_transaction",
  "payload": {}
}
```

### `scan_barcode`

```json
{
  "schema_version": 1,
  "command_id": "cmd-scan",
  "transaction_id": "txn-001",
  "expected_version": 1,
  "command_type": "scan_barcode",
  "payload": {
    "barcode": "049000001234"
  }
}
```

`barcode` is a non-empty opaque string. Its leading zeros are significant.

### `tender_cash`

```json
{
  "schema_version": 1,
  "command_id": "cmd-tender",
  "transaction_id": "txn-001",
  "expected_version": 2,
  "command_type": "tender_cash",
  "payload": {
    "amount_minor_units": 500
  }
}
```

Money is represented only as exact nonnegative integer minor units. Binary
floating-point values, fractional minor units, major-unit decimals, negative
values, and numeric strings are invalid.

### `complete_transaction`

```json
{
  "schema_version": 1,
  "command_id": "cmd-complete",
  "transaction_id": "txn-001",
  "expected_version": 3,
  "command_type": "complete_transaction",
  "payload": {}
}
```

### `remove_line_item`

```json
{
  "schema_version": 1,
  "command_id": "cmd-remove",
  "transaction_id": "txn-001",
  "expected_version": 4,
  "command_type": "remove_line_item",
  "payload": {
    "line_index": 1
  }
}
```

`line_index` is an exact nonnegative integer and is zero-based in the
authoritative line list at `expected_version`. An out-of-range index is a
structurally valid command that receives the durable domain outcome
`line_item_not_found`. Expected-version enforcement happens before the domain
interprets the index, so a stale selection is never retargeted against a newer
line list.

### `void_transaction`

```json
{
  "schema_version": 1,
  "command_id": "cmd-void",
  "transaction_id": "txn-001",
  "expected_version": 4,
  "command_type": "void_transaction",
  "payload": {}
}
```

Voiding is a pre-payment correction accepted only for an open transaction.
Authorization and post-payment reversal are separate future concerns.

## Typed request identity

Logical command identity is the fully decoded immutable command value, not the
raw JSON bytes. Two successfully decoded Schema v1 documents identify the same
logical request when their typed command values are structurally equal.

Therefore, insignificant whitespace, JSON object member ordering, and
equivalent legal JSON escape spellings do not change command identity. A
change to the command ID, transaction ID, expected version, command type, or
typed payload value does change it.

The concrete Racket command variants are intrinsically Schema v1. The v1 decoder
rejects any other schema version, and the encoder always emits version 1. No
cryptographic canonical-JSON representation is defined or required.

## Strict decoding

Command data is untrusted. The Schema v1 decoder rejects:

- malformed or invalid UTF-8 JSON;
- trailing non-whitespace content after the one JSON value;
- duplicate object member names at any nesting level, including names with
  different but escape-equivalent spellings;
- a non-object top-level value;
- missing or extra envelope fields;
- an unsupported or incorrectly typed schema version;
- an unknown or incorrectly typed command type;
- a missing or non-object payload;
- missing or extra command-specific payload fields;
- non-string or empty command IDs and transaction IDs;
- negative, fractional, inexact, or string expected versions;
- a non-string or empty scan barcode;
- negative, fractional, inexact, or string cash amounts;
- negative, fractional, inexact, or string removal line indices;
- fields in commands whose payload must be empty.

The decoder performs no coercion and returns either a typed command or a codec
failure with one of these stable codes:

```text
malformed-json
duplicate-field
expected-object
missing-field
unexpected-field
unsupported-schema-version
unknown-command-type
invalid-field-type
invalid-command-id
invalid-transaction-id
invalid-expected-version
invalid-barcode
invalid-money
invalid-line-index
```

Schema evolution must use an explicit new schema version rather than silently
changing the meaning of Schema v1.

## Durable receipt relationship

Migration v2 can store a Schema v1 command inside a durable command receipt.
The receipt duplicates selected envelope values for lookup and diagnostics,
but load strictly decodes `command_json` through this codec and rejects any
metadata disagreement. Typed command equality remains the request-identity
rule; raw JSON formatting is not identity.

The receipt is idempotency and outcome metadata. It does not make a requested
command an accepted transaction fact, and transaction replay does not consult
receipts.

## Deliberately deferred

Schema v1 itself does not implement or define:

- server-side command-ID generation;
- cryptographic request hashes or canonical JSON.

The separate [Transaction HTTP API v1](transaction-http-api-v1.md) defines the
implemented route and response mapping while continuing to use this codec
unchanged.
