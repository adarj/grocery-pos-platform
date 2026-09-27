# Local POS API Contract

## Status

**Early development contract**.

This document defines the initial communication boundary between local Flutter applications and the Racket POS Core.

The liveness/readiness endpoints and Transaction HTTP API v1 are implemented.
The detailed transaction command/query contract is documented in
[Transaction HTTP API v1](transaction-http-api-v1.md).
That contract also defines exact read-only completed-sale receipt lookup and
the narrow current register/cashier/shift operational routes.

## Purpose

The Local POS API provides a stable boundary between:

```text
Flutter human-facing applications
              ↓
          HTTP / JSON
              ↓
       Racket POS Core
```

The API exists to keep presentation concerns separate from authoritative POS business behavior.

## Ownership Boundary

### Flutter owns presentation

Flutter applications are responsible for:

* rendering POS state;
* collecting user input;
* sending commands;
* presenting backend errors and recovery actions;
* accessibility and human-interface behavior.

Flutter must not independently become authoritative for:

* transaction totals;
* tax calculations;
* promotion eligibility;
* tender state;
* payment completion;
* refund validity;
* manager authorization;
* transaction lifecycle;
* receipt truth.

### Racket owns POS semantics

The Racket POS Core is responsible for:

* transaction state;
* catalog interpretation;
* barcode and PLU behavior;
* pricing;
* taxation;
* promotions and discounts;
* tender orchestration;
* payment orchestration;
* manager authorization rules;
* canonical receipt data;
* local persistence semantics;
* synchronization semantics;
* validation of requested state transitions.

A client requests an operation. The POS Core determines whether the operation is valid.

## Transport

The initial local transport is HTTP with JSON request and response bodies.

Development base URL:

```text
http://127.0.0.1:7340
```

Ordinary POS Core configuration accepts only the literal loopback addresses
`127.0.0.1` and `::1`. It rejects wildcard, LAN/public, and hostname values,
including `0.0.0.0`, `::`, and `localhost`, before database startup. DNS is not
used to infer trust, and there is no remote-listener mode. A future remote API
requires an explicitly authenticated and authorized architecture.

The server enforces a native Racket safety policy of at most 64 concurrent and
64 waiting connections, a 10-second request-read timeout, a 64 KiB request-body
ceiling, a 30-second response timeout, and a 10-second response-send timeout.
Racket's safe defaults remain in force for request lines, headers, multipart
data, and other limits. The body ceiling is enforced by the HTTP request reader
before a POS handler can decode a body.

Loopback is still treated as an application trust boundary. Backend
authorization and business rules must never rely solely on a Flutter UI hiding
a control.

## Runtime Composition

The Racket process now constructs its durable transaction service before the
HTTP listener starts. Startup resolves `SQLITE_DB_PATH`, migrates and validates
the POS database through schema v12 using a dedicated connection after
establishing WAL with FULL synchronous durability. Every production connection
explicitly enables foreign-key enforcement, retains a 1000-page WAL automatic
checkpoint threshold, and uses the bounded Racket connector busy policy.
Request connections verify the database is already WAL before joining the
bounded SQLite pool and thread-mapped virtual connection used for requests.
The service held by the application uses that virtual connection; unrelated
request threads therefore do not share one physical transaction context.

The server application is created through `make-app` with the transaction
service and runtime readiness probe as explicit dependencies. Transaction
routes delegate through that same service rather than reimplementing its
idempotency or transaction semantics. The detailed ownership and shutdown
contract is documented in
[Racket POS Core Runtime Composition](racket-runtime.md).

Migration 3 includes the persistent local catalog documented in
[Local Catalog](catalog.md). Live runtime checkout resolves new scans from its
explicitly activated SQLite catalog through the same virtual connection pool;
runtime startup never seeds development merchandise. Migration 4 adds current
tax categories/item mappings; new scans snapshot Racket's exact line-tax
decision and the transaction query exposes authoritative tax.

Migration 5 adds one current register configuration, a current cashier
directory, and durable shifts. Production runtime composes a register
operations service over the same virtual connection and injects one POS Core
clock and secure shift-ID generator. It never seeds development identities.
New transaction starts resolve operational context inside POS Core and
atomically couple their event/receipt with the active shift slot. See
[Register Operations and Shift Context](register-operations.md).

Migration 6 adds the append-only shift cash ledger and immutable close
reconciliation. Completed cash-sale movement and shift-slot release participate
in the same transaction-command writer boundary. See
[Shift Cash Accountability](cash-accountability.md).

Migration 7 adds operator principals, fixed roles, and optional Argon2id PIN
credentials. Migration 8 adds durable per-known-operator login throttling.
Bearer sessions remain process-local, and the runtime now supplies an explicit
authentication service to the HTTP application. See
[Operator Identity and PIN Credentials](../security/operator-identity-and-pin-credentials.md).

## Authentication

`POST /auth/login` is public and accepts exactly two string fields:

```json
{
  "operator_id": "operator-123",
  "pin": "80421637"
}
```

Successful login returns an opaque 256-bit bearer capability and safe current
operator/session presentation fields. Missing, inactive, unenrolled, blocked,
and wrong-credential cases all return HTTP 401 with
`authentication_failed`; the response never identifies the internal cause.
Malformed request JSON remains a distinct 400 validation failure.

`GET /auth/session` and `POST /auth/logout` require exactly one
`Authorization: Bearer TOKEN` header. Query parameters, cookies, body fields,
environment variables, and files are not bearer transports. Authentication
responses use `Cache-Control: no-store`; missing/invalid protected credentials
return `authentication_required` and a Bearer challenge.

`POST /auth/change-pin` is also bearer-protected. It requires
`application/json` with exactly `current_pin` and `new_pin` string fields;
there is no client-supplied operator ID. The current PIN receives normal
step-up verification and throttle treatment; the new PIN must satisfy the
strong enrollment policy. Success returns
`{"ok":true,"credential_revision":N,"reauthentication_required":true}`
with `Cache-Control: no-store`; the old bearer is already invalidated. A 400
`pin_policy_rejected` or 403 `credential_change_failed` guarantees no
credential mutation; a 503 `credential_change_unavailable` means the writer
rolled back. A transport-lost response is uncertain: the terminal locks and
requires sign-in rather than blindly retrying the PIN-change POST.

`GET /health`, `GET /ready`, and `POST /auth/login` remain public. Every other
implemented business or auth-session route is protected. Authentication runs
before its business handler, so an anonymous transaction command creates no
event, receipt, cash movement, shift change, or command receipt. A genuine
temporary failure while revalidating session security state returns sanitized
HTTP 503 `authentication_unavailable` rather than mislabeling a credential as
invalid.

The server enforces five-minute idle and twelve-hour absolute expiry and checks
current operator active state, credential presence, and credential revision on
every protected request. POS Core restart invalidates all bearer sessions.
Current roles and server-computed effective permissions are returned with
authenticated principal state. Racket applies the fixed role and durable
resource-ownership policy on every request; the Flutter list is a presentation
hint only. See [Authenticated Sessions and Register Lock](../security/authenticated-sessions-and-register-lock.md)
and [Authorization and Ownership](../security/authorization-and-ownership.md).

Valid authentication with insufficient permission returns HTTP 403 with
`authorization_denied`. It does not revoke the bearer session and does not
include the missing permission. Authentication failures remain 401 and a
temporary inability to revalidate security state remains 503.

A fresh whole-sale void also requires the separate
[`POST /approvals/transaction-void`](transaction-http-api-v1.md) ceremony.
The approver's PIN issues no register bearer session. The resulting short-lived
capability is sent only in `X-Grocery-POS-Approval` with the exact void command;
see [Supervisor / Manager Approval](../security/scoped-manager-approval.md).

Checkpoint 5's security-audit ledger is not exposed by HTTP or Flutter. POS
Core records typed local evidence behind these routes; root-only
`grocery-pos-audit` is the inspection boundary. See
[Local Security Audit Ledger](../security/security-audit-ledger.md).

## Health Endpoint

### `GET /health`

Returns basic POS Core process health information.

Example:

```json
{
  "environment": "dev",
  "ok": true,
  "service": "grocery-pos-core",
  "version": "0.0.0-dev"
}
```

The health endpoint confirms that the service is reachable and able to construct its health response.

It does not open SQLite or inspect migrations, catalog, register/cashier/shift
state, peripherals, or cloud services. It remains a process/listener liveness
endpoint.

Unsupported methods return 405 with `Allow: GET`.

## Readiness Endpoint

### `GET /ready`

Reports whether the active runtime can currently establish the authoritative
production SQLite boundary. A ready response is HTTP 200:

```json
{
  "database_schema_version": 12,
  "ok": true,
  "service": "grocery-pos-core",
  "status": "ready"
}
```

A live listener whose runtime or database boundary is unavailable returns HTTP
503:

```json
{
  "ok": false,
  "reason": "database_unavailable",
  "service": "grocery-pos-core",
  "status": "not_ready"
}
```

Stable reasons are:

- `runtime_stopped`;
- `database_missing`;
- `database_unavailable`; and
- `database_schema_not_current`.

The probe requires an active runtime, an existing regular database file, a
fresh production-policy `read/write` connection, a lightweight SQLite query,
and exact-current canonical migration history. The connection is closed after
the probe. Readiness does not create or migrate a database, establish WAL,
inspect business workflow state, run full schema/application validation,
perform `quick_check` or `integrity_check`, or restore a backup.

Readiness is stronger than liveness but weaker than whole-file integrity
certification. Use the explicit Checkpoint 2 maintenance commands in
[Local POS Database Maintenance](../operations/database-maintenance.md) for
deeper checks. `POST /ready` returns 405 with `Allow: GET`.

## JSON Conventions

API payloads use UTF-8 JSON.

Field names should use `snake_case`.

Identifiers should be opaque to clients unless their structure is explicitly documented.

Clients must tolerate JSON object field ordering differences.

## Command Model

State-changing POS operations are modeled internally as strict typed commands
rather than allowing callers to mutate domain state directly. The durable
application-service boundary requires the Transaction Command Schema v1
identity and version fields. `POST /transaction-commands` exposes that boundary
by strictly decoding Schema v1 and delegating to the service without
implementing a separate idempotency policy.

The implemented HTTP request preserves a command envelope resembling:

```json
{
  "schema_version": 1,
  "command_id": "cmd_01ABC...",
  "transaction_id": "txn_01ABC...",
  "expected_version": 2,
  "command_type": "scan_barcode",
  "payload": {
    "barcode": "049000001234"
  }
}
```

The exact transport-independent schema is documented in
[Transaction Command Schema v1](transaction-command-schema.md), and its
idempotency decision is recorded in
[ADR-0011](../adr/0011-use-durable-command-receipts-and-expected-stream-versions.md).

The Flutter terminal now consumes this boundary through a typed `PosCoreClient`
and strict HTTP adapter. Its command, durable-result, authoritative-snapshot,
and failure models are documented in
[Flutter POS Core Client Foundation](flutter-pos-client.md). The implemented
cashier controller and widgets use that boundary for the current start, scan,
cash-tender, completion, open-sale removal/void, recovery, and next-sale
workflow. Completed receipt display and exact historical lookup use the typed
read-only receipt query rather than adding receipt behavior to cashier mutation
orchestration.

### Command IDs and expected versions

Every mutating transaction command has a `command_id` that is globally unique
within the local register database. A retry of the same logical intent must
reuse the same command ID; response uncertainty is not a reason to generate a
replacement ID.

The command also carries the caller's `expected_version`, identifying the last
transaction stream version on which a genuinely new intent was based. The
backend must not silently replace that precondition with the newest stream
version.

The same command ID with the same decoded typed command returns its original
durable outcome and version. The same ID with a different transaction, expected
version, command type, or typed payload is command-ID reuse and executes no
business action. Logical equality is based on the decoded typed command, not
raw JSON bytes.

Known durable retries bypass transaction replay, catalog lookup, domain
decision, and event append. Two simultaneous first submissions can both finish
pure optimistic work before either receipt exists, but final atomic persistence
prevents duplicate accepted facts.

This requirement becomes especially important for:

* tender operations;
* payment requests;
* refunds;
* voids;
* drawer operations;
* remote management commands.

The implemented pre-payment correction commands are `remove_line_item` and
`void_transaction`. Removal addresses one zero-based line in the authoritative
state at `expected_version`; the server checks that version before interpreting
the index. An accepted correction appends a new event, and Flutter waits for a
new authoritative query rather than editing its basket locally. Void is
accepted only from open state, produces terminal `voided`, and retains the
cancelled basket and monetary projection. Paid reversal/refund remains a
separate future contract.

### Mutation outcomes and current state

A mutation response represents the command's original durable
outcome kind, stable machine-readable code, and outcome stream version. It must
not substitute current transaction state for a delayed command retry or expose
provisional state before persistence succeeds.

Current authoritative transaction state and version are obtained through
`GET /transactions/{transaction_id}`. HTTP handlers strictly decode commands,
delegate to `transaction-service-execute-command`, and map its stable result;
they do not reimplement duplicate lookup, expected-version checks, domain
decision, or receipt/event persistence. Exact payloads and status mappings are
specified in [Transaction HTTP API v1](transaction-http-api-v1.md).

## Transaction State

Flutter must render the state reported by the POS Core rather than reconstructing authoritative transaction state from local UI events.

The transaction model is expected to evolve toward explicit states such as:

```text
NoActiveTransaction
TransactionOpen
Subtotaled
Tendering
PartialTendered
PaymentInProgress
PaymentUnknown
Paid
ReceiptPending
ReceiptPrintFailed
Completed
Suspended
Voided
Refunded
RecoveryRequired
```

The current transaction slice implements open, paid, completed, and voided;
the other listed states remain prospective.

Invalid transitions must be rejected by the backend.

## Payment Safety

Payment operations require stricter semantics than ordinary UI commands.

In particular:

> An unknown payment result must never be resolved by blindly submitting another charge.

Before initiating an external payment request, the local system should persist enough request intent to make recovery and reconciliation possible.

Payment APIs will receive a dedicated contract before production payment integration begins.

## Error Model

API errors should be machine-readable and stable enough for Flutter to map them to appropriate user-facing behavior.

Implemented API errors use the common structure below. Individual routes may
add documented stable fields such as `reason` or `retry_same_command_id`:

```json
{
  "ok": false,
  "error": {
    "code": "manager_approval_required",
    "message": "Manager approval is required for this operation.",
    "recoverable": true
  }
}
```

### Error codes

The `code` field is the programmatic contract.

Human-facing applications should not branch on the prose `message`.

Raw Racket exceptions, stack traces, secrets, or unsanitized external-device responses must not be returned to ordinary clients.

## HTTP Semantics

Where practical:

* `2xx` indicates a successfully processed request;
* `400` indicates malformed or invalid input;
* `401` indicates missing authentication where authentication is required;
* `403` indicates an authenticated actor lacks permission;
* `404` indicates an unknown resource or route;
* `409` indicates a valid request that conflicts with current domain state;
* `5xx` indicates an internal service failure.

HTTP 503 is used by `/ready` when the runtime/persistence boundary is not ready
and by protected authentication when authoritative security state is
temporarily unavailable. It does not replace existing domain statuses or
transaction-command uncertainty semantics.

Domain-specific error codes remain necessary even when an HTTP status code is supplied.

## Security

The API must not expose or log:

* full payment card numbers;
* CVV/CVC values;
* magnetic-stripe track data;
* raw sensitive EMV data;
* PINs;
* authentication secrets;
* private keys;
* long-lived access tokens;
* unsanitized terminal payloads containing protected data.

Authorization must be enforced by the Racket POS Core, not merely by Flutter UI visibility.

All externally derived strings and identifiers should be treated as untrusted input and validated at their appropriate boundary.

## Logging and Correlation

As the API evolves, requests should support correlation with structured operational and domain logs.

Useful identifiers may include:

```text
command_id
correlation_id
transaction_id
register_id
actor_id
```

Sensitive values must not be added merely for debugging convenience.

## Versioning

The Local POS API is currently pre-stable and has no formal public version number.

Once independently released clients and backend versions must coexist, an explicit compatibility and schema-versioning policy will be adopted before introducing breaking API changes.

## Testing Requirements

API behavior should be covered by tests at several levels.

Backend tests should verify:

* valid responses;
* invalid request handling;
* invalid domain-state transitions;
* stable error codes;
* command idempotency where applicable.

Flutter tests should verify:

* supported backend states render correctly;
* connection loss is handled;
* structured errors map to appropriate UI states;
* clients do not calculate authoritative business results independently.

The explicit real-process integration suite exercises the complete typed
Flutter client/controller → HTTP → Racket runtime → file-backed SQLite
boundary, including restart and same-command recovery. See
[POS integration testing](../development/integration-testing.md).

## Current Implemented Surface

Currently implemented:

```text
GET /health
GET /ready
POST /auth/login
GET /auth/session
POST /auth/logout
POST /auth/change-pin
POST /transaction-commands
GET /transactions/{transaction_id}
GET /receipts/{transaction_id}
GET /register-context
GET /cashiers
POST /shifts/open
POST /shifts/{shift_id}/close
GET /shifts/{shift_id}/cash-summary
```

The health/readiness/login routes are public; all other routes above require an
Authorization bearer. `GET /cashiers` additionally requires supervisor or
manager permission. Transaction and receipt reads enforce own/read-any scope,
and every transaction mutation enforces durable ownership. The transaction
routes expose the durable typed-command mutation,
authoritative current-state replay query, and canonical completed-sale receipt
derived from that same replay. Receipt lookup creates no command or cashier
recovery record. Transaction snapshots include only a server-derived
`owned_by_authenticated_operator` relationship hint for safe binding of legacy
local recovery after terminal slot release; it does not grant authority.
Command-specific mutation routes, broad sale search, and
speculative transaction operations are deliberately absent.

Shift open/close are operational resource writes, not transaction commands.
They create no command ID or same-command retry marker; explicit
`GET /register-context` and exact shift cash-summary reads resolve transport
uncertainty. Opening and counted cash are exact integer minor units. Flutter
does not calculate expected cash or over/short. Open shift accepts only opening
cash and derives the cashier identity from the authenticated operator. Cash
summary responses are strictly discriminated as `limited` or `full`; the
limited open-own cashier view contains no financial fields. Manager close-any
does not rewrite the shift's cashier snapshot. See
[Authorization and Ownership](../security/authorization-and-ownership.md).

The domain model should drive the interface, not the reverse.
