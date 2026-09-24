# Local Security Audit Ledger

Milestone 7 Checkpoint 5 begins security-audit coverage at database migration
v11. It creates no synthetic history. Transaction events remain business truth;
command actor/approver tables remain command authorization evidence. Audit
records are separate chronological security and operations evidence, never
replay or authorization input.

## Storage and integrity

`security_audit_events` stores a positive contiguous sequence, audit event
schema version 1, informational epoch milliseconds, fixed `pos_core` or
`root_cli` source kind, non-secret source instance ID, fixed event type, strict
UTF-8 JSON, and 32-byte previous/current hashes. SQLite triggers prohibit
update/delete and enforce next-sequence and previous-tail linkage. The
application hashes a domain-separated, length-delimited representation with
SHA-256. The first previous hash is 32 zero bytes. Sequence, not wall time,
orders events; a clock adjustment does not invalidate the chain.
The triggers enforce append structure, not cryptographic correctness: a direct
SQL insert with a forged `event_hash` can pass those triggers, but full
application verification rejects it and POS Core then refuses to start.

The full chain is checked at POS Core startup, during validated backup/restore
candidate checks, and by explicit inspection. A corrupt chain prevents normal
startup and backup publication. `/ready` deliberately performs no full scan.
This is local tamper evidence, not protection against a privileged owner able
to rewrite and recompute the database.

## Event coverage

Supported types are `runtime.started`; `auth.login_succeeded`,
`auth.login_failed`, `auth.logout`, `auth.session_expired`,
`auth.session_invalidated`; `authorization.denied`;
`approval.granted`, `approval.not_granted`, `approval.required`;
`transaction.void_resolved`; `shift.opened`, `shift.closed`;
`operator.created`, `operator.role_changed`, `operator.active_changed`,
`operator.pin_enrolled`, `operator.pin_changed`,
`operator.pin_change_failed`, `operator.pin_reset`; and `audit.accessed`.

Events use stable operator/session/command/shift/approval IDs, fixed roles,
actions, reasons and outcome codes, and only minimal event-specific facts.
Unknown claimed login IDs are not recorded merely because someone typed them.
Denied foreign reads retain their public not-found behavior while recording an
internal authorization denial. Exact durable void retry does not duplicate
`transaction.void_resolved`. Approval PIN verification is not a register login
and is not mislabelled as one.

Required evidence rolls back or prevents the associated success: runtime
start, login success, approval grant, fresh approved void resolution, shift
open/close, successful root operator mutation, and root audit access. Durable
actions append in their own existing SQLite writer transaction. Login success
revokes the newly issued in-memory session if its required event cannot be
written. Login failure, logout, observed session expiry/invalidation,
authorization denial, approval rejection, and approval-required are
best-effort; audit failure never reverses the security decision. Best-effort
failure diagnostics are sanitized.
CP6 self-change and root reset append required `operator.pin_changed` and
`operator.pin_reset` inside the credential rotation writer; audit failure rolls
the credential/throttle/grant changes back. A wrong current PIN emits
best-effort `operator.pin_change_failed` without any PIN material. The event
row format remains schema version 1; database schema v12 gates the expanded
fixed vocabulary.
Operational-configuration activation may create same-ID cashier operator
stubs. Each genuinely new principal receives `operator.created` inside the
same activation transaction, in snapshot order; existing principals are not
logged as creations. A failed required append rolls back the entire activation.

If an attempted login replaces the one existing register session but its
required success audit append fails, the new token is revoked and the old
session remains replaced. The register stays locked; it does not fall back to
an unaudited login or revive the previous capability.

## Root inspection

Installed `grocery-pos-audit` requires effective UID 0 and always targets
`/var/lib/grocery-pos/pos.db`. It neither creates nor migrates a missing or
outdated database. It accepts `verify`, `list`, or `list AFTER_SEQUENCE LIMIT`.
The optional sequence is nonnegative and the limit is 1–1000. Output is JSON
lines. Before a successful verify/list result is returned, the CLI verifies
the existing chain and appends `audit.accessed`; if that append fails, no audit
data is returned. A corrupt existing chain is reported safely without appending
to it. `verify` reports `verified_through_sequence` for the pre-access tail and
`access_event_sequence` for its newly appended access row; `event_count` also
describes the pre-access ledger. Another writer can append between verification
and the access write, so the two sequence values need not be adjacent. `list`
appends access first, then selects ascending sequences after the requested
cursor; its own event appears only if it falls within the requested page.

An authenticated operator can repeatedly cause best-effort denial events, so
the local ledger can grow under sustained misuse. CP5 deliberately adds no
retention, deletion, or lossy coalescing. Storage-pressure monitoring and a
bounded operational response require CP6/CP7 qualification; they must not
silently erase security evidence. The x86_64 Flatpak/appliance package outputs
also require qualification on an x86_64 environment because the current
development VM is aarch64.

The ledger is sensitive local employee/security evidence. Default support
bundles include none of its rows, JSON, hashes, or identifiers. No audit HTTP
route or Flutter reader exists. PINs, Argon2 verifiers, bearer or approval
tokens/digests, raw headers/bodies, arbitrary exception text, barcodes,
line items, tender amounts, and drawer counts must never enter audit events.
Validated SQLite backups contain the ledger and verify its chain; there is no
separate audit sidecar or automatic upload.
