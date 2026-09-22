# Authenticated Sessions and Register Lock

## Authority boundary

Racket is the local authentication authority. Flutter presents a lock screen
and carries a capability, but it never decides whether an operator or token is
valid. Application operators remain distinct from the Fedora `grocery-pos`
backend identity, `grocery-pos-kiosk`, root, and technician accounts.

Migration 8 adds only durable login-throttle state:

```text
operator_login_throttle
  operator_id                 same-ID FK to operators, primary key
  consecutive_failures        integer >= 1
  last_failed_at_epoch_ms     integer >= 0
  blocked_until_epoch_ms      integer >= last_failed_at_epoch_ms
```

It creates no rows by default and changes no transaction, receipt, cashier,
shift, role, or credential fact. Bearer sessions are never stored in SQLite.

## PIN verification and login

New enrollment retains the Checkpoint 1 policy: exactly 8–12 ASCII digits and
no repeated one/two-digit motif or simple ascending/descending sequence. An
existing credential-v1 verifier uses the separately frozen verification syntax
of exactly 8–12 ASCII digits. This separation prevents later enrollment-policy
tightening from making an existing syntactically valid credential impossible
to verify.

Before native Argon2 verification, the stored PHC value must match the Grocery
POS credential-v1 profile: Argon2id, PHC version 19, `m=19456`, `t=2`, `p=1`,
and bounded salt/hash encodings. Malformed, truncated, duplicated-parameter, or
different-profile values fail safely and do not choose arbitrary native work
factors.

`POST /auth/login` accepts exact string fields `operator_id` and `pin`. IDs and
PINs are not trimmed or normalized. Missing, inactive, unenrolled, blocked, and
wrong-credential cases all return the same `authentication_failed` response.
Ineligible identities perform real Argon2id work against a runtime dummy
verifier. Unknown IDs never create durable database rows.

Known-operator failures use this durable schedule:

| Consecutive failure | Blocked period |
| --- | ---: |
| 1–3 | none |
| 4 | 5 seconds |
| 5 | 15 seconds |
| 6 | 30 seconds |
| 7+ | 60 seconds |

Attempts during the blocked period do not test the operator's real verifier,
increment the count, or move the deadline. After 15 minutes without a failed
attempt, the next failure begins a new sequence. Success deletes the row.

## Session capability

A successful login replaces any previous register session and returns an
opaque token shaped as `gpos_s1_` plus 64 lowercase hexadecimal characters.
The random portion contains 256 bits. POS Core stores only a domain-separated
SHA-256 digest plus non-secret session metadata:

- random session ID;
- operator ID;
- credential revision;
- monotonic creation, last-activity, and absolute-expiry times;
- epoch absolute-expiry metadata for the client response.

Idle expiry is five minutes. Absolute expiry is twelve hours and never moves.
Only Racket's process-monotonic clock controls both deadlines, so an operating-
system wall-clock correction cannot extend or prematurely end a session. The
epoch expiry returned to Flutter is informational and is never consulted for
server authentication.
Every protected request revalidates current operator existence, active state,
credential presence, and credential revision. It also loads the current role,
so role changes do not revoke authentication. Disablement, missing credentials,
or revision mismatch invalidate immediately. Successful authoritative
validation refreshes idle activity. A temporary SQLite availability failure
fails the request with `authentication_unavailable` without revoking or
refreshing a capability whose security state could not be checked.

Durable throttle timestamps deliberately remain epoch milliseconds because
they must survive process restart. No-delay tiers are identified by failure
count as well as the stored deadline, so a backward wall-clock correction
cannot turn failures one through three into a blocked interval or prematurely
trigger the 15-minute quiet reset.

Sessions are process-local. POS Core restart intentionally invalidates every
token and returns the register to the lock screen. Throttle rows persist across
restart. Backups therefore contain security principals, credential verifiers,
and throttle state, but never live bearer sessions; restore cannot resurrect a
logged-out session.

## HTTP boundary

Public routes:

```text
GET  /health
GET  /ready
POST /auth/login
```

Protected routes:

```text
GET  /auth/session
POST /auth/logout
POST /transaction-commands
GET  /transactions/{id}
GET  /receipts/{id}
GET  /register-context
GET  /cashiers
POST /shifts/open
POST /shifts/{id}/close
GET  /shifts/{id}/cash-summary
```

Protected requests accept exactly one `Authorization: Bearer TOKEN` header.
Missing, malformed, expired, replaced, logged-out, and unknown sessions share
HTTP 401 `authentication_required`. Authentication responses use
`Cache-Control: no-store`; 401 protected responses include a Bearer challenge.
Tokens are never accepted through URLs, bodies, files, argv, or environment.
HTTP 403 now means `authorization_denied` for a valid session. It neither
revokes the bearer nor returns the missing permission; see
[Authorization and Ownership](authorization-and-ownership.md).

## Flutter register lock and recovery

The terminal checks public liveness/readiness, then presents an explicit
operator-ID and masked PIN lock screen. It does not request register, cashier,
shift, transaction, or receipt state until login succeeds. PIN input is cleared
after every submission and generic failure text does not enumerate operator
state.

The bearer token lives only in `MemoryAuthenticationSession`. It is never
written to `CashierSessionStore`, Flatpak state, preferences, logs, or support
artifacts. Manual lock immediately hides protected routes, clears the token,
and uses only a short-lived captured copy for one best-effort server logout.
Logout failure never restores the token or queues it for later retry. Every
authenticated-to-locked transition replaces the root navigator identity,
disposing the protected subtree and route history before another operator can
enter. User activity resets a five-minute presentation timer; expiry locks
locally even if no API request is made. A definitive protected-route 401
centrally locks the app. A transient 503 remains an availability problem rather
than a false credential failure.

Authentication lifetime is independent from transaction recovery. Locking
does not clear the active transaction or a write-before-POST exact command. If
a command receives 401 before its handler runs, Flutter retains the same
command and ID, reauthenticates, and explicitly retries it. If a command became
durable before POS Core died, restart loses the session but durable command
receipts still return the original one-effect outcome after reauthentication.
Bearer/session identity is not embedded into the command schema.

## Operations, privacy, and limitations

Before deploying the authentication cutover, explicitly create/enroll at least
one active operator with the root-only `grocery-pos-auth` tool. No default
manager or PIN is generated. `/ready` validates schema and persistence health;
it intentionally does not claim that an unlock credential exists.

Support bundles continue to exclude operator rosters, PINs, PHC verifiers,
bearer tokens, Authorization headers, environment dumps, and database content.
Project output must not log those values. The formal security audit ledger is
not implemented yet.

Checkpoint 3 applies fixed role and resource-ownership authorization and
durable transaction-command actor attribution. Manager approval, credential
reset, login/security audit events, cloud identity, and remote authentication
remain deferred.
