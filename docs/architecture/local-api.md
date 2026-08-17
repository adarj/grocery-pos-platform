# Local POS API Contract

## Status

**Early development contract**.

This document defines the initial communication boundary between local Flutter applications and the Racket POS Core.

Only the health endpoint is implemented at the time of writing. Transaction APIs will be added incrementally alongside the tested transaction domain model.

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

## JSON Conventions

API payloads use UTF-8 JSON.

Field names should use `snake_case`.

Identifiers should be opaque to clients unless their structure is explicitly documented.

Clients must tolerate JSON object field ordering differences.

## Command Model

State-changing POS operations are modeled internally as strict typed commands
rather than allowing callers to mutate domain state directly. The durable
application-service boundary now requires the Transaction Command Schema v1
identity and version fields, although HTTP transaction routes are not yet
implemented.

A future HTTP request will need to preserve a command envelope resembling:

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

### Command IDs

Every consequential mutating command should have a unique `command_id`.

`command_id` provides the basis for idempotency and retry handling.

Receiving the same command more than once must not accidentally apply the same business action multiple times.

This requirement becomes especially important for:

* tender operations;
* payment requests;
* refunds;
* voids;
* drawer operations;
* remote management commands.

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

Not all of these states are implemented yet.

Invalid transitions must be rejected by the backend.

## Payment Safety

Payment operations require stricter semantics than ordinary UI commands.

In particular:

> An unknown payment result must never be resolved by blindly submitting another charge.

Before initiating an external payment request, the local system should persist enough request intent to make recovery and reconciliation possible.

Payment APIs will receive a dedicated contract before production payment integration begins.

## Error Model

API errors should be machine-readable and stable enough for Flutter to map them to appropriate user-facing behavior.

A future error response should follow a structure similar to:

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

Later integration tests should exercise the complete Flutter → Racket boundary.

## Current Implemented Surface

Currently implemented:

```text
GET /health
```

The in-memory transaction domain and durable idempotent typed-command
application service are implemented, but they are deliberately not exposed as
HTTP routes yet. A transaction API contract will be introduced as a separately
scoped, tested checkpoint rather than as a large speculative REST surface.

The domain model should drive the interface, not the reverse.
