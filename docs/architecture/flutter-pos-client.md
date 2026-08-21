# Flutter POS Core Client Foundation

## Status

The Flutter `pos_terminal` implements a typed client for the three current
local POS Core routes, a cashier-session application controller, and the
current cash-sale cashier slice: start, scan, cash tender, authoritative paid
state/change, completion, crash-safe command-intent recovery, and explicit
next-sale session transition.

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
Flutter owns presentation and cashier intent orchestration; it does not
calculate authoritative totals, advance transaction lifecycle, or infer stream
versions.

The source is organized as:

```text
lib/
  main.dart                         process composition
  app/pos_terminal_app.dart         Material application
  core/pos_core/                    typed client boundary and HTTP adapter
    models/                         wire-facing immutable values
  features/cashier/                 session state, recovery, orchestration, UI
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

## Crash-safe cashier recovery

The controller persists a purpose-built local recovery record before every
new mutation is sent:

```text
create exact typed command
  -> save active transaction ID + pending command
  -> POST command
  -> known result saves active ID + pending null
  -> authoritative GET
```

The versioned record contains exactly an active transaction ID and an optional
Transaction Command Schema v1 command. It never contains a transaction
snapshot, line items, totals, status, tender/change, command result, event, or
backend receipt. This store is client intent/session metadata, not transaction
truth; POS Core remains the only authority for sale state.

```json
{
  "schema_version": 1,
  "active_transaction_id": "txn_...",
  "pending_command": {
    "schema_version": 1,
    "command_id": "cmd_...",
    "transaction_id": "txn_...",
    "expected_version": 3,
    "command_type": "scan_barcode",
    "payload": { "barcode": "049000001234" }
  }
}
```

`pending_command` may be null; when present, its transaction ID must equal the
active transaction ID.

The Linux file store resolves to:

- `$XDG_STATE_HOME/grocery-pos/pos-terminal/cashier-session-v1.json` when
  `XDG_STATE_HOME` is non-empty;
- otherwise `$HOME/.local/state/grocery-pos/pos-terminal/cashier-session-v1.json`.

If neither location is configured, local recovery is unavailable and the
cashier fails closed. Saves write and flush a complete temporary file in the
same directory before renaming it over the live record. This avoids normally
exposing a partially serialized live JSON record; it is not a claim of stronger
power-loss durability than the operating system/filesystem provides.

Local decoding requires the exact v1 record fields and a supported, valid typed
command. A schema mismatch, malformed field, unsupported command, or pending
command whose transaction differs from the active transaction blocks the
cashier as `Register recovery required`. Corrupt recovery state is neither
deleted nor bypassed automatically.

Startup performs only local restoration:

```text
no record
  -> initial cashier session

active ID + pending command
  -> Retry Command with the exact restored command

active ID + pending null
  -> Refresh Transaction using GET
```

Startup never automatically sends a command or loads transaction state. If a
command result was known and clearing its pending marker fails, the stale
stored command is conservative: a restart may offer same-command retry, and
the backend returns the original receipt without duplicating the business
fact. If pending-null persistence succeeded but GET did not, restart offers
refresh and never resends the resolved command.

A local save failure before POST preserves the current trusted snapshot where
one exists, reports that the command was not sent, and performs no backend
mutation. A later explicit cashier action may try again after local storage is
usable.

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
- exact human cash-entry parsing into integer minor units without floating
  point;
- cash-tender submission without locally deciding sufficiency;
- authoritative paid-state, tendered-cash, and change presentation;
- sale completion followed by an authoritative completed-state read;
- an explicit `Next Sale` action after an authoritative completed snapshot;
- concise feedback for unknown barcodes and version conflicts;
- an explicit `Retry Command` recovery panel for an uncertain mutation;
- a distinct `Refresh Transaction` panel when a command is known but the
  subsequent authoritative read failed.

The scan field is disabled while an operation is active. A scanned item is not
added optimistically: while the POST is resolved but its GET is pending, the
old snapshot is withheld and the UI shows a loading state. After an accepted
scan and successful refresh, the field is cleared and focused for the next
keyboard/scanner entry. A rejected barcode remains available for correction.

Cash input accepts whole dollars or one/two decimal places after ignoring
surrounding whitespace. It rejects signs, currency symbols, commas, exponent
notation, trailing decimal points, and more than two decimal places. Parsing
uses string and integer operations only. Syntactically valid amounts—including
cash below the displayed total—are sent to POS Core; Racket alone decides
whether the transaction is non-empty, open, and sufficiently tendered.

The UI does not infer `paid`, calculate change, or infer `completed` from a
successful command result. Those presentations appear only after
`fetchTransaction` returns the corresponding authoritative snapshot. Tendered
cash and change are rendered directly, even if they do not match a client-side
arithmetic assumption. A paid/completed snapshot with missing payment details
shows a safe unavailable state rather than inventing zero values.

`Retry Command` calls only `CashierSessionController.retryPendingCommand`, so
the retained command identity is preserved. `Refresh Transaction` calls only
`CashierSessionController.refreshTransaction`, so it cannot accidentally
resend a command whose durable result is already known. These same recovery
paths apply to scan, tender, and completion commands.

`Next Sale` is a client-session safety operation, not a Racket lifecycle rule.
It is available only from an authoritative completed snapshot. One explicit
press clears the completed local session before creating, persisting, and
sending a new start intent with new transaction and command IDs. Open and paid
sessions cannot be abandoned through this operation. Completion does not
automatically begin another sale.

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

This slice does not implement automatic retry, retry timers, cached/offline
transaction truth, split tender, card/external payment behavior, receipt
printing, or drawer behavior. The recovery file currently contains only
barcode and integer-cash command payloads and is never logged.

Future payment, terminal, and device commands must not reuse this storage
design automatically. They require separate security analysis and explicit
unknown-external-effect recovery; in particular, this checkpoint does not
implement `PaymentUnknown` or make an uncertain charge safe to submit again.
