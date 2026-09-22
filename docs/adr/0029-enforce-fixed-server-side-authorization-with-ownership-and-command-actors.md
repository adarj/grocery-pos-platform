# ADR-0029: Enforce fixed server-side authorization with ownership and command actors

Status: Accepted

Date: 2026-09-21

## Context

Checkpoint 2 authenticates one active register operator but deliberately treats
every active enrolled operator alike. That is insufficient once a register can
be used by cashiers, supervisors, and managers. The server must distinguish
function grants from ownership of a transaction or shift without making
Flutter an authority.

Durable command receipts add another boundary. A command may be retried after
reauthentication or a POS Core restart. Once authorization exists, returning
Alice's durable result to Bob merely because Bob knows its command ID would
disclose command state and could confuse local recovery ownership. Historical
receipts, however, predate authenticated actor evidence and must not be given a
fabricated identity.

## Decision

Racket owns one fixed, deny-by-default policy for the `cashier`, `supervisor`,
and `manager` roles. Grants are enumerated by stable permission identifiers;
there is no numeric role hierarchy, editable ACL, or Flutter role matrix.
Unknown roles and permissions deny.

Resource ownership comes only from durable server state:

* transaction and receipt ownership uses
  `transaction_operational_context.cashier_id`;
* shift ownership uses `register_shifts.cashier_id`;
* comparison with the authenticated `operator_id` is exact and case-sensitive.

Cashiers may operate and read only their own transactions. Supervisors and
managers may read any transaction or receipt, but may not operate another
cashier's transaction. Managers alone may close another operator's otherwise
closable shift. Opening a shift derives the cashier ID from the authenticated
operator and still requires that operator to be an active configured cashier.

Open own-shift cash summaries returned to cashiers are limited to shift
identity and status. Supervisors and managers may receive the full open
summary. Closed-shift reconciliation is full because an independent count has
already been supplied.

Migration v9 adds `transaction_command_actor_attributions`, keyed by
`command_id`, containing only the authenticated `operator_id`. It also
deterministically classifies every receipt already present at the v9 cutover in
`transaction_command_legacy_unattributed_receipts`, without assigning an
operator or changing the receipt. New durable command outcomes commit their
receipt and attribution in the existing transaction-command Unit of Work and
are never marked legacy. Actor attribution contains no role, display name,
session, credential, or approval state and is not transaction-event or receipt
truth.

An exact attributed command retry returns the original result only to the same
operator, even after role, session, shift, or process changes. A different
operator receives generic authorization denial before payload or outcome
details are compared. Exact receipts durably classified as pre-v9 remain
recoverable for compatibility and remain unattributed; the system does not
claim who originally submitted them. An unclassified receipt with no actor is
a modern integrity defect and recovery fails closed.

Authentication responses include the server-computed effective permission
list in deterministic order. Flutter may use it only to shape presentation.
Every request is independently authorized in Racket.

The existing whole-sale void remains `transaction.operate.own` in Checkpoint
3. Scoped manager approval and approver attribution are deferred to
Checkpoint 4.

## Consequences

* Valid authentication no longer implies access to every POS operation.
* HTTP 401, 403, and 503 have distinct authentication, authorization, and
  security-state-availability meanings.
* `POST /shifts/open` no longer accepts a cashier identity.
* Cashier recovery state is locally bound to an operator, while Racket remains
  authoritative for ownership.
* Backup and restore naturally preserve command actor attribution in SQLite.
* Historical receipts have an explicit durable classification rather than
  guessed actor history or an ambiguous missing actor row.
* Manager close-any is not yet represented by a general security audit event;
  the append-only security audit ledger is deferred to Checkpoint 5.

## Rejected or deferred alternatives

* role ordering or implicit role inheritance;
* editable/custom roles or generic IAM;
* client-supplied operator, role, or owner claims;
* Flutter-only permission enforcement;
* manager transaction takeover;
* fabricated historical actor backfill;
* actor identity in transaction events or canonical receipts;
* manager approval, approval tokens, and the security audit ledger.
