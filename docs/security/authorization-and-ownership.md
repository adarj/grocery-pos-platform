# Authorization and Ownership

Milestone 7 Checkpoint 3 makes the authenticated operator authoritative for
access to POS functions and resources. Authentication still answers who holds
the register session. Authorization in Racket answers whether that operator
may perform the requested action on the referenced durable resource.

Flutter receives safe permission identifiers for presentation, but it cannot
grant access. Hiding a button is not an authorization boundary.

## Fixed policy

The roles remain `cashier`, `supervisor`, and `manager`. Grants are explicit;
there is no rank comparison or wildcard permission.

| Permission | Cashier | Supervisor | Manager |
| --- | ---: | ---: | ---: |
| `register.read` | yes | yes | yes |
| `cashier_directory.read` | no | yes | yes |
| `transaction.read.own` | yes | yes | yes |
| `transaction.read.any` | no | yes | yes |
| `transaction.operate.own` | yes | yes | yes |
| `receipt.read.own` | yes | yes | yes |
| `receipt.read.any` | no | yes | yes |
| `shift.open.own` | yes | yes | yes |
| `shift.close.own` | yes | yes | yes |
| `shift.close.any` | no | no | yes |
| `shift.cash_summary.read.own` | yes | yes | yes |
| `shift.cash_summary.read.any` | no | yes | yes |

Unknown roles and permissions deny. A role change does not revoke the bearer
session, but the next request reloads the current role and applies current
grants. `GET /auth/session` returns the refreshed role and deterministic
permission list.

## Ownership

The request never supplies an authorization owner.

* A transaction is owned by its durable operational-context `cashier_id`.
* A receipt is owned through that same transaction context.
* A shift is owned by its durable `register_shifts.cashier_id`.
* Ownership is exact, case-sensitive equality with authenticated
  `operator_id`.

A contextless historical transaction cannot prove cashier ownership. It is
therefore unavailable to own-scoped reads or mutations, while supervisor and
manager read-any access remains possible.

Cashiers can read and operate their own transactions. Supervisors and managers
can read across owners but cannot scan, tender, complete, correct, or void
another operator's transaction. Whole-sale void remains an own-transaction
operation until Checkpoint 4 introduces manager approval.

For cashier transaction and receipt reads, a missing or foreign resource uses
the same not-found-style public result. Knowledge of an ID is not authority.

## Shifts and blind counting

`POST /shifts/open` accepts only `opening_cash_minor_units`. Racket derives the
cashier identity from the authenticated operator and resolves the display name
from current active cashier configuration. A manager or supervisor not
configured as an active cashier cannot open a shift.

Cashiers and supervisors may close only their own shift. A manager may close a
foreign shift, but the final SQLite writer transaction rechecks that the
operator is still an active manager. No role can close a shift whose active
transaction slot is occupied.

An open own-shift summary for a cashier is:

```json
{"shift_id":"...","status":"open","view":"limited"}
```

It contains no opening cash, cash sales, expected cash, counted cash, or
over/short. Supervisors and managers with read-any receive `view: "full"`.
After a count closes the shift, the owner may receive the full reconciliation.
Racket omits sensitive fields rather than relying on Flutter to hide them.

## Durable command actors

Schema v9 adds:

```sql
CREATE TABLE transaction_command_legacy_unattributed_receipts (
  command_id TEXT PRIMARY KEY NOT NULL,
  FOREIGN KEY (command_id)
    REFERENCES transaction_command_receipts(command_id)
    ON DELETE CASCADE
);

CREATE TABLE transaction_command_actor_attributions (
  command_id TEXT PRIMARY KEY NOT NULL,
  operator_id TEXT NOT NULL,
  FOREIGN KEY (command_id)
    REFERENCES transaction_command_receipts(command_id)
    ON DELETE CASCADE
);
```

The actual migration also applies the repository's strict storage-class and
nonempty-text checks. There is intentionally no operator foreign key: durable
command history must survive later operator lifecycle changes.

Migration v9 deterministically inserts every receipt already present at its
cutover into the legacy-classification table. It records no operator and
changes no receipt. A post-v9 receipt is never entered there; it must have an
actor row. Schema validation requires each receipt to have exactly one of the
two provenance forms. If a modern actor row is unexpectedly absent, both the
optimistic and final writer duplicate checks deny recovery rather than applying
the legacy rule.

For every new durable transaction-command outcome, business events and
operational effects (when any), receipt, and actor attribution commit in the
same `BEGIN IMMEDIATE` Unit of Work. Authorization denial writes none of them.

Duplicate lookup is actor-aware both before replay and inside the final writer
transaction:

* same actor plus exact command returns the original durable result;
* same actor plus a different command retains `command_id_reused` behavior;
* different actor receives `authorization_denied` without payload or outcome
  disclosure;
* an exact receipt explicitly classified by migration v9 as pre-v9 remains
  recoverable and remains unattributed;
* an unclassified modern receipt fails closed for every operator.

The attribution is adjacent security metadata. Transaction replay, event
meaning, receipt derivation, pricing, tax, and cash accounting do not consult
it.

## Flutter recovery

Cashier recovery schema v2 stores only `operator_id`, active transaction ID,
and the optional exact pending command. It never stores a bearer token,
session ID, role, permissions, or PIN.

An operator cannot send, refresh, or erase another operator's recovery state.
Legacy schema-v1 state is treated as unbound until current register context
proves the active slot relation, or an authorized transaction query returns the
server-derived `owned_by_authenticated_operator` relationship from durable
operational context. The latter permits exact completion/void retry after the
accepted terminal command has released the active slot. A pending legacy start
whose transaction does not exist remains preserved but unbound; the local file
and knowledge of an ID are never ownership evidence. Failure to prove
ownership preserves and blocks the state rather than assigning or deleting it.

A definitive 403 means the pending mutation did not enter the business
handler. Flutter may clear that pending marker while preserving the active
recovery context. It never generates a replacement command ID to evade denial.

## Boundaries still deferred

Checkpoint 3 does not add manager approvals, approval tokens, approver
attribution, credential reset, editable roles, or a general security audit
ledger. In particular, manager close-any is not yet a durable security-audit
event. Those boundaries are defined by later M7 checkpoints.
