# POS Support Diagnostics

## Collect a local bundle

On the packaged appliance, run as root with an explicit destination:

```text
grocery-pos-support collect /var/lib/grocery-pos/support-bundles/CASE.tar.gz
```

The destination parent must already exist and the command never overwrites an
existing file. It builds a private candidate and atomically publishes one
`.tar.gz` archive with mode `0600`. The result stays local: there is no upload,
email, cloud connection, or remote-support channel.

Source development can inspect a temporary database with:

```text
just support-bundle DB OUTPUT.tar.gz
```

Collection is observational and may run while checkout is active. It does not
stop/restart POS Core, run migrations, repair SQLite, force a checkpoint, or run
`quick_check`/`integrity_check`.

## Bundle schema version 1

The archive contains exactly these top-level JSON files:

| File | Allowlisted contents |
| --- | --- |
| `manifest.json` | schema version, random bundle ID, generation time, collector version, section list, explicit exclusions |
| `platform.json` | OS ID/version/variant, kernel release, CPU architecture |
| `package.json` | Grocery POS package name, version, release, architecture |
| `service.json` | selected load/active/sub/unit/result/exit/restart properties |
| `database.json` | file/openability, journal mode, migration versions/status, schema-valid flag, page/freelist sizes, DB/WAL/SHM sizes |
| `api.json` | sanitized public `/health` and `/ready` status fields |
| `storage.json` | total, used, available bytes and usage percentage for the state filesystem |

An unavailable database, stopped API, or failed RPM/systemd/platform/storage
provider becomes a stable availability status. Arbitrary exception or command
output is not serialized, allowing useful partial collection from an unhealthy
register.

## Privacy exclusions

The ordinary bundle never includes:

- `pos.db`, WAL, SHM, or rollback journals;
- backups or displaced recovery databases;
- transaction events, command receipts, receipt contents, catalog, cashier,
  operator/role roster, credential verifier, or shift contents;
- raw journald message text;
- whole configuration files or process environments;
- hostname, machine ID, boot ID, usernames, home paths, serial/MAC/device or
  non-loopback network identifiers; or
- credentials, secrets, keys, tokens, passwords, or payment data.

The design collects an allowlist; it does not copy broadly and attempt later
redaction. Database inspection is structural/read-only and never emits the
absolute DB path or raw SQLite exceptions.

The bundle is still operationally sensitive. Keep mode `0600`, protect it from
cashier access, and transfer it only through a future authenticated/audited
procedure. Retention/pruning and remote upload are not implemented.

For a case requiring deeper local investigation, a technician may deliberately
use `journalctl -u grocery-pos-core` or the explicit
`grocery-pos-db quick-check`/`integrity-check` tools. Raw logs and expensive
integrity scans are not silently folded into ordinary support collection.

On the kiosk appliance, use the separate administrator/VT procedure documented
in [Kiosk Recovery](kiosk-recovery.md). Collection does not require stopping the
cashier presentation or POS Core.
