# Flutter POS Core Client Foundation

## Status

The Flutter `pos_terminal` implements a typed client for the three current
local POS Core routes. The cashier controller and transaction workflow widgets
are deliberately deferred to a later checkpoint.

The backend wire contract remains authoritative and is documented in
[Transaction HTTP API v1](transaction-http-api-v1.md). Command retry semantics
are governed by
[ADR-0011](../adr/0011-use-durable-command-receipts-and-expected-stream-versions.md).

## Boundary

`PosCoreClient` is the Flutter application boundary for:

- reading process health;
- executing one typed transaction command;
- reading current authoritative transaction state.

Widgets do not receive raw `http.Response` values or package HTTP exceptions.
Flutter owns presentation and future cashier intent orchestration; it does not
calculate authoritative totals, advance transaction lifecycle, or infer stream
versions.

The source is organized as:

```text
lib/
  main.dart                         process composition
  app/pos_terminal_app.dart         Material application
  core/pos_core/                    typed client boundary and HTTP adapter
    models/                         wire-facing immutable values
  features/status/                  current health/status presentation
```

## Commands

The four sealed command variants mirror Transaction Command Schema v1:

- `StartTransactionCommand`;
- `ScanBarcodeCommand`;
- `TenderCashCommand`;
- `CompleteTransactionCommand`.

Every command retains its caller-supplied `commandId`, `transactionId`, and
`expectedVersion`. Tender amounts are integer minor units. The HTTP client does
not generate command IDs, infer expected versions, mutate commands, or retry a
POST automatically.

Command identity belongs to the caller's logical intent. Higher-level cashier
orchestration must retain the exact command value whenever an uncertain result
requires a same-ID retry.

## Command results and transaction reads

Documented `200`, `404`, and `409` command-result responses all decode to a
`PosCommandResult`. Outcome kinds are closed typed values; `outcomeCode` remains
the backend's stable machine-readable code. `outcomeStreamVersion` is the
original durable command outcome version, not necessarily the transaction's
current version.

`TransactionSnapshot` mirrors the authoritative transaction query. Status is a
closed value (`open`, `paid`, or `completed`), line items are backend-provided,
and all money remains integer minor units. Tender and change are nullable until
the backend reports them. The client does not derive totals or synthesize an
empty transaction after a failed read.

## Failures and uncertain mutations

The client distinguishes:

- transport failure: no trustworthy response was obtained;
- structured server failure: the backend returned a safe error envelope;
- invalid response: JSON or typed fields violate the documented contract.

Structured errors preserve `code`, `message`, optional `reason`, and, for
mutation responses only, `retrySameCommandId`. A transport failure or invalid
response after attempting a valid command is conservatively marked as requiring
the same command ID because the client cannot prove that persistence did not
commit. The HTTP adapter does not perform that retry itself.

Query and health failures do not acquire mutation retry semantics. Unknown
outcome kinds, unknown transaction statuses, missing authoritative fields, and
floating-point or string money representations fail closed as invalid server
responses.

## Deliberately deferred

This foundation does not implement cashier workflow state, command-ID
generation, automatic retry, pending-command persistence, barcode input,
tender/completion widgets, local Flutter storage, or payment behavior.
