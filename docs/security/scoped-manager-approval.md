# Supervisor / Manager Approval for Entire Sale Void

Checkpoint 4 changes one operation: a fresh `void_transaction` needs approval
from a **different** active supervisor or manager. Scans, line removal, cash
tender and completion remain own-transaction operations. A supervisor/manager
working as the cashier still cannot approve their own void. POS Core, not
Flutter, enforces every rule.

The cashier stays signed in and remains the transaction-command actor. The
approver enters an operator ID and PIN in a dialog that names “Approve Entire
Sale Void,” the requester, transaction ID, item count and total. The approver
does not receive a register bearer session. The same Argon2id/PHC-bound
credential verifier and durable per-operator login throttle used for login
also protect approval; unknown, inactive, unenrolled, incorrect, throttled,
cashier-role and self-approval cases share a generic public failure.

`POST /approvals/transaction-void` requires the cashier bearer and strict JSON
containing the exact Transaction Command Schema v1 void command,
`approver_operator_id`, and `approver_pin`. POS Core verifies current requester
ownership and expected version, then issues a random `gpos_a1_` token. It is
bound to that requester, command, transaction and version, expires after 90
monotonic seconds, and may be replaced only by a newer grant for the same
exact requester, transaction, schema and expected version. A changed scope
under the same command ID is rejected while a live grant exists. The grant
cannot be used after POS Core restart. SQLite stores only a digest and
non-secret scope/evidence, not the raw token or PIN. The response is
`Cache-Control: no-store`.

Schema v12 additionally binds the requester's authenticated credential
revision into every new grant. The final command writer requires grant,
request, and current authoritative requester revisions to agree. PIN rotation
or actual role/active change atomically deletes unconsumed grants involving
that operator as requester or approver; disable/re-enable and demote/re-promote
cannot revive an old capability. Migration from v11 deliberately discards
unconsumed, already process-invalid grants while preserving completed command
attributions. See [Credential Lifecycle and Recovery](credential-lifecycle-and-recovery.md).

Flutter keeps the token only long enough to POST the exact command with
`X-Grocery-POS-Approval`. The command is written to local recovery storage
*before* this business POST. The token, PIN, role and bearer never enter that
record. Cancellation before grant means no pending command. If local
publication fails after grant, no command is sent. A lost response leaves the
same pending command but discards the token. Retry without approval first:
an already-durable exact result returns; otherwise `approval_required` means
the same command ID needs a fresh supervisor/manager approval. Never generate
a replacement ID for this situation.

The final approval check occurs after acquiring the SQLite writer reservation;
it rechecks the requester's active state and own-operation permission as well
as the approver's current authority and the monotonic expiry. Consumption
occurs inside that same transaction as the void outcome, receipt, requester
actor and durable approver evidence. Every durable outcome, including a version
conflict, consumes the approval. A persistence failure rolls everything back, including grant
consumption. Legacy pre-v10 void receipts are explicitly classified as
unapproved; no historical manager is fabricated. An unexpectedly missing
modern approver attribution fails closed.

Approver identity and grant rows belong in validated SQLite backup, but an
unconsumed grant restored under a new process instance remains unusable.
Support bundles exclude the DB, grant rows, token digests, approver
attributions, operator rosters, PINs and tokens. Checkpoint 5 now records
grant issuance, rejected ceremonies, approval-required decisions, and fresh
approved void resolution in the separate
[local security audit ledger](security-audit-ledger.md). That ledger does not
replace command-local approver attribution.
