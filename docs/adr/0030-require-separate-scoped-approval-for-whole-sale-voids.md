# ADR-0030: Require separate scoped approval for whole-sale voids

Status: Accepted

Date: 2026-09-22

## Context

ADR-0029 deliberately left an operator's own whole-sale void available while
the approval mechanism was incomplete. A void cancels an entire open sale, so
the first privileged business action needs dual control without changing the
cashier's register session, the transaction actor, or Transaction Command
Schema v1. An accepted response can be lost after durable commit; approval
must not defeat exact-command recovery.

## Decision

The fixed Racket policy grants `approval.transaction_void` only to supervisors
and managers. A different active enrolled operator must authenticate with a
PIN to approve the requester's exact owned void command. The hardened Argon2id
verification, dummy check, durable login throttle, and post-hash credential
re-read are shared with ordinary login, but approval issues no bearer session.
The requesting operator remains the sole register-session operator and the
durable command actor. Self-approval is denied, including for a supervisor or
manager working a till.

Approval produces a 256-bit opaque `gpos_a1_` capability. Only a
domain-separated digest enters SQLite. A separate random process instance ID
and a 90-second monotonic deadline make unused grants invalid after restart,
backup restore, or expiry. The grant binds the requester, approver credential
revision, command ID, transaction ID, command schema and expected version.
Issuing another grant for that command replaces the first. Flutter sends the
capability once in `X-Grocery-POS-Approval`, never inside the command, recovery
file, bearer session, URL or log.

For a fresh void, the existing `BEGIN IMMEDIATE` command Unit of Work finally
checks the digest, instance, scope, deadline, and approver's current active
credential revision and permission. Consumption, any business event and shift
effect, command receipt, requester actor attribution, and approver attribution
commit together or roll back together. An approved durable rejection consumes
the grant and retains both attributions. Missing/invalid approval creates no
durable command result and returns `approval_required` with same-command retry.

Migration v10 adds grants, durable approver attributions, and a deterministic
marker for exactly the void receipts already present before CP4. It never
invents a historical approver. Every void receipt has exactly one of modern
approver evidence or explicit legacy-unapproved classification. Broken modern
evidence cannot become legacy through absence. The CP3 requester actor/legacy
provenance remains independent.

An exact already-durable void is resolved after requester provenance checks
and before requiring new approval. The original actor can recover it after
token disposal, role/session changes, shift closure, or POS Core restart.
Another actor receives generic denial before the payload, outcome, or approval
state is disclosed. Transaction events, receipt derivation, and replay do not
consult approver metadata.

## Consequences and limits

Flutter's approval dialog names the entire-sale action and displays the
requester and current transaction facts. It obtains a grant before persisting
the exact command, persists before POST, then discards the token after the
request. A transport-uncertain pending void retains its command ID but never
its approval token; a subsequent retry either resolves the durable receipt or
asks for a new approval for that same command.

Only whole-sale void uses this approval policy. No manager register session,
general workflow engine, remote approval, or CP5 security audit ledger is
introduced. Grant issuance and failed approval attempts are not yet durable
security-audit events; CP5 owns that separate ledger.
