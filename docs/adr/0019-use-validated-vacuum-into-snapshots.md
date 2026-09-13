# ADR-0019: Use validated VACUUM INTO snapshots for local POS database backups

Status: Accepted

Date: 2026-09-03

## Context

The local SQLite database contains authoritative transaction, command-recovery,
catalog, tax, register, shift, and cash-accountability facts. It operates under
the WAL and `synchronous=FULL` policy established by ADR-0018. In WAL mode,
committed data may be present in the WAL sidecar rather than the main database
file, so copying only that main file is not a safe live-backup procedure.

Technicians also need explicit, testable inspection and integrity tools. Those
tools must remain useful for an old, non-WAL, malformed, or otherwise suspect
file. Forcing an offline target through the writable production connection
policy could change the evidence being diagnosed. Similarly, automatically
falling back to an older technically valid backup could silently omit later
legitimate financial transactions.

## Decision

The initial canonical live-backup mechanism is SQLite `VACUUM INTO` on a
dedicated production-policy connection to the authoritative source database.
The source must have the exact current Grocery POS migration history and pass
the existing application schema validators before generation begins.

Backup output is generated under a cryptographically unique, visibly
unpublished `.partial` name in the final destination directory. The filename
is passed to SQLite as a bound SQL parameter. The source connection is released
before the candidate is opened independently in SQLite `read-only` mode.

A candidate is publishable only when all of these checks succeed:

- it is a regular, nonempty file;
- `PRAGMA integrity_check` returns exactly one `ok` row;
- `PRAGMA foreign_key_check` returns no rows;
- the canonical migration history exists and is exactly the current supported
  v1-through-v6 history; and
- the existing Grocery POS schema and application-integrity validators pass
  without migration or repair.

Only a validated candidate is atomically renamed within the same filesystem to
the caller-selected final name. On the Linux POS appliance this uses
`renameat2` with `RENAME_NOREPLACE`, so absence of the final name and the rename
are one atomic operation. Existing final paths are never overwritten,
including when one appears during publication. Backup publication fails closed
where that primitive is unavailable. A handled failure removes its partial
candidate where practical. A hard process interruption may leave a clearly
named `.partial` artifact, which is never a published backup.

Database information, quick checking, full integrity checking, and backup
validation use a dedicated read-only inspection boundary. Inspection never
creates a database, establishes WAL, changes synchronous/checkpoint settings,
runs migrations, checkpoints, repairs, or restores data.

The runtime never automatically restores or selects a backup. A missing or
damaged authoritative database continues to fail closed; recovery-point
selection remains an explicit technician operation. ADR-0022 later defines the
offline restore procedure without changing this no-automatic-recovery rule.

## Rationale

`VACUUM INTO` produces a consistent, standalone snapshot while the WAL source
can remain live. It avoids inventing a fragile main/WAL/SHM copying protocol
and is supported directly by the existing Racket/SQLite stack without new FFI
or dependencies.

Independent read-only validation prevents inspection from upgrading or
normalizing the recovery artifact. Full SQLite integrity checking,
foreign-key checking, exact migration history, and the existing application
validators cover distinct failure classes. Same-directory atomic publication
gives backup consumers a clear namespace boundary: appearance of the final
name means the Checkpoint 2 validation pipeline completed.

## Rejected or deferred alternatives

### Copy the live main database file

Rejected because a live WAL database can have committed facts outside the main
file.

### Manually bundle the database, WAL, and SHM files

Rejected as the canonical mechanism because coordinating a consistent live
snapshot and later restore from sidecars is more fragile than producing one
standalone SQLite database.

### Automatically open the newest valid backup

Rejected because technical validity does not prove that a backup includes all
later legitimate financial facts. Recovery-point choice must be explicit.

### Use the SQLite Online Backup API

Deferred. The existing stack supports parameter-bound `VACUUM INTO` without
additional FFI or abstraction. The Online Backup API can be reconsidered only
if measured operational needs justify its complexity.

### Vacuum the authoritative database in place

Rejected. Backup creation must not rewrite the live database as its output
mechanism.

### Repair, restore, retain, encrypt, or upload automatically

Automatic repair, restore, retention/pruning, encryption, off-machine or cloud
replication, and stale-partial cleanup are separate operational and security
decisions.

### Add custom checkpoint management

Rejected for this checkpoint. Inspection remains observational and ADR-0018's
1000-page WAL autocheckpoint policy remains unchanged.

## Consequences

### Positive

- Live backup produces one independently readable SQLite snapshot.
- Invalid or interrupted candidates do not acquire a published final name.
- Inspection and candidate validation do not mutate or migrate their targets.
- Existing migration validators remain the single schema/application-integrity
  authority.
- The final path is never intentionally overwritten.

### Negative

- `VACUUM INTO` is a full, non-incremental operation that consumes I/O, CPU,
  and temporary storage.
- Full candidate validation adds latency proportional to database size.
- A hard interruption can leave a `.partial` file for later manual handling.
- The stored snapshot may use rollback journaling rather than WAL, which is
  acceptable for an offline artifact.
- Atomic rename is the namespace publication boundary; exhaustive filesystem
  and power-loss qualification remains future Milestone 6 work.

## Security and privacy

A backup contains the store's authoritative operational and financial data. It
must be protected like the live database. This decision does not yet define
encryption at rest, technician authorization, service-user permissions,
retention, or remote replication. Maintenance JSON reports only structural
metadata and never database rows or transaction payloads.

## Deferred work

At the time of this decision, restore, appliance ownership/supervision, support
diagnostics, and reliability qualification were deferred. ADR-0021 subsequently
defined the service boundary, ADR-0022 defined explicit offline restore,
ADR-0023 defined support-bundle policy, and ADR-0026 defined evidence-tiered
qualification. Backup scheduling/retention, encryption, off-machine
replication, and the still-unexecuted external qualification campaigns remain
deferred.
