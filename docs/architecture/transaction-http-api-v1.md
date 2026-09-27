# Transaction HTTP API v1

## Status and boundary

Transaction HTTP API v1 exposes the implemented durable cash-sale application
boundary through the local Racket server. It is a transport adapter over the
existing typed command service, authoritative transaction query, and canonical
completed-sale receipt query; it does not implement transaction rules,
idempotency, replay, or SQLite persistence.

The implemented routes are:

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/health` | Process liveness |
| `GET` | `/ready` | Runtime/authoritative-database readiness |
| `POST` | `/transaction-commands` | Execute or resolve one typed transaction command |
| `GET` | `/transactions/{transaction_id}` | Read current authoritative transaction state |
| `GET` | `/receipts/{transaction_id}` | Derive the canonical completed-sale receipt |
| `GET` | `/register-context` | Read current register and open-shift state |
| `GET` | `/cashiers` | List active configured cashiers |
| `POST` | `/shifts/open` | Open or resolve a shift for one cashier |
| `POST` | `/shifts/{shift_id}/close` | Close or resolve an idle shift |
| `GET` | `/shifts/{shift_id}/cash-summary` | Read authoritative shift cash accountability |

No command-specific mutation routes exist. The one command endpoint mirrors
`transaction-service-execute-command` and prevents route handlers from
reimplementing command dispatch or retry semantics.

## Command request

`POST /transaction-commands` requires `Content-Type: application/json`.
Parameters such as `charset=utf-8` are accepted. A missing or non-JSON content
type returns `415 Unsupported Media Type` with code
`unsupported_media_type`.

The local server's native request reader rejects bodies larger than 64 KiB
before this handler receives or decodes them. A request-reader rejection has no
typed command outcome; a client that had already established a logical command
must retain its exact command identity while resolving any transport
uncertainty.

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

The six current Schema v1 command types are `start_transaction`,
`scan_barcode`, `tender_cash`, `complete_transaction`, `remove_line_item`, and
`void_transaction`. Removal carries exactly one nonnegative, zero-based
`line_index`; void carries an empty payload. The expected stream version binds
a line index to the authoritative line list the caller observed. Structural
index errors return `400`, while an exact nonnegative index that is not present
is a durable domain rejection.

### Scoped approval for a fresh whole-sale void

Before a **fresh** `void_transaction`, the authenticated owning operator calls
`POST /approvals/transaction-void` with `Content-Type: application/json` and
exactly these fields:

```json
{
  "command": {
    "schema_version": 1,
    "command_id": "cmd-void-001",
    "transaction_id": "txn-001",
    "expected_version": 3,
    "command_type": "void_transaction",
    "payload": {}
  },
  "approver_operator_id": "supervisor-01",
  "approver_pin": "80421637"
}
```

The approver must be a different active supervisor or manager with an enrolled
PIN. No approver login or register-session switch occurs. The response uses
`Cache-Control: no-store` and contains `ok: true` plus `approval` with
`approval_token`, `expires_at_epoch_ms`, `approver_operator_id`, and
`approver_display_name`. The opaque token expires after 90 monotonic seconds,
is bound to the exact requester and command, and is unusable after POS Core
restart or replacement by a new grant for the same command.

The client first persists the exact command for recovery, then POSTs it to
`/transaction-commands` with its normal bearer and one separate
`X-Grocery-POS-Approval: gpos_a1_...` header. The approval token is never a
Schema v1 command field. Supplying the header on a non-void command returns
`400 unexpected_approval` without consuming a grant. A fresh void lacking a
valid grant returns `403 approval_required` with
`retry_same_command_id: true` and creates no durable command effect. The
client keeps the exact pending command, discards the old token, and seeks a new
approval for that same ID. An exact already-durable void retry by its original
actor requires no new approval. Approval credential/role failures use generic
`403 approval_not_granted`; malformed requests return 400, stale targets 409,
and genuine security-state unavailability 503. See
[Supervisor / Manager Approval](../security/scoped-manager-approval.md).

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
`line_item_not_found`, `invalid_transaction_state`,
`stale_expected_version`, `stream_version_conflict`,
`register_not_configured`, `shift_required`, or
`shift_has_active_transaction`.

`start_transaction` keeps its existing wire shape. POS Core, not Flutter,
resolves the configured register and active shift. A new production start
requires an open idle shift; no operational identity or timestamp is accepted
from the command body.

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
    "owned_by_authenticated_operator": true,
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
    "tax_minor_units": 20,
    "total_minor_units": 219,
    "tendered_cash_minor_units": null,
    "change_due_minor_units": null
  }
}
```

Current status values are exactly `open`, `paid`, `completed`, and `voided`.
All currency values are exact JSON integer minor units.
`subtotal_minor_units` is the sum of stored base line prices,
`tax_minor_units` is the sum of stored rounded line tax, and
`total_minor_units` is their authoritative Racket-calculated sum.
Tender sufficiency and change use that tax-inclusive total. Tender and change
fields remain present as JSON null before tender. The response contains no
command receipts, event history, database row IDs, or journal metadata.
`owned_by_authenticated_operator` is a server-derived exact relationship to
the authenticated operator. It is used to bind legacy local recovery after a
terminal command releases the active shift slot; it is not client authority,
and every later mutation is independently authorized by Racket.

An accepted line removal is visible only through a subsequent authoritative
query. It removes exactly one current line and its stored price/tax
contribution. A voided projection retains the cancelled line list, subtotal,
tax, and total, while tender and change remain null. `voided` is terminal; it
describes a cancelled open basket and is not completed revenue.

A missing transaction returns `404 Not Found` with code
`transaction_not_found`. A journal or replay recovery failure returns
`500 Internal Server Error` with code `transaction_recovery_failed`. An
unexpected query exception returns the generic code `internal_error`. None of
these responses exposes an internal exception message.

## Canonical completed-sale receipt query

`GET /receipts/{transaction_id}` is a read-only exact lookup. It loads and
replays the same authoritative journal stream as the transaction query, then
requires the reconstructed status to be `completed`. It takes no command ID or
expected version and never reads current catalog/tax data for sale facts.

A successful response is:

```json
{
  "ok": true,
  "receipt": {
    "schema_version": 1,
    "transaction_id": "txn_001",
    "transaction_version": 4,
    "line_items": [
      {
        "barcode": "049000001234",
        "description": "Test Apples",
        "unit_price_minor_units": 199,
        "tax_category_id": "development-standard",
        "tax_rate_millionths": 100000,
        "tax_amount_minor_units": 20
      }
    ],
    "subtotal_minor_units": 199,
    "tax_minor_units": 20,
    "total_minor_units": 219,
    "tendered_cash_minor_units": 500,
    "change_due_minor_units": 281
  }
}
```

Lines are the final retained sale lines after append-only corrections. Legacy
untaxed lines use JSON null for category/rate and zero line tax. All monetary
fields are exact integer minor units; Flutter must not reconstruct them.

An unknown stream returns `404 transaction_not_found`. An existing open, paid,
or voided transaction returns `409 receipt_not_available` with reason
`transaction_not_completed`. Journal/replay corruption returns the same safe
`500 transaction_recovery_failed` code as authoritative transaction recovery.
Receipt Schema v1 contains no status, generated receipt ID, or fabricated
timestamp. See [Canonical Completed-Sale Receipts](receipts.md).

New transactions with recorded operational context return Receipt Schema v2.
It retains all v1 line/money fields and adds exact historical values:

```json
{
  "schema_version": 2,
  "transaction_id": "txn_001",
  "transaction_version": 4,
  "register": {
    "register_id": "register-front-01",
    "display_name": "Front Register 1"
  },
  "cashier": {
    "cashier_id": "cashier-001",
    "display_name": "Alice"
  },
  "shift_id": "shift_...",
  "started_at_epoch_ms": 1787500000000,
  "completed_at_epoch_ms": 1787500030000,
  "line_items": [
    {
      "barcode": "049000001234",
      "description": "Test Apples",
      "unit_price_minor_units": 199,
      "tax_category_id": "development-standard",
      "tax_rate_millionths": 100000,
      "tax_amount_minor_units": 20
    }
  ],
  "subtotal_minor_units": 199,
  "tax_minor_units": 20,
  "total_minor_units": 219,
  "tendered_cash_minor_units": 500,
  "change_due_minor_units": 281
}
```

Identity and time come from transaction replay, not current configuration or
query time. Legacy completed streams keep the exact v1 response.

## Register and shift operations

`GET /register-context` returns a legitimate unconfigured state rather than an
error:

```json
{
  "ok": true,
  "register_context": {
    "configured": false,
    "register": null,
    "active_shift": null
  }
}
```

When configured, `register` contains exact ID/display name. `active_shift` is
null or contains its snapshotted register/cashier identity,
`opened_at_epoch_ms`, nullable `closed_at_epoch_ms`, and nullable
`active_transaction_id`.

`GET /cashiers` returns only current active cashier IDs/display names to
authorized supervisor and manager sessions. These are operational attribution
references, not authentication credentials; ordinary shift opening does not
use this directory to select another identity.

`POST /shifts/open` requires exactly:

```json
{
  "opening_cash_minor_units": 10000
}
```

Opening cash is an exact nonnegative integer. POS Core derives the cashier from
the authenticated operator and configured same-ID active cashier, supplies
register/name/time/shift ID, and atomically records the opening cash movement.
A successful response contains both `shift` and an authoritative permission-
scoped `cash_summary`: limited for an ordinary cashier's open shift, full for a
read-any supervisor or manager. Repeating the same-cashier open resolves the
existing shift without changing its opening amount; a different cashier
conflicts. Stable errors
include `register_not_configured`, `cashier_not_found`, `cashier_inactive`, and
`shift_already_open`.

`POST /shifts/{shift_id}/close` requires:

```json
{ "counted_cash_minor_units": 14194 }
```

The exact nonnegative physical count is reconciled by POS Core. Success returns
the closed `shift` and immutable `cash_summary`, including signed
`over_short_minor_units`. It returns an already-closed
shift and first reconciliation safely, but an open shift with an active transaction returns
`409 shift_has_active_transaction`. Other stable errors include
`shift_not_found` and `cash_accounting_unavailable` for a closed legacy shift.
Unexpected/corrupt operational state fails as the safe
generic `500 internal_error` without SQL or internal detail.

`GET /shifts/{shift_id}/cash-summary` returns:

```json
{
  "ok": true,
  "cash_summary": {
    "shift_id": "shift_...",
    "status": "open",
    "opening_cash_minor_units": 10000,
    "completed_cash_sale_count": 3,
    "cash_sales_minor_units": 1234,
    "expected_cash_minor_units": 11234,
    "counted_cash_minor_units": null,
    "over_short_minor_units": null
  }
}
```

Closed summaries require counted cash and signed over/short. Ordinary money
fields remain nonnegative exact integers. The summary is backend-derived;
clients must not reconstruct expected cash or variance.

Shift writes are not Transaction Command Schema mutations. They have no
command ID, expected version, `retry_same_command_id`, or Flutter pending
command record. After transport uncertainty, clients explicitly refresh
`/register-context` and the exact shift cash summary. They do not automatically
retry the write.

## Routing and common errors

Recognized routes with the wrong method return `405 Method Not Allowed` and an
`Allow` header:

| Route | `Allow` |
| --- | --- |
| `/health` | `GET` |
| `/ready` | `GET` |
| `/transaction-commands` | `POST` |
| `/transactions/{transaction_id}` | `GET` |
| `/receipts/{transaction_id}` | `GET` |
| `/register-context` | `GET` |
| `/cashiers` | `GET` |
| `/shifts/open` | `POST` |
| `/shifts/{shift_id}/close` | `POST` |
| `/shifts/{shift_id}/cash-summary` | `GET` |

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

The server accepts only literal loopback addresses but is still an application
trust boundary. The surrounding server requires a current process-local bearer
session and passes the server-derived principal to fixed authorization and
durable ownership checks. Transaction Command Schema v1 still embeds no actor,
role, session, or bearer identity. The
server also enforces a native 64 KiB request-body limit and exposes separate
`/ready` infrastructure state. ADR-0018 permits bounded connector-level SQLite
busy retry, never whole-command retry. The transaction API still adds no
payment behavior or external-effect exactly-once semantics. Flutter now has a
typed client and the current start, scan, cash
tender, pre-payment line removal/void, authoritative tax/change, completion,
next-sale cashier slice, and exact completed-sale receipt lookup. Receipt
printing, timestamps, broad sale search, and paid reversal/refund are not part
of the current surface. Shift identity is now server-derived from the
authenticated operator, but the configured cashier snapshot remains durable
business attribution. See [Authorization and Ownership](../security/authorization-and-ownership.md).
The current
single-category line-tax model and on-screen receipt are not claims of
universal tax or fiscal compliance.
