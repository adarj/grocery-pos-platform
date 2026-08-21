# Flutter POS Core Client Foundation

## Status

The Flutter `pos_terminal` implements a typed client for the three current
local POS Core routes, a cashier-session application controller, and the first
cashier presentation slice: starting a sale, submitting barcode scans, and
rendering the authoritative basket returned by POS Core.

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
  features/cashier/                 session state, IDs, orchestration, and UI
  features/status/                  health gateway to the cashier
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

## Cashier session orchestration

`CashierSessionController` is a plain `ChangeNotifier` with one immutable
`CashierSessionState`. It owns application/session concerns only:

- creating a new transaction and command ID for a new start intent;
- creating one new command ID for every other new logical mutation;
- deriving a new command's `expectedVersion` only from the current
  authoritative `TransactionSnapshot`;
- allowing only one command or refresh operation in flight;
- retaining the exact command after an uncertain outcome;
- explicitly resubmitting that same object when retry is requested;
- refreshing authoritative transaction state after a known durable result.

The production `CashierIdGenerator` uses secure random opaque identifiers.
Their `cmd_` and `txn_` prefixes aid local diagnosis but have no business
meaning and are never parsed. ID generation is injected so orchestration tests
can be deterministic.

A new intent and a retry are different operations:

```text
new intent
  -> new command ID
  -> expected version from authoritative GET snapshot

uncertain retry
  -> exact retained TransactionCommand
  -> same command ID, transaction ID, expected version, and payload
```

The controller never automatically retries a mutation or changes its identity.
An uncertain start retains both the generated command ID and generated
transaction ID.

## Snapshot trust and refresh

A non-null snapshot in `CashierSessionState` means that it is currently trusted
as the concurrency basis for a new command. The controller invalidates that
snapshot before submitting a mutation or starting a refresh. It remains
unavailable after an uncertain mutation, a non-retryable mutation failure, or a
failed post-command read.

A `PosCommandResult` is stored for presentation but never used to update
version, line items, totals, tender, change, or transaction status. Accepted,
domain-rejected, and version-conflicted non-start commands are followed by
`fetchTransaction`; only that returned snapshot restores mutation capability.
A durable `not_found` clears the active session without fabricating state.

An accepted start refreshes the generated transaction ID. A start result of
`already_exists` is surfaced but does not attach the cashier to the collided
transaction. An explicit query error with code `transaction_not_found` also
clears the active session; other read failures retain the active ID so the user
can request another GET without resending the resolved command.

While an uncertain command is pending, new mutations and ordinary refresh are
blocked because GET alone cannot prove the original command's durable outcome.
Only `retryPendingCommand` resolves it through the backend command receipt.

## Cashier presentation

The health screen remains the liveness gateway and exposes an explicit
`Open Register` action only after POS Core reports healthy. The cashier screen
then renders `CashierSessionState` and invokes controller intent methods; it
does not construct commands, generate IDs, choose expected versions, or call
`PosCoreClient` directly.

The current presentation supports:

- `Start Sale`, whose basket appears only after the controller's authoritative
  transaction GET succeeds;
- barcode entry through a labeled field, button submission, or keyboard-wedge
  scanner Enter submission;
- backend-order line-item rendering and integer-only USD minor-unit formatting;
- backend-provided subtotal and total rendering without local calculation;
- concise feedback for unknown barcodes and version conflicts;
- an explicit `Retry Command` recovery panel for an uncertain mutation;
- a distinct `Refresh Transaction` panel when a command is known but the
  subsequent authoritative read failed.

The scan field is disabled while an operation is active. A scanned item is not
added optimistically: while the POST is resolved but its GET is pending, the
old snapshot is withheld and the UI shows a loading state. After an accepted
scan and successful refresh, the field is cleared and focused for the next
keyboard/scanner entry. A rejected barcode remains available for correction.

`Retry Command` calls only `CashierSessionController.retryPendingCommand`, so
the retained command identity is preserved. `Refresh Transaction` calls only
`CashierSessionController.refreshTransaction`, so it cannot accidentally
resend a command whose durable result is already known.

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

Pending commands currently exist only in Flutter process memory. A Flutter
process crash after an uncertain POST can therefore lose the retained command;
durable client-side pending-intent recovery remains future work and must not be
approximated by generating a replacement ID.

This slice does not implement tender or completion controls, automatic retry,
retry timers, pending-command persistence, local Flutter storage, or payment
behavior. Tender and completion presentation are deferred to the next cashier
checkpoint.
