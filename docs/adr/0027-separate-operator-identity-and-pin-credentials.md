# ADR-0027: Separate operator identity from cashier attribution and store local PIN credentials with Argon2id

Status: Accepted

Date: 2026-09-13

## Context

The M6 register stores a current operational cashier snapshot and immutable
cashier attribution in shifts and transaction events. Those records answer who
operated a till; they are not an authentication authority. M7 needs durable
application principals and credentials without rewriting historical business
facts or confusing POS identities with Linux service, kiosk, root, or
technician accounts.

Register-configuration activation replaces the current cashier snapshot. If
credentials lived only in that snapshot, an ordinary operational update could
delete security state. Authentication must also remain local-first and survive
SQLite backup and restore without relying on a cloud identity provider or an
unbacked external secret.

## Decision

Add migration 7, `create_operator_identity_credentials`, with authoritative
`operators`, `operator_roles`, and `operator_pin_credentials` tables. Existing
cashier IDs become same-ID operator principals with role `cashier`, but receive
no credential. IDs remain opaque, case-sensitive, non-empty strings. Operators
may exist without cashier rows, and the fixed roles are exactly `cashier`,
`supervisor`, and `manager`.

Operational cashier configuration and security identity remain related but
distinct. Activating a cashier snapshot creates a same-ID cashier-role operator
stub only when none exists. It never deletes an operator or overwrites an
existing operator's role, active state, display name, credential, or credential
revision.

Store local PIN verifiers as Argon2id PHC strings with baseline parameters
`m=19456 KiB`, `t=2`, and `p=1`. PINs are exactly 8–12 ASCII digits and reject a
small deterministic set of trivial patterns. The PHC string contains the
random salt and work parameters. Do not store plaintext, a reversible value, a
second fast hash, or a pepper. Initial enrollment writes credential revision 1
and cannot replace an existing credential.

Provide a root-only local `grocery-pos-auth` bootstrap tool fixed to
`/var/lib/grocery-pos/pos.db`. PIN enrollment uses a twice-entered no-echo
terminal prompt and never accepts a PIN in argv. The tool neither creates nor
migrates a database. No default operator, manager, shared PIN, or credential is
created by migration, packaging, or provisioning.

## Rationale

The same-ID rule preserves current cashier references and historical
attribution while giving security state an independent lifetime. SQLite remains
the local credential authority and existing validated backup/restore mechanisms
carry credentials with the rest of authoritative state. Argon2id supplies a
memory-hard, salted password-hash format with self-describing parameters.

No pepper is introduced because a recovery-critical external secret requires a
separate appliance key-backup and recovery design. A local root tool establishes
the first principals without creating an HTTP bootstrap endpoint or depending
on cloud availability.

## Consequences

- A migrated M6 register is ready with credential enrollment required for each
  cashier; this checkpoint does not enforce login yet.
- Removing a cashier from operational configuration does not revoke or delete
  the operator principal. Explicit security administration owns that decision.
- Credential hashes are included in controlled authoritative database backups
  and excluded from ordinary support bundles.
- Argon2 work occurs outside SQLite writer transactions; SQLite arbitrates the
  final first-enrollment race inside `BEGIN IMMEDIATE`.
- Root administration performed in this checkpoint does not yet produce the
  future M7 security-audit ledger.

## Rejected or deferred alternatives

Linux accounts as POS operators, cloud-required authentication, default manager
credentials, shared store PINs, custom roles, plaintext/reversible/fast PIN
storage, bcrypt/PBKDF2 substitution, a pepper without recovery design,
credential deletion/reset, HTTP login, bearer sessions, throttling,
authorization, manager approval, transaction actor attribution, and a security
audit ledger are rejected or deferred.

