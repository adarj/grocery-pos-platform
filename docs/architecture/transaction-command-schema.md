# Transaction Command Schema v1

## Status

Transaction Command Schema v1 defines the stable JSON representation of the
four mutating commands supported by the current cash-sale transaction slice.

It defines transport-independent command values and their logical identity. It
does not define HTTP routes or idempotent service processing. The separate
[Transaction Command Receipts](transaction-command-receipts.md) contract uses
this schema as its durable command representation.

## Purpose and boundary

A command describes one caller intent. It belongs at the application boundary,
not in authoritative transaction state:

```text
untrusted JSON
    -> strict Transaction Command Schema v1 decoding
    -> immutable typed Racket command
    -> future application command processing
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
- `command_id` is a non-empty opaque string identifying one logical intent.
- `transaction_id` is a non-empty opaque string naming the target transaction.
- `expected_version` is an exact nonnegative integer supplied by the caller.
- `command_type` is one of the four strings defined below.
- `payload` has the exact command-specific object shape defined below.

The codec does not trim, case-fold, generate, or otherwise reinterpret command
IDs, transaction IDs, or barcodes. String-size and request-body limits belong
to the future HTTP boundary.

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

Schema v1 does not implement or define:

- application-level duplicate-command orchestration;
- service-level expected-version enforcement;
- application production and reuse of durable receipt outcomes;
- HTTP request or response mappings;
- server-side command-ID generation;
- cryptographic request hashes or canonical JSON.
