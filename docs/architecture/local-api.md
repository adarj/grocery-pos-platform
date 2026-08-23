# Local POS API Contract

## Status

**Early development contract**.

This document defines the initial communication boundary between local Flutter applications and the Racket POS Core.

The health endpoint and Transaction HTTP API v1 are implemented. The detailed
transaction command/query contract is documented in
[Transaction HTTP API v1](transaction-http-api-v1.md).
That contract also defines exact read-only completed-sale receipt lookup.

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

The service should remain bound to loopback by default unless a future architecture decision intentionally establishes another trusted transport boundary.

Localhost is still treated as an application trust boundary. Backend authorization and business rules must never rely solely on a Flutter UI hiding a control.

## Runtime Composition

The Racket process now constructs its durable transaction service before the
HTTP listener starts. Startup resolves `SQLITE_DB_PATH`, migrates and validates
the POS database through schema v4 using a dedicated connection, and then
builds a bounded SQLite pool plus one thread-mapped virtual connection for
request use.
The service held by the application uses that virtual connection; unrelated
request threads therefore do not share one physical transaction context.

The server application is created through `make-app` with the transaction
service as an explicit dependency. Transaction routes delegate through that
same service rather than reimplementing its idempotency or transaction
semantics. The detailed ownership and shutdown contract is documented in
[Racket POS Core Runtime Composition](racket-runtime.md).

Migration 3 includes the persistent local catalog documented in
[Local Catalog](catalog.md). Live runtime checkout resolves new scans from its
explicitly activated SQLite catalog through the same virtual connection pool;
runtime startup never seeds development merchandise. Migration 4 adds current
tax categories/item mappings; new scans snapshot Racket's exact line-tax
decision and the transaction query exposes authoritative tax.

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

It does not by itself guarantee that every checkout dependency or peripheral is operational.
It remains a liveness endpoint rather than a full database or peripheral
readiness probe.

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
POST /transaction-commands
GET /transactions/{transaction_id}
GET /receipts/{transaction_id}
```

The transaction routes expose the durable typed-command mutation,
authoritative current-state replay query, and canonical completed-sale receipt
derived from that same replay. Receipt lookup creates no command or cashier
recovery record. Command-specific mutation routes, broad sale search, and
speculative transaction operations are deliberately absent.

The domain model should drive the interface, not the reverse.
