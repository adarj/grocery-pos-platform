# Local POS Database Maintenance

## Safety boundary

The configured live POS database is the authoritative source of local
transaction and cash-accountability truth. A backup is an offline recovery
artifact, not an alternate database that the runtime may select automatically.

Maintenance inspection opens its target read-only. It does not create a
missing database, establish WAL, migrate an older schema, repair corruption,
force a checkpoint, or change connection durability settings. Normal writable
access to the live database continues to use the production policy documented
in [ADR-0018](../adr/0018-use-wal-with-full-synchronous-durability.md).

All commands emit small structural JSON documents. They do not dump tables,
events, command payloads, customer data, or other database contents.

## Database information

Run:

```text
just db-info DB
```

The report includes:

- whether the main path exists, is a regular file, and can be inspected
  read-only;
- effective journal mode;
- canonical applied migration history, highest applied version, and current
  software-supported version;
- migration status: `current`, `supported-prefix`, `unsupported`, `missing`,
  `invalid`, or an availability/file failure status;
- whether known schema/application invariants validate for the recorded
  supported migrations;
- page size, page count, and freelist count when SQLite can report them; and
- main database, `-wal`, and `-shm` presence/sizes.

This is observational. It does not run `quick_check` or `integrity_check`, and
it does not checkpoint WAL merely to make file sizes look smaller.

## Integrity checks

For SQLite's lower-cost check, run:

```text
just db-quick-check DB
```

This executes `PRAGMA quick_check`. Health means exactly one result row whose
value is `ok`; otherwise the returned strings are diagnostics and the command
exits nonzero.

For the full check, run:

```text
just db-integrity-check DB
```

This executes the normal full `PRAGMA integrity_check` and also reports the
number of rows from `PRAGMA foreign_key_check`. SQLite's integrity check covers
low-level database consistency but does not validate foreign-key constraints,
which is why the checks are distinct. Neither SQLite check replaces Grocery
POS migration-history, schema-shape, or application-integrity validation.

These scans are manually invoked maintenance operations. They are not run for
each command, request, health check, or normal POS startup.

## Create a live backup

Run:

```text
just db-backup DB OUTPUT
```

The source must be an existing authoritative database already operating under
the WAL/FULL production policy and at the exact current Grocery POS schema.
The output parent directory must already exist. `OUTPUT` must not exist and
must not resolve to the source path. The command never overwrites an existing
final backup.

The backup pipeline is:

```text
verify exact current live source
  -> VACUUM INTO same-directory unique .partial candidate
  -> release live-source maintenance connection
  -> open candidate read-only
  -> full integrity_check
  -> foreign_key_check
  -> exact migration-history and POS schema/application validation
  -> same-filesystem atomic rename to OUTPUT
```

The `VACUUM INTO` filename is parameter-bound rather than interpolated into
SQL. The result is a consistent standalone SQLite snapshot; raw `cp` of a live
WAL main file, or manual copying of DB/WAL/SHM sidecars, is not the canonical
backup procedure.

Backup creation can run while POS Core has the source database open. It uses a
separate production-policy connection and does not enter the transaction-command
Unit of Work. The operation consumes I/O, CPU, and space, and a checkpoint or
large snapshot can affect latency, so operational scheduling and load
qualification remain future work.

## Validate a backup artifact

Run:

```text
just db-backup-validate BACKUP
```

Validation requires a regular nonempty file, healthy full integrity results,
zero foreign-key violations, exact current migration history through v6, and
all current Grocery POS schema/application validators. It is strictly
read-only: no migration, WAL conversion, repair, or restore is attempted.

An offline backup is not required to report WAL journal mode. If it is later
restored through the future explicit restore workflow, the authoritative
database will again be placed under the production connection policy.

## Partial and publication semantics

Generation uses a cryptographically unique hidden name ending in `.partial`
in the final destination directory. A handled failure removes that candidate
when practical and never creates the final name. A hard interruption can leave
a partial artifact; partial files are not published backups and are never
selected automatically. This checkpoint intentionally provides no automatic
partial cleanup.

After validation, Linux `renameat2` with `RENAME_NOREPLACE` performs a
non-overwriting same-filesystem atomic rename. The command fails closed if that
primitive is unavailable or the final name appears during publication. Final
name appearance is therefore the namespace signal that validation completed.
This boundary does not yet claim exhaustive durability under every filesystem,
mount option, sudden-power-loss, or storage-device failure; that qualification
belongs to later Milestone 6 testing.

## Recovery and data protection limits

The runtime never falls back to a backup. A valid older snapshot may still omit
legitimate later sales, so a missing or damaged authoritative database fails
closed. Restore and recovery-point selection will be explicit offline
technician operations in a later checkpoint.

Backup files contain store operational and financial data and must be protected
like the live database. Encryption at rest, technician authorization,
production filesystem ownership/permissions, retention and pruning,
off-machine replication, and cloud upload are not yet defined. Do not include
database or backup contents in ordinary logs or support bundles.
