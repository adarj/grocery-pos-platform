# Flutter POS Core Client Foundation

## Status

The Flutter `pos_terminal` implements a typed client for the current local POS
Core authentication, transaction, receipt, and register-operation routes, a
process-memory authentication controller, a cashier-session application
controller, and the
current cash-sale cashier slice: start, scan, cash tender, authoritative paid
state/change, completion, open-sale line removal/void, crash-safe
command-intent recovery, explicit next-sale session transition, and read-only
canonical completed-sale receipt lookup.

The backend wire contract remains authoritative and is documented in
[Transaction HTTP API v1](transaction-http-api-v1.md). Command retry semantics
are governed by
[ADR-0011](../adr/0011-use-durable-command-receipts-and-expected-stream-versions.md).

## Boundary

`PosCoreClient` is the Flutter application boundary for:

- reading process health;
- reading structured runtime/persistence readiness, including expected 503
  states;
- executing one typed transaction command;
- reading current authoritative transaction state;
- reading a canonical completed-sale receipt by exact transaction ID;
- reading configured register/active-shift context and active cashier choices;
- explicitly opening and reconciling/closing a register shift;
- reading authoritative shift cash summaries.

`PosAuthenticationClient` is deliberately separate. It owns login, current
session lookup, and logout transport. `MemoryAuthenticationSession` retains the
opaque bearer only for the life of the Flutter process and supplies it to the
HTTP adapter for protected requests. A definitive
`authentication_required` 401 clears that memory centrally; a transient 503
does not falsely revoke it.

Widgets do not receive raw `http.Response` values or package HTTP exceptions.
Flutter owns presentation and cashier intent orchestration; it does not
calculate authoritative totals, advance transaction lifecycle, or infer stream
versions.

## Appliance endpoint and sandbox boundary

Production composition resolves `GROCERY_POS_CORE_BASE_URI`, defaulting to
`http://127.0.0.1:7340`. The value must use HTTP, a literal `127.0.0.1` or
`::1`, no credentials, no non-root path/query/fragment, and a legal explicit or
default port. This seam permits an alternate local appliance port without
creating remote API support; backend listener validation remains independent.

The Kinoite cashier artifact is a system Flatpak with only Wayland, DRI, and
network sharing. It has no host/home filesystem or database access. Flutter's
existing XDG state resolver naturally maps into Flatpak-private persistent
state, so the exact write-before-POST recovery record survives application,
session, reboot, and deployment transitions without becoming POS truth.

The Linux runner reads `GROCERY_POS_KIOSK=1`. Only that mode starts fullscreen
without the ordinary GTK header/title bar. With the variable absent, the
existing development desktop window is unchanged. One cashier window is
created; no customer-display or mirroring behavior is introduced. See
[ADR-0025](../adr/0025-run-cashier-ui-as-dedicated-plasma-flatpak-kiosk.md).

The source is organized as:

```text
lib/
  main.dart                         process composition
  app/pos_terminal_app.dart         Material application
  core/pos_core/                    typed client boundary and HTTP adapter
    models/                         wire-facing immutable values
  features/authentication/         register lock, login, in-memory session
  features/cashier/                 session state, recovery, orchestration, UI
  features/receipt/                 read-only receipt lookup and presentation
  features/status/                  health/register/shift operational home
```

## Commands

The six sealed command variants mirror Transaction Command Schema v1:

- `StartTransactionCommand`;
- `ScanBarcodeCommand`;
- `TenderCashCommand`;
- `CompleteTransactionCommand`;
- `RemoveLineItemCommand`;
- `VoidTransactionCommand`.

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
snapshot, line items, subtotal/tax/total, status, tender/change, command result, event, or
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

## Register operational home

After health succeeds, Flutter reads typed `RegisterContext`. An unconfigured
database shows `Register configuration required`, points to the explicit CLI
workflow, blocks `Open Register`, and still permits historical receipt lookup.
Flutter does not create a default identity.

A configured register with no shift shows the authenticated operator, accepts
exact opening cash through the shared integer-only money parser, and offers
`Open Shift`. The request sends only nonnegative opening minor units; Racket
derives and validates the shift cashier. While it is pending the action cannot
be submitted again. Transport
uncertainty offers `Refresh Register State`; it never enters transaction
same-command recovery.

An active own shift displays its snapshotted register/cashier names, opaque
shift ID, and explicitly UTC open time. It enables `Open Register`, receipt
lookup, and a close-reconciliation workflow. Another operator's active shift
shows register-in-use and cannot be adopted for transaction work. The
cashier enters an independent physical count; expected cash is not prefilled.
An active-sale close rejection tells the operator to finish or void the sale;
Flutter never abandons transaction state to force closure. Success first shows
the authoritative opening, sales, expected, counted, and signed over/short
values, then `Done` returns to the authenticated register home.

`ShiftCashSummary` strictly discriminates `limited` and `full`. A limited open
view permits only shift ID, status, and view. A full view requires nonnegative
opening/sales/expected/count fields, a nonnegative completed-sale count, and a
signed variance only for closed reconciliation. Widgets render returned values
independently even if arithmetically surprising. Flutter never calculates
expected cash or over/short.

An uncertain open or close is recovered through `GET /register-context` and
`GET /shifts/{shift_id}/cash-summary`; Flutter does not automatically repeat the
write. A closed summary recovers the durable result after response loss. No
cash summary or reconciliation is added to `CashierSessionStore`.

The operational models and client parse exact nonnegative epoch milliseconds,
strict identity fields, and valid configured/shift nullability. Operational
writes create no transaction command ID and do not touch
`CashierSessionStore`.

Flutter parses server-supplied permissions into typed presentation hints; it
contains no role-to-permission matrix. Racket relates the authenticated
operator to durable cashier/shift ownership and independently enforces every
operation. Local recovery schema v2 stores only its operator owner, active
transaction ID, and optional exact pending command. A different operator
cannot send or erase that state. Legacy schema-v1 state binds only after
authoritative current shift-slot evidence agrees or an authorized transaction
query supplies `owned_by_authenticated_operator: true` from durable operational
context. This second proof preserves exact completion/void recovery after the
active slot is released. A legacy pending start whose transaction does not
exist remains preserved but unbound rather than being assigned from its local
ID alone.

## Register authentication and lock

Terminal startup calls only public health/readiness routes. A ready terminal
starts locked and does not fetch register, cashier, shift, transaction, or
receipt state until local operator login succeeds. The kiosk-friendly view
collects an exact operator ID and masked 8–12 digit PIN, disables suggestions,
and clears the PIN field after every submission. It displays one generic
failure message for wrong, missing, inactive, unenrolled, or throttled
identities.

The access token is memory-only. It is not part of `CashierSessionController`,
`CashierSessionStore`, Flatpak/XDG files, preferences, logs, or crash text.
Manual `Lock` immediately obscures protected presentation, clears token memory,
and then attempts best-effort server logout. A high-level five-minute input
timer supplies presentation locking; server-side expiry remains authoritative.
If a 401 arrives while a pushed cashier/receipt route is open, the app shell
immediately obscures it and replaces the root navigator identity. That disposes
the authenticated subtree and its complete protected route history. A later
operator therefore receives a newly constructed status/register view and fresh
protected queries rather than access to the prior operator's widget state.

Locking never clears transaction recovery. A transaction POST rejected by
authentication before dispatch remains an exact pending command and is retried
with its original command ID only after reauthentication. Likewise, if a
command committed before POS Core process death, restart invalidates the bearer
but the same persisted command resolves through its durable command receipt
after a fresh login. No bearer/session identifier is added to the transaction
command schema.

## Cashier presentation

The health/register home remains the liveness and operational gateway and
exposes `Open Register` only while an active shift exists. The cashier screen
then renders `CashierSessionState` and invokes controller intent methods; it
does not construct commands, generate IDs, choose expected versions, or call
`PosCoreClient` directly.

The current presentation supports:

- `Start Sale`, whose basket appears only after the controller's authoritative
  transaction GET succeeds;
- barcode entry through a labeled field, button submission, or keyboard-wedge
  scanner Enter submission;
- backend-order line-item rendering and integer-only USD minor-unit formatting;
- backend-provided subtotal, tax, and total rendering without local
  calculation;
- exact human cash-entry parsing into integer minor units without floating
  point;
- cash-tender submission without locally deciding sufficiency;
- authoritative paid-state, tendered-cash, and change presentation;
- sale completion followed by an authoritative completed-state read;
- confirmed removal of one selected open-sale line, followed by an
  authoritative read;
- confirmed pre-payment void, followed by an authoritative `voided` read;
- an explicit `Next Sale` action after an authoritative completed or voided
  snapshot;
- concise feedback for unknown barcodes and version conflicts;
- an explicit `Retry Command` recovery panel for an uncertain mutation;
- a distinct `Refresh Transaction` panel when a command is known but the
  subsequent authoritative read failed.

The scan field is disabled while an operation is active. A scanned item is not
added optimistically: while the POST is resolved but its GET is pending, the
old snapshot is withheld and the UI shows a loading state. After an accepted
scan and successful refresh, the field is cleared and focused for the next
keyboard/scanner entry. A rejected barcode remains available for correction.

Open transactions are scanner-first. Barcode entry remains a keyboard-wedge
integration: the scanner types an opaque identifier into the text field and
sends Enter. Autocorrect, suggestions, and smart punctuation are disabled for
that field, while identifier normalization and scanner timing heuristics remain
absent. Focus is requested only at workflow transitions—when an authoritative
open snapshot first becomes available, after a resolved scan refresh, after a
restored-session refresh/retry, or after Next Sale reaches its authoritative
new transaction. It is not requested on every build, so deliberately focusing
cash or another control is not immediately undone.

F2 focuses barcode and F4 focuses cash only while an authoritative open sale is
idle. They are focus-only shortcuts: they never submit a mutation, generate an
ID, bypass recovery, or operate during busy, paid, completed, or blocked states.
The shortcuts are also inert in voided state.
Enter remains the only keyboard-wedge submission mechanism. While one scan is
unresolved the input controls are unavailable, and no scan queue or buffered
second intent exists.

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
paths apply to scan, tender, completion, removal, and void commands. A retry
uses the exact persisted correction command; it never reconstructs one from
currently visible line or dialog state.

`Next Sale` is a client-session safety operation, not a Racket lifecycle rule.
It is available only from an authoritative completed or voided snapshot. One
explicit press clears the terminal local session before creating, persisting,
and sending a new start intent with new transaction and command IDs. Open and
paid sessions cannot be abandoned through this operation. Completion or void
does not automatically begin another sale. Barcode focus returns only after
the new start command resolves and its authoritative GET reports an open
transaction.

POS Core additionally requires an open idle shift for every new start. A stale
Flutter home cannot bypass that rule. `shift_required` is rendered as `Open a
cashier shift before starting a sale.` without inventing an anonymous sale.
Completion or void atomically frees the backend shift slot, so Next Sale under
the same still-open shift uses the existing client lifecycle unchanged.

Each authoritative open basket row has a text-labeled Remove action. The
confirmation captures the exact source snapshot; if the controller's trusted
snapshot changes while the dialog is open, Flutter submits nothing and asks
the cashier to select the item again. The controller still derives
`expectedVersion`; the widget never supplies it. Backend expected-version
enforcement is the second guard against external concurrent changes. After a
confirmed command, the old basket is withheld and the row disappears only
after GET returns the corrected projection.

`Void Sale` is a secondary, confirmed open-sale action, including for an empty
sale. Flutter does not show `Sale Voided` from an accepted command result. Only
an authoritative `voided` snapshot establishes that terminal presentation,
which retains the backend-provided cancelled basket and subtotal/tax/total and
offers Next Sale. Paid, completed, and voided transactions expose no Remove or
Void controls; post-payment refund/reversal remains separate.

High-frequency and recovery actions use enlarged text-labeled touch targets.
Paid and completed presentations give the backend-provided Change Due value the
strongest monetary emphasis while retaining Total and Cash Received. Combined
semantic labels describe transaction status and authoritative money values;
recovery titles are headings, important durable-result feedback is a live
region, and the developer-oriented transaction version is excluded from the
accessibility tree. Wide, narrow, long-basket, and 2× text-scale widget tests
protect the current layout. These are targeted accessibility improvements, not
a claim of a complete accessibility audit.

Recovery interaction remains deliberately distinct: restored uncertain
commands show Retry Command and recover correction focus from the exact pending
typed command; known commands with unavailable current state show Refresh
Transaction; corrupt local recovery state exposes neither normal mutation path.

## Command results and transaction reads

Documented `200`, `404`, and `409` command-result responses all decode to a
`PosCommandResult`. Outcome kinds are closed typed values; `outcomeCode` remains
the backend's stable machine-readable code. `outcomeStreamVersion` is the
original durable command outcome version, not necessarily the transaction's
current version.

`TransactionSnapshot` mirrors the authoritative transaction query. Status is a
closed value (`open`, `paid`, `completed`, or `voided`), line items are
backend-provided,
and subtotal, tax, total, tender, and change remain integer minor units. Tax is
a required field and is never inferred as `total - subtotal`; the cashier
renders all three summary values independently. Tender and change are nullable
until the backend reports them. The client does not derive totals or synthesize
an empty transaction after a failed read.

## Canonical receipt reads

`CanonicalReceipt` and `CanonicalReceiptLine` strictly parse Receipt Schemas v1
and v2. Both preserve the backend's final stream version, retained line order,
sale-time price/tax fields, transaction totals, cash, and change. A legacy line
retains paired null category/rate metadata and zero stored line tax. Flutter
does not recalculate consistency: subtotal, tax, total, tender, and change are
rendered independently from the response.

Receipt v1 remains context-free for legacy transactions. Receipt v2 requires
exact register/cashier identities, shift ID, and paired start/completion epoch
milliseconds. The receipt screen presents these snapshots and formats the
completion time explicitly in UTC; it performs no current-configuration lookup
and invents no context for v1.

`fetchReceipt(transactionId)` is a query, not a mutation. It generates no
command ID or expected version, receives no same-command retry semantics, and
never touches `CashierSessionStore`. Explicitly repeating a failed GET is safe.

An authoritative completed cashier view exposes `View Receipt`, which opens a
dedicated screen and fetches the receipt from POS Core. It does not copy the
visible `TransactionSnapshot`. The connected gateway separately exposes
`Lookup Completed Sale`; lookup sends the exact submitted transaction ID only
after Enter/button activation and performs no normalization, case folding, or
search-as-you-type. Unknown and non-completed transactions receive distinct
safe messages. A failed receipt read leaves the completed cashier session
unchanged. Voided transactions do not expose View Receipt.

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

## Real POS Core integration evidence

An explicitly invoked Linux integration suite now crosses the production
boundary:

```text
CashierSessionController + FileCashierSessionStore
  -> HttpPosCoreClient
  -> real loopback HTTP
  -> real Racket runtime and transaction service
  -> isolated file-backed SQLite journal and command receipts
```

Each scenario owns a child POS Core process, a dynamically allocated loopback
port, a temporary SQLite file, and a temporary Flutter recovery record. POS
Core performs its normal startup migration; the harness does not create schema
or use a test-only route. Readiness is established through bounded polling of
the real `/ready` endpoint, while `/health` remains the independent liveness
contract. Teardown stops the child process before
removing its temporary directory.

Before the first server start, the fixture invokes the production catalog and
register-configuration activation CLIs against that isolated database.
Restarts reuse it without reseeding. Sale scenarios open an actual shift
through the typed HTTP client.

The suite covers the full cash sale and Next Sale, three sequential scans,
tax-aware line removal, same-ID removal duplicate prevention, void/restart/Next
Sale, ten bounded full-sale cycles, active and paid transaction recovery across
both Flutter-controller and POS Core restart, transport failure with a
persisted pending command, and GET-only restoration when pending is null. It also models
a real accepted scan whose local pending marker remains stale across POS Core
restart: retrying that exact restored command resolves through the durable
backend receipt and the authoritative basket contains the item exactly once.
It also loads a corrected completed-sale receipt through real HTTP, verifies
semantic receipt equality after POS Core restart, rejects a voided receipt,
and proves that replacing the current persistent catalog/tax snapshot cannot
change an old receipt's sale-time facts.

Operational scenarios additionally prove configured/no-shift startup,
same-cashier shift open with immutable opening cash, active-transaction close
protection, exact net sale movements, duplicate-completion defense, correction
and void cash behavior, exact and shortage reconciliation, close-response read
recovery, Receipt v2 attribution, shift/transaction binding across POS Core
restart, and historical identity stability after configuration rename. The
mixed ten-transaction endurance run uses one shift, reconciles only completed
sales, records a deliberate overage, and verifies the closed summary after
restart.

These tests remain outside ordinary `flutter test` discovery. The fast Flutter
unit/widget suite continues to use deterministic clients, while
`just test-pos-integration` owns the real backend automatically. Harness usage
and diagnostics are documented in
[POS integration testing](../development/integration-testing.md).

## Deliberately deferred

This slice does not implement automatic retry, retry timers, cached/offline
transaction truth, quantity editing, post-payment refund/reversal, split
tender, card/external payment behavior, receipt printing, receipt numbering or
date/recent-sale search, drawer hardware, cash drops, paid-outs, refunds, or
general accounting reports. Fixed endpoint/resource authorization and command
actor attribution are implemented in Racket; Flutter only consumes the
server-computed permission list. Manager approval, credential reset, the
general security audit ledger, and variance approval remain deferred.
Current recovery payloads may contain an opaque barcode, integer cash amount,
or nonnegative removal line index; void and lifecycle commands have empty
payloads. The recovery record is never logged.

Future payment, terminal, and device commands must not reuse this storage
design automatically. They require separate security analysis and explicit
unknown-external-effect recovery; in particular, this checkpoint does not
implement `PaymentUnknown` or make an uncertain charge safe to submit again.
