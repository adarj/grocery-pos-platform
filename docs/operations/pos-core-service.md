# POS Core Fedora Service

## Purpose and qualification boundary

The internal `grocery-pos-core` noarch RPM packages the Racket POS Core source,
Fedora service metadata, machine configuration, and technician launchers. It is
the first deployable service boundary for the future Fedora Kinoite register.
It is not yet a complete appliance image, kiosk session, public release, or
final production qualification.

Fedora supplies `/usr/bin/racket` at runtime. Nix reproducibly builds and tests
the RPM, but the installed service does not require Nix, `nix-daemon`, a Nix
store, Distrobox, `direnv`, a repository checkout, or a developer home.

## Installed filesystem contract

| Category | Installed path | Ownership and mutability |
| --- | --- | --- |
| Application source | `/usr/libexec/grocery-pos-core` | root-owned deployment content; read-only to the service |
| Machine configuration | `/etc/grocery-pos/pos-core.env` | root-owned `%config(noreplace)`, mode `0644`; currently contains no secrets |
| Authoritative state | `/var/lib/grocery-pos` | `grocery-pos` service state directory, mode `0750` |
| Canonical database | `/var/lib/grocery-pos/pos.db` | authoritative SQLite file; provisioned separately and owned for service access |
| Transient runtime state | `/run/grocery-pos` | systemd-managed runtime directory, mode `0750` |
| Unit | `/usr/lib/systemd/system/grocery-pos-core.service` | root-owned package content |
| Service identity | `/usr/lib/sysusers.d/grocery-pos.conf` | named `grocery-pos` user/group without fixed numeric IDs |
| Logs | system journal | no separate `/var/log/grocery-pos` tree |

The package installs no database, catalog, register, cashier, shift, opening
cash, backup, or other business state. Application code and configuration stay
root-controlled. POS Core does not run as root, the cashier user, or a developer
account, and its identity receives no hardware-device groups.

`StateDirectory=` manages the state directory when the service can start, but
does not guarantee recursive ownership repair for an arbitrary pre-provisioned
database. Provisioning must make `pos.db` readable and writable by
`grocery-pos` while excluding unrelated local users.

## Configuration and canonical database

The root-controlled environment file contains:

```text
GROCERY_POS_ENV=production
RACKET_API_HOST=127.0.0.1
RACKET_API_PORT=7340
```

Checkpoint 3 still permits only literal `127.0.0.1` or `::1`; remote listening
is unsupported. `SQLITE_DB_PATH` is deliberately absent from the editable
file. The service launcher sets and exports exactly:

```text
SQLITE_DB_PATH=/var/lib/grocery-pos/pos.db
```

immediately before executing the packaged entry point, so ordinary API
configuration cannot redirect authoritative state.

## Missing-database fail-closed boundary

The unit contains:

```text
AssertFileNotEmpty=/var/lib/grocery-pos/pos.db
```

This is evaluated before `ExecStart`. A missing or empty canonical database
therefore fails the systemd start job instead of reaching POS Core's
create-capable initialization path. An operational restart after database loss
cannot silently create a fresh register and replace missing financial history.

This service guard does not change source development: `just run-racket` can
still initialize a deliberately selected development database. The service
never restores a backup or selects a recovery point automatically.

## Service lifecycle

After explicit provisioning, normal commands are:

```text
systemctl status grocery-pos-core
systemctl start grocery-pos-core
systemctl stop grocery-pos-core
systemctl restart grocery-pos-core
journalctl -u grocery-pos-core
curl http://127.0.0.1:7340/health
curl http://127.0.0.1:7340/ready
```

The `Type=exec` service runs as `grocery-pos:grocery-pos` and sends stdout and
stderr to journald with `SyslogIdentifier=grocery-pos-core`. Normal stop uses
SIGTERM with a 30-second timeout. `Restart=on-failure` waits five seconds and
allows at most three starts in 60 seconds. Administrator stop stays stopped;
persistent startup failure is not hidden by a database reset.

The package does not enable or start the unit and has no install-time migration
or database scriptlet. Checkpoint 6 controls enablement after provisioning.

## Service hardening

The initial unit applies `NoNewPrivileges`, private temporary/device views,
strict system/home/kernel/control-group/clock/hostname protections, SUID/SGID
and realtime restrictions, a locked process personality, empty capability
sets, only `AF_UNIX`/`AF_INET`/`AF_INET6`, and native system-call architecture.
Writable durable access comes from `StateDirectory=`, not a broad filesystem
exception.

`PrivateNetwork=yes` is deliberately absent because Flutter must reach host
loopback. `MemoryDenyWriteExecute=yes`, aggressive system-call filters, and
custom SELinux policy remain deferred until Racket and the appliance are
qualified.

## Installed technician commands

The RPM provides thin launchers for the existing Racket tools:

```text
grocery-pos-db info /var/lib/grocery-pos/pos.db
grocery-pos-db quick-check /var/lib/grocery-pos/pos.db
grocery-pos-db integrity-check /var/lib/grocery-pos/pos.db
grocery-pos-db backup /var/lib/grocery-pos/pos.db OUTPUT
grocery-pos-db backup-validate BACKUP
grocery-pos-catalog validate SNAPSHOT
grocery-pos-catalog activate SNAPSHOT /var/lib/grocery-pos/pos.db
grocery-pos-register-config validate SNAPSHOT
grocery-pos-register-config activate SNAPSHOT /var/lib/grocery-pos/pos.db
```

These launchers contain no maintenance or business logic. State-changing
operations require a deliberate technician procedure and correct filesystem
authority. Technician authentication/authorization, restore, scheduled backup,
retention, encryption, and replication are not implemented here.

## Provisioning prerequisite

The future first-boot sequence remains separate from RPM installation:

```text
install package/image while service remains disabled
  -> establish /var/lib/grocery-pos
  -> explicitly create/migrate the initial database through canonical code
  -> activate catalog and register/cashier configuration
  -> set grocery-pos ownership and restrictive permissions on pos.db
  -> enable and start grocery-pos-core
```

Checkpoint 6 will implement and qualify that lifecycle. Checkpoint 5 defines
offline restore and support diagnostics. Flutter/KDE kiosk startup and the full
Kinoite image are also outside this package.

## Build and test

On Linux, Nix exposes `packages.pos-core-rpm`:

```text
just build-pos-core-rpm
just check-pos-core-package
```

The rootless package check extracts the RPM, verifies payload paths, metadata,
dependencies, permissions, service directives, and absence of Nix store
references. It then explicitly provisions a temporary database, runs packaged
code, checks `/health` and `/ready`, commits a start and scan, sends SIGTERM,
restarts against the same DB, verifies recovered state, and exercises packaged
inspection/integrity/backup commands.

This is artifact evidence, not final booted-appliance qualification. Installed
systemd, SELinux, rpm-ostree upgrades, sudden power loss, and endurance remain
later Milestone 6 work.
