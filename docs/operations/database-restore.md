# Offline POS Database Restore

## Consequence and authority boundary

Restore replaces authoritative local financial and operational history with one
explicitly selected recovery point. If the selected backup is older than the
lost or damaged database, legitimate later transactions can disappear from the
register's recovered view. Grocery POS therefore never chooses the newest
backup, falls back at startup, or retries alternate backups automatically.

Use restore only after deliberate technician assessment. A file under
`recovery/` is displaced evidence, not automatically a valid backup.

## Appliance command

On the packaged appliance, run as root:

```text
grocery-pos-recovery restore SELECTED-BACKUP.sqlite
```

The target is fixed to `/var/lib/grocery-pos/pos.db`; the privileged command is
not a generic file replacement tool. It does not enable, disable, or preset the
service.

The workflow is:

```text
validate selected backup read-only
  -> copy to /var/lib/grocery-pos/.grocery-pos-restore.<random>.partial
  -> synchronize and validate staged copy read-only
  -> systemctl stop grocery-pos-core
  -> confirm service inactive
  -> preserve canonical DB and sidecars
  -> atomically install staged candidate without overwrite
  -> set grocery-pos:grocery-pos and mode 0640
  -> synchronize file and directory metadata
  -> systemctl start grocery-pos-core
  -> require /ready within 30 seconds
```

Both validations require the Checkpoint 2 contract: a regular nonempty SQLite
file, healthy full integrity check, zero foreign-key violations, exact current
v1-v9 migration history, and valid Grocery POS schema/application invariants.
Validation never migrates, repairs, or converts the backup to WAL.

Before the service stops, a failure removes ordinary staging where safe and
does not touch the live database. If stop fails or the unit remains active,
replacement is refused.

## Displaced-state evidence

Existing regular files at these exact names are moved together where present:

```text
pos.db
pos.db-wal
pos.db-shm
pos.db-journal
```

They are preserved beneath a unique root-owned, mode `0700` directory:

```text
/var/lib/grocery-pos/recovery/<operation-id>/
```

This matters because WAL may contain committed transactions absent from the
main file. Old sidecars never remain beside the replacement database. A
mode-`0600` `restore-manifest.json` records manifest schema version 1, operation
ID/start time, displaced names and sizes, both validation statuses, and current
supported schema version. It contains no POS rows and makes no health claim
about displaced state.

Directories, symlinks, FIFOs, sockets, devices, and other unexpected objects at
canonical database/sidecar names fail closed. Recovery evidence is sensitive,
root-controlled, and never pruned automatically.

## Verification failure

If ownership, service start, or readiness verification fails after
displacement, restore reports a stable error plus the operation/recovery
location where available. A readiness failure stops the service again. Grocery
POS does not automatically roll back to the displaced database because that may
be the damaged state that prompted recovery, and it does not select another
backup.

Stop and preserve both sides for explicit inspection/escalation. Do not
improvise destructive file operations. Whole-device power-loss behavior and a
booted-appliance recovery exercise remain Checkpoint 7 qualification.

On a provisioned kiosk, enter the separate technician VT and stop the graphical
presentation if needed as described in [Kiosk Recovery](kiosk-recovery.md).
The service-aware recovery command itself owns the POS Core offline boundary;
rpm-ostree rollback is not a database restore.

## Development-only primitive

For temporary/test paths, source development exposes:

```text
just db-restore-offline BACKUP DB
```

This command does **not** coordinate systemd. The caller is responsible for
ensuring the target SQLite database is offline. It preserves displaced state in
a sibling `recovery/<operation-id>/` directory and uses the same validation,
staging, sidecar, and no-overwrite primitives.
