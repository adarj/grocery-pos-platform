# Operator Identity and PIN Credentials

## Boundary

An operator is a local application principal stored in authoritative SQLite.
It is not the Fedora `grocery-pos` backend user, the `grocery-pos-kiosk`
presentation user, root, or a technician's administrator account.

Migration 7, `create_operator_identity_credentials`, adds:

```text
operators
  operator_id       non-empty, opaque, case-sensitive text
  display_name      non-empty text
  active            strict integer 0/1

operator_roles
  operator_id       one primary-key/FK row per operator
  role              cashier | supervisor | manager

operator_pin_credentials
  operator_id       optional primary-key/FK row
  password_hash     Argon2id PHC string
  credential_revision  integer >= 1
```

A missing credential row means `credential enrollment required`. The safe
operator domain representation reports identity, active state, role,
enrollment state, and credential revision; it does not expose the PHC verifier.
Roles are durable attributes in this checkpoint, not yet a permission matrix.

## Cashier compatibility

For a person who can operate a till, `cashier_id` is also `operator_id`.
Migration backfills every existing cashier as a same-ID operator with the same
display name and active value, role `cashier`, and no credential. It does not
rewrite shifts, transaction events, receipts, or other M6 state.

Register configuration remains an operational full snapshot. Activation creates
a cashier-role operator stub when a new cashier ID has no operator. If the
operator already exists, activation preserves that operator's role, credential,
revision, active state, and identity display name. Removing a cashier does not
remove its operator; re-adding the same exact ID reconnects to the existing
security principal. A manager or supervisor who appears in a cashier snapshot
is not demoted.

## PIN enrollment policy, verification, and storage

A newly enrolled PIN must be exactly 8–12 ASCII characters from `0` through
`9`. Input is not trimmed. Enrollment rejects:

- one digit repeated for the whole PIN;
- a one- or two-digit motif repeated for the whole PIN; and
- simple ascending or descending numeric sequences, including wraparound.

Production hashing uses Racket `crypto-lib` and explicitly selects its
Argon2id implementation. The frozen baseline is:

```text
algorithm:   Argon2id
memory:      19456 KiB
iterations:  2
parallelism: 1
format:      $argon2id$ PHC password-hash string
```

The library generates a fresh random salt for every enrollment. Initial
enrollment writes revision 1 and never replaces an existing credential. The
service validates and hashes before entering the SQLite writer transaction,
then re-reads the operator and credential state under `BEGIN IMMEDIATE` before
inserting. Concurrent first enrollments therefore have one winner and one
`credential_already_enrolled` result without holding the writer lock during
Argon2 work.

Verification of an existing credential-v1 PIN uses the separately frozen
syntax of exactly 8–12 ASCII digits; it does not reapply the current enrollment
strength rules. Before invoking the native provider, POS Core requires the
stored PHC verifier to have the exact supported Argon2id/v19 parameter profile
and bounded salt/hash encodings. This prevents database-controlled work factors
and ensures future enrollment-policy tightening cannot invalidate an existing
syntactically valid credential.

PIN bytes are cleared where a mutable temporary buffer is practical, but
Racket's garbage-collected runtime cannot promise deterministic whole-process
memory zeroization. The enforceable contract is that PINs are never persisted
in plaintext, serialized to JSON, put in argv, logged, emitted in exceptions,
or included in support bundles.

## Reproducible crypto dependency

Fedora 44 supplies Racket 9.1 and native `libargon2`, but the Fedora 44
`racket-pkgs` payload does not provide the `crypto` collection. The POS Core RPM
therefore carries the exact Racket library collections needed by `crypto-lib`
under `/usr/libexec/grocery-pos-core/vendor/racket/collects` and uses Fedora's
`libargon2` shared library. Its runtime dependencies are `racket`,
`racket-pkgs`, and `libargon2`; it never runs `raco pkg install` on the
appliance.

Nix fetches every Racket collection from an exact upstream Git revision with a
fixed SHA-256 output hash. The packaged provenance manifest at
`vendor/racket/crypto-sources.json` records collection names, versions,
repositories, revisions, hashes, and upstream license declarations. The
repository source for that manifest is
`packaging/fedora/racket-crypto-sources.json`. Package checks compare its pins
with `flake.nix`, load the packaged collections, and perform a real Argon2id
round trip against Nix-provided `libargon2`. No Nix-store path or Nix runtime is
part of the RPM payload.

## Root bootstrap

On an installed appliance, a technician can explicitly establish the first
manager:

```text
sudo grocery-pos-auth operator create manager-local "Store Manager" manager
sudo grocery-pos-auth operator enroll-pin manager-local
sudo grocery-pos-auth status
sudo grocery-pos-auth operator list
```

Enrollment prompts twice with terminal echo disabled. There is no `--pin`
option. The installed command requires effective root and is fixed to
`/var/lib/grocery-pos/pos.db`; `SQLITE_DB_PATH` and `--database` cannot redirect
it. The canonical database must already exist, be nonempty, and validate as the
current schema. The command never creates, migrates, restores, or repairs it.

Other Checkpoint 1 operations are:

```text
grocery-pos-auth operator create OPERATOR_ID DISPLAY_NAME ROLE
grocery-pos-auth operator set-role OPERATOR_ID ROLE
grocery-pos-auth operator enable OPERATOR_ID
grocery-pos-auth operator disable OPERATOR_ID
```

There is no delete or credential-reset operation and no implicit manager. Root
is only the current OS administration boundary; application-level technician
authentication and durable security audit are later M7 work.

## Backup, restore, readiness, and diagnostics

Credentials are authoritative SQLite state. Validated database backup and
explicit offline restore carry the PHC verifier and revision; there is no
separate unbacked credential file or pepper. Protect backups as sensitive POS
data.

Readiness validates current migration 10 DDL and relational invariants but
performs no Argon2 hashing and does not require every operator to be enrolled.
Fresh M7 appliance provisioning reaches schema 10 and creates cashier operator
stubs. An unenrolled register can be persistence-ready, but the Checkpoint 2
terminal remains locked until an administrator explicitly enrolls a usable
active operator.

The ordinary support bundle excludes operator IDs, operator display names,
role rosters, PINs, credential verifiers, and credential rows. Regression tests
place distinctive identity and credential sentinels in a real database and
search every allowlisted bundle member.

## Authenticated-session integration

Checkpoint 2 adds process-local bearer sessions and durable login throttling
without changing this identity/credential model. See
[Authenticated Sessions and Register Lock](authenticated-sessions-and-register-lock.md).
Session validity alone does not grant an operation. Checkpoint 3 reloads the
current role and applies fixed server-side permissions and resource ownership;
see [Authorization and Ownership](authorization-and-ownership.md). Manager
approval for whole-sale void is now defined by
[Supervisor / Manager Approval](scoped-manager-approval.md). General security
audit and credential reset remain deferred.

The files under `docs/acceptance/m6` remain historical evidence for the schema
6 M6 baseline. They are not regenerated to describe current schema 10 code.
