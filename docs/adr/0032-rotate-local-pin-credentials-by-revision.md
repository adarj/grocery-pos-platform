# ADR-0032: Rotate local PIN credentials by revision and recover through root administration

Status: Accepted

Date: 2026-09-24

## Context

Initial PIN enrollment alone cannot support an operator who knows the current
PIN and wants to change it, or a technician recovering a forgotten PIN. A
bearer request authenticated immediately before a reset can also wait for a
SQLite writer; checking the bearer only at HTTP entry would let old credential
authority commit a fresh mutation after the reset.

## Decision

Migration v12 adds `requester_credential_revision` to unconsumed whole-sale
void grants. Migration discards old unconsumed grants, which are already
process-instance-invalid after the restart needed for migration. It preserves
receipts, actor/approver attributions, legacy provenance, and audit history.

An authenticated operator may call `POST /auth/change-pin` with current and
new PINs. The current PIN is verified with the existing hardened Argon2id and
throttle machinery; the new PIN must satisfy enrollment policy. On success the
credential is updated in place, its revision increments, throttle clears,
unconsumed grants involving the operator are revoked, and required
`operator.pin_changed` evidence appends in one writer transaction. The current
bearer is invalidated and Flutter locks without sending a separate logout.
Transport uncertainty also locks locally without blindly retrying the POST.

The root-only `grocery-pos-auth operator reset-pin OPERATOR_ID` path does not
require the old PIN. It uses secure interactive TTY entry, a preliminary
revision read, Argon2 hashing outside the writer, and the same conditional
rotation primitive with required `operator.pin_reset` evidence. It may reset
an inactive operator without enabling that account. Root is an OS recovery
trust anchor, not a POS operator, manager, or hidden master credential.

For fresh transaction commands, shift open/close, approval issuance, and void
consumption, the final SQLite writer boundary checks current active operator
state, permission, and the credential revision of the authenticated principal.
Already-durable exact command retries remain exempt from historical revision
reauthorization: they recover an outcome, not create a new one. A still-pending
same-operator command can be retried under a new session/revision with the same
command ID. A pending void needs a new scoped approval after rotation.

Actual role/active changes and credential rotations revoke unconsumed grants
for either requester or approver, preventing disable/re-enable or
demote/re-promote from reviving an old grant. No-op role/active assignments do
not revoke. No credential deletion, default PIN, master PIN, automatic service
restart, or remote reset is introduced.

## Recovery consequences

An explicit offline database restore makes the selected backup's credentials,
revisions, roles, throttle, command evidence, and audit ledger authoritative.
An older backup may therefore restore an older PIN. The displaced database is
preserved as evidence; security rows are not merged. POS Core restart drops
all bearer sessions and makes old process-bound approval grants unusable.
An older binary supporting only v11 must refuse v12; OS rollback is not a
database downgrade. Create a fresh validated backup after schema upgrade.

Read operations authenticated just before a reset may finish; the hard
revocation guarantee is that no fresh consequential mutation under the old
revision commits after the reset writer commits. Audit retention and cloud
recovery remain outside this checkpoint.
