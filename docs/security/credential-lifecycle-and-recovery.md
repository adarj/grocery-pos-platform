# Credential lifecycle and local recovery

Current schema: v12. The same strong 8–12 ASCII-digit PIN policy applies to
initial enrollment, self-change, and root reset. Existing credential-v1 PIN
verification accepts syntactically valid 8–12 digits without reapplying later
enrollment-strength rules. Argon2id remains v19, m=19456 KiB, t=2, p=1.

`POST /auth/change-pin` is bearer-protected and accepts exactly
`{"current_pin":"...","new_pin":"..."}` as JSON. It verifies the current
PIN through the normal throttled verifier, rejects weak or unchanged new PINs,
hashes outside `BEGIN IMMEDIATE`, then conditionally increments the revision.
The successful response contains `credential_revision` and
`reauthentication_required: true`; the old bearer is already invalid. A 400
`pin_policy_rejected` or 403 `credential_change_failed` confirms no change. A
503 `credential_change_unavailable` confirms rollback. If the HTTP response is
lost, Flutter clears PIN fields and bearer, locks, and requires login; it does
not blindly retry the credential change.
An unexpected failure while clearing the already-revision-invalid process-local
session after commit cannot be reported as this definitive no-commit 503.
`operator.pin_changed` and root `operator.pin_reset` audit events retain the
operator ID and exact previous/new integer credential revisions, never PINs or
verifiers. A failed current-PIN check emits only the operator ID best-effort.

For a forgotten PIN, root on the appliance uses:

```text
sudo grocery-pos-auth operator reset-pin OPERATOR_ID
```

The installed wrapper requires an interactive terminal, disables echo, prompts
twice, and never takes a PIN in argv or environment. Reset requires an existing
credential, advances its revision, clears throttle, revokes unconsumed approvals
involving the operator, and records `operator.pin_reset` atomically. It may
target an inactive operator, but does not enable it. For a new unenrolled
operator, use `operator enroll-pin` instead. Enabling is separate.

If no usable approver remains, root may reset an existing supervisor/manager
credential or deliberately create and enroll a new manager. There is no
default, hidden, or master recovery credential. A corrupt schema or audit
chain must be addressed through database diagnosis/restore, not an audit bypass.

Credential rotation does not close a shift or alter transaction ownership.
Operator-bound local recovery records remain schema v2 and do not store
credential revisions, PINs, bearers, or approval tokens. A pending exact
command can resume after the same operator signs in with the new PIN; a
pending void needs fresh independent approval. A committed exact command is
recoverable without repeating its historical authorization decision.

Validated backups contain credential verifiers and are security-sensitive.
Restoring an older selected backup restores its older credential revision and
possibly its older PIN. The restore restarts POS Core, invalidating sessions
and process-bound approvals; no rows are merged from the displaced database.
`/ready` remains runtime/database readiness, not human credential readiness.
Root appliance status separately reports `register_auth_ready`,
`approval_auth_ready`, and `audit_event_count`. Store handoff requires both
readiness booleans. `register_auth_ready` means at least one active, enrolled,
configured cashier; `approval_auth_ready` means at least one active, enrolled
operator with `approval.transaction_void`. These aggregate flags do not prove
that an independent approver exists for every requester. At least two
approval-capable people are recommended because nobody may approve their own
whole-sale void.

Checkpoint 7 must qualify the production x86_64 terminal Flatpak and appliance
bundle on a suitable target/builder; native aarch64 checks do not substitute
for that path. It must also stress repeated invalid logins and authorization
denials, measure audit-ledger database/WAL growth and storage pressure, and
verify checkout availability and backup/restore time with a large ledger.
CP6 adds no audit retention, deletion, or loss of denial evidence.
