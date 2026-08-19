# Transaction HTTP API v1

## Status and boundary

Transaction HTTP API v1 exposes the implemented durable cash-sale application
boundary through the local Racket server. It is a transport adapter over the
existing typed command service and authoritative transaction query; it does not
implement transaction rules, idempotency, replay, or SQLite persistence.

The implemented routes are:

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/health` | Process liveness |
| `POST` | `/transaction-commands` | Execute or resolve one typed transaction command |
| `GET` | `/transactions/{transaction_id}` | Read current authoritative transaction state |

No command-specific mutation routes exist. The one command endpoint mirrors
`transaction-service-execute-command` and prevents route handlers from
reimplementing command dispatch or retry semantics.

## Command request

`POST /transaction-commands` requires `Content-Type: application/json`.
Parameters such as `charset=utf-8` are accepted. A missing or non-JSON content
type returns `415 Unsupported Media Type` with code
`unsupported_media_type`.

The body is exactly
[Transaction Command Schema v1](transaction-command-schema.md):

```json
{
  "schema_version": 1,
  "command_id": "cmd_scan_001",
  "transaction_id": "txn_001",
  "expected_version": 1,
  "command_type": "scan_barcode",
  "payload": {
    "barcode": "049000001234"
  }
}
```

The adapter passes the raw UTF-8 body bytes to the existing strict command
codec. It performs no second JSON interpretation or command normalization.
Consequently, duplicate fields, trailing content, invalid UTF-8, extra fields,
wrong primitive types, unsupported versions, and non-integer money retain the
Schema v1 rejection policy.

An absent or empty body returns reason `missing_body`. Other decode failures
return the codec's stable reason converted to snake case:

```json
{
  "ok": false,
  "error": {
    "code": "invalid_transaction_command",
    "reason": "missing_field",
    "message": "Transaction command is invalid."
  }
}
```

Malformed transport data receives `400 Bad Request` and creates no command
receipt. The response never echoes the invalid body or exposes the codec's
free-form diagnostic.

## Durable command result

A resolved command returns only its durable original receipt metadata:

```json
{
  "ok": true,
  "command_result": {
    "command_id": "cmd_scan_001",
    "transaction_id": "txn_001",
    "outcome_kind": "accepted",
    "outcome_code": "accepted",
    "outcome_stream_version": 2
  }
}
```

The response does not contain current transaction state, a duplicate flag,
event payloads, or persistence metadata. First execution and an identical
same-ID retry return the same meaningful status and JSON. A delayed retry
continues to return its original outcome version even after the transaction
advances. Current state is obtained through the separate transaction query.

Durable receipt outcomes map as follows:

| Outcome kind | `ok` | HTTP status |
| --- | --- | --- |
| `accepted` | `true` | `200 OK` |
| `domain_rejected` | `false` | `409 Conflict` |
| `not_found` | `false` | `404 Not Found` |
| `already_exists` | `false` | `409 Conflict` |
| `version_conflict` | `false` | `409 Conflict` |

`outcome_code` is the stable durable application code, such as
`unknown_barcode`, `transaction_not_found`, `transaction_already_exists`,
`stale_expected_version`, or `stream_version_conflict`.

The command endpoint uses `200`, not `201`, for every accepted command because
it represents command processing rather than a command-specific REST resource
creation operation.

## Command failures and uncertain outcomes

A command ID already associated with a different typed command returns:

```json
{
  "ok": false,
  "error": {
    "code": "command_id_reused",
    "message": "Command ID is already associated with a different command."
  }
}
```

with `409 Conflict`. The original command and receipt are not exposed.

A stable application persistence failure returns `500 Internal Server Error`:

```json
{
  "ok": false,
  "error": {
    "code": "command_persistence_failed",
    "message": "The command could not be committed. Retry using the same command ID.",
    "retry_same_command_id": true
  }
}
```

A receipt/journal/replay recovery failure returns code
`transaction_recovery_failed` without corruption positions, decoder details,
SQL, or raw stored values.

Once a valid typed command has been decoded, an escaping exception cannot prove
that the atomic commit did not land. The HTTP adapter therefore returns:

```json
{
  "ok": false,
  "error": {
    "code": "command_outcome_unknown",
    "message": "The command outcome could not be confirmed. Retry using the same command ID.",
    "retry_same_command_id": true
  }
}
```

The client must retry the same typed command with the same command ID. It must
not generate a replacement ID, and the server does not automatically execute
the command again within the failed request. This is the HTTP expression of
[ADR-0011](../adr/0011-use-durable-command-receipts-and-expected-stream-versions.md).

## Transaction query

`GET /transactions/{transaction_id}` treats the one non-empty path segment as
an opaque, case-sensitive transaction ID. It takes no command ID or expected
version and reconstructs current state from the authoritative event journal.

A successful response is:

```json
{
  "ok": true,
  "transaction": {
    "transaction_id": "txn_001",
    "version": 2,
    "status": "open",
    "line_items": [
      {
        "barcode": "049000001234",
        "description": "Test Apples",
        "unit_price_minor_units": 199
      }
    ],
    "subtotal_minor_units": 199,
    "total_minor_units": 199,
    "tendered_cash_minor_units": null,
    "change_due_minor_units": null
  }
}
```

Current status values are exactly `open`, `paid`, and `completed`. All currency
values are exact JSON integer minor units. Tender and change fields remain
present as JSON null before tender. The response contains no command receipts,
event history, database row IDs, or journal metadata.

A missing transaction returns `404 Not Found` with code
`transaction_not_found`. A journal or replay recovery failure returns
`500 Internal Server Error` with code `transaction_recovery_failed`. An
unexpected query exception returns the generic code `internal_error`. None of
these responses exposes an internal exception message.

## Routing and common errors

Recognized routes with the wrong method return `405 Method Not Allowed` and an
`Allow` header:

| Route | `Allow` |
| --- | --- |
| `/health` | `GET` |
| `/transaction-commands` | `POST` |
| `/transactions/{transaction_id}` | `GET` |

Unknown paths and malformed transaction query shapes return the common
structured `404` response:

```json
{
  "ok": false,
  "error": {
    "code": "not_found",
    "message": "Route not found."
  }
}
```

All HTTP errors use the stable `{ok:false,error:{code,message}}` envelope.
Optional fields such as `reason` and `retry_same_command_id` appear only for
the cases documented above. Programmatic clients branch on `code`, not prose.

## Safety and current limitations

The adapter never returns stack traces, arbitrary `exn-message` text, SQL
errors, corrupt journal contents, raw command JSON, or application persistence
details.

The server is loopback-bound by default but is still an application trust
boundary. Transaction HTTP API v1 does not add authentication, actor/session
authorization, or production security claims. It also does not add a request
streaming/body-size guarantee, readiness endpoint, automatic SQLite busy
retry, persistent catalog, payment behavior, or external-effect exactly-once
semantics. Flutter now has a typed client for this surface, but the cashier
workflow and transaction widgets remain unimplemented.
