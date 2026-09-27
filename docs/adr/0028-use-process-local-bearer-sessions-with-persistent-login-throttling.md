# ADR-0028: Use process-local bearer sessions with persistent login throttling

Status: Accepted

Date: 2026-09-14

## Context

Operator principals and Argon2id PIN credentials are durable local security
state, but an authenticated register session is a short-lived capability. If
bearer sessions were stored in SQLite, database backups could contain active
capabilities and restoring an older backup could resurrect a session that had
already been logged out. Persisting session activity would also add writes to
ordinary POS requests and couple transaction durability to UI login lifetime.

Online PIN guessing needs a different lifetime. Restarting POS Core must not
erase accumulated failures and provide a cheap way around throttling. Login
responses also must not disclose whether an operator is missing, inactive,
unenrolled, blocked, or supplied the wrong PIN.

## Decision

Store at most one register session in a concurrency-safe, process-local POS
Core session store. Issue an opaque `gpos_s1_` token containing 256 random bits
and retain only a domain-separated SHA-256 digest. A separate non-secret random
session ID is available for future audit correlation. Tokens travel only in an
HTTP `Authorization: Bearer` header; they are not cookies, JWTs, query values,
JSON command fields, environment values, files, or command arguments.

Enforce a five-minute idle timeout and a twelve-hour absolute timeout in
Racket using process-monotonic elapsed time. A separately sampled epoch expiry
is response metadata for clients and does not control capability validity.
Authenticated requests refresh only the monotonic idle deadline, and only
after each request re-reads the current operator, active state, credential
presence and credential revision from authoritative SQLite. A transient
authoritative-state failure neither refreshes nor destroys the session. Role is
current rather than session snapshot state. A new login replaces the prior
register session, logout revokes it, and POS Core restart loses all sessions and
locks the register.

Add migration 8, `create_operator_login_throttle`, for durable per-known-
operator failure state only. Failures one through three have no blocked period;
the fourth through seventh use 5, 15, 30 and 60 seconds, with 60 seconds for
later failures. Fifteen minutes without a failure resets the sequence. Requests
during a block use dummy Argon2id verification and neither increment nor extend
the row. Successful authentication removes the row. Unknown IDs never create
durable throttle rows.

Use one process-local login-attempt semaphore to bound concurrent Argon2 work
on the single register. Argon2 executes outside SQLite writer transactions. A
short `BEGIN IMMEDIATE` confirmation re-reads the verifier, credential revision
and active state before issuing a session. Missing/ineligible identities use a
real dummy verifier at the same frozen Argon2id profile, and all account-state
failures share one HTTP 401 response.

Flutter retains its bearer token only in process memory. It starts behind a
register lock, locks on definitive 401 invalidation, and applies a separate
five-minute presentation inactivity lock. Manual or automatic locking never
clears the durable exact-command recovery record; a newly authenticated session
may retry the same pending command ID.

## Consequences

- POS Core restart deliberately invalidates sessions while durable throttle and
  transaction state survive.
- Database backup and restore cannot capture or resurrect bearer capabilities.
- An appliance upgraded to this checkpoint needs at least one active operator
  with an enrolled PIN before the cashier terminal can unlock.
- A role change does not force logout, while disablement, missing credentials,
  or a future credential-revision change does.
- Temporary database failure during session validation returns a fail-closed
  availability error without falsely declaring the credential invalid.
- All authenticated operators temporarily have the same business API access;
  role-based authorization is a later checkpoint.

## Rejected or deferred alternatives

SQLite/filesystem session persistence, JWTs, cookies, multiple simultaneous
register sessions, bearer tokens in URLs or command envelopes, restart session
recovery, process-only throttling, permanent lockout, account-enumerating
errors, fast fake dummy hashing, authentication bypass switches, HTTP
credential enrollment, role authorization, manager approval, credential reset,
actor attribution, and the security audit ledger are rejected or deferred.
