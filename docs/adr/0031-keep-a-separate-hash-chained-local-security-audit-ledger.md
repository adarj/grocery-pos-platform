# ADR-0031: Keep a separate hash-chained local security audit ledger

Status: Accepted

Date: 2026-09-23

## Context

The transaction journal is business truth and replay input. Command actor and
approver attributions are durable, command-local authorization evidence. Neither
provides a chronological record of login, denial, account administration, and
security-sensitive operational actions. Reusing transaction events for that
purpose would make business replay depend on security logging.

## Decision

Migration v11 adds an initially empty `security_audit_events` table. It does not
infer events for pre-v11 activity; existing command attribution remains the
historical evidence at that boundary. Each supported schema-v1 audit event has
an exact typed JSON shape. Trusted POS Core or root CLI code supplies event
content; HTTP clients cannot submit audit records. A random, non-secret
per-process/invocation source ID distinguishes writers.

SQLite `BEGIN IMMEDIATE` writers allocate contiguous sequence numbers. The
first row links to a 32-byte zero genesis hash; each later row links to its
predecessor. SHA-256 hashes a domain-separated, length-delimited encoding of
sequence, schema version, epoch metadata, source, event type, exact stored JSON
bytes, and previous hash. Exact owned triggers reject out-of-order inserts,
wrong previous-tail links, updates, and deletes. Startup, candidate backup
validation, restore validation, and root inspection verify the full chain.
Readiness remains a lightweight migration-history probe, not a chain scan.

Consequential durable operations append required evidence inside their
existing writer transaction: approval grants, approved void resolutions, shift
open/close, root operator changes, and operator stubs genuinely created by
operational-configuration activation. `runtime.started` must append before the
listener starts. A login is not reported successful unless its success event
persists; if that append fails, the newly issued process-local session is
revoked. `audit.accessed` must append before root CLI data is returned.
Failure/denial/expiry/logout events are best-effort: an audit-write problem
must never turn a denied request into authorization, keep a logged-out token
alive, or turn a safe rejection into a public secret-bearing diagnostic.

Only root's installed `grocery-pos-audit verify` and `list` commands expose the
ledger. There is no audit HTTP endpoint, Flutter viewer, sidecar audit file,
retention/purge command, or cloud exporter in this checkpoint. The ledger is
included in validated SQLite backups and excluded from default support bundles.
It never feeds transaction replay, receipt derivation, command idempotency, or
authorization decisions.

## Consequences and limits

The ledger is append-only through supported application paths and hash-chained
for local integrity verification. It is tamper-evident against accidental or
unsophisticated modification, not tamper-proof: a privileged database owner
could rewrite and recompute local history. Independent remote anchoring,
signing, retention, and alerting require separate later decisions.
The SQLite triggers verify append order and tail linkage; they do not compute
SHA-256. Full application verification rejects structurally linked rows with
forged event hashes. Repeated authenticated denials can grow the ledger; CP5
does not discard or coalesce that evidence, leaving storage-pressure response
for explicit lifecycle qualification.
