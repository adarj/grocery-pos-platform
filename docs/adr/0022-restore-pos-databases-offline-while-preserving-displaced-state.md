# ADR-0022: Restore POS databases offline while preserving displaced state

Status: Accepted

Date: 2026-09-11

## Context

The authoritative POS database contains financial and operational history. The
service already refuses to bootstrap an empty database after data loss, and
validated backups now exist. A technically valid older backup can nevertheless
omit legitimate later transactions, so recovery-point selection cannot be an
automatic runtime decision.

SQLite sidecars also matter during recovery. In particular, a WAL can contain
committed changes not yet checkpointed into the main database. Restore changes
the most consequential local persistence boundary and must not destroy the
state that motivated investigation.

## Decision

Restore is explicit, offline, and technician-initiated. The technician selects
one backup. Grocery POS validates it, copies it to a private random staging file
beside the canonical database, synchronizes the copy, and validates that staged
copy independently before service interruption.

The appliance command requires root, stops `grocery-pos-core` through systemd,
and confirms that the service is inactive before canonical state changes. It
preserves each regular `pos.db`, `pos.db-wal`, `pos.db-shm`, and
`pos.db-journal` that exists in a unique root-only
`/var/lib/grocery-pos/recovery/<operation-id>/` directory. Unexpected objects
and canonical-path symlinks fail closed.

The staged candidate is installed with Linux same-filesystem
`renameat2(RENAME_NOREPLACE)`. File contents and relevant containing
directories are explicitly synchronized. The canonical file is set to
`grocery-pos:grocery-pos` mode `0640`, then POS Core is started and must reach
`/ready` within 30 seconds before restore is declared successful.

Post-install start or readiness failure stops/leaves POS Core stopped. It does
not reinstall the displaced database, select another backup, or erase either
side. A root-only schema-versioned manifest records only operational metadata;
it does not claim that displaced state is a valid backup and does not write a
synthetic transaction event into the restored database.

## Consequences

- Recovery is slower and more deliberate than blind replacement.
- Double validation minimizes the actual service-offline interval and detects
  failed or changed transfers before displacement.
- Preserved database and sidecar evidence consumes disk and remains sensitive.
- Failure after displacement can intentionally leave POS Core stopped for an
  explicit technician decision.
- File and directory synchronization provides a deliberate Linux durability
  boundary, but arbitrary storage/controller power-loss qualification remains
  Checkpoint 7 work.

## Rejected or deferred alternatives

Automatic newest-backup restore, startup fallback, overwrite-in-place,
deleting WAL before preservation, restoring while POS Core runs, automatic
rollback to displaced state, alternate-backup retries, recovery retention and
pruning, and cloud recovery orchestration are rejected or deferred.
