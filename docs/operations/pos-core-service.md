# POS Core Fedora Service

## Purpose and qualification boundary

The internal `grocery-pos-core` noarch RPM packages the Racket POS Core source,
Fedora service metadata, machine configuration, and technician launchers. It is
the deployable backend service boundary for the Fedora Kinoite register.
Checkpoint 6 composes it into the Fedora Kinoite kiosk lifecycle, but it remains
separately packaged and is not a public release or final production
qualification.

The evidence tiers and currently pending booted-system checks are recorded in
the [Milestone 6 acceptance record](../acceptance/m6/README.md).

Fedora supplies `/usr/bin/racket` and `libargon2` at runtime. The RPM carries a
fixed, source-pinned `crypto-lib` collection graph because Fedora 44's
`racket-pkgs` does not contain that collection. Nix reproducibly builds and
tests the RPM, but the installed service does not require Nix, `nix-daemon`, a
Nix store, Distrobox, `direnv`, a repository checkout, a developer home, or a
runtime `raco pkg install`.

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

POS Core bearer sessions are intentionally process-local. A normal or abnormal
service restart preserves SQLite business, credential, and login-throttle state
but invalidates every register token. `/health` and `/ready` may recover while
the cashier terminal correctly returns to its lock screen. Do not treat this as
credential loss or attempt to persist tokens outside the service.

Current v12 startup verifies the full local security audit chain and records a
required `runtime.started` event before serving HTTP. Audit corruption or an
unwritable required event fails startup closed. Root inspection uses
`grocery-pos-audit verify` or `grocery-pos-audit list`; see
[Local Security Audit Ledger](../security/security-audit-ledger.md). The CLI
does not expose the ledger to the cashier terminal or support bundle.

The package does not enable or start the unit and has no install-time migration
or database scriptlet. Explicit appliance provisioning builds and validates the
initial database first, then enables/starts the unit and requires `/ready`.

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
grocery-pos-recovery restore SELECTED-BACKUP.sqlite
grocery-pos-support collect OUTPUT.tar.gz
grocery-pos-auth status
grocery-pos-auth operator list
grocery-pos-auth operator create OPERATOR_ID DISPLAY_NAME ROLE
grocery-pos-auth operator set-role OPERATOR_ID ROLE
grocery-pos-auth operator enable OPERATOR_ID
grocery-pos-auth operator disable OPERATOR_ID
grocery-pos-auth operator enroll-pin OPERATOR_ID
```

These launchers contain no maintenance or business logic. State-changing
operations require a deliberate technician procedure and correct filesystem
authority. Recovery is explicitly offline and preserves displaced DB/WAL/SHM/
journal evidence; support export contains allowlisted metadata rather than POS
data. See the [restore runbook](database-restore.md) and
[support diagnostics runbook](support-diagnostics.md). The auth command is a
root-only local bootstrap tool fixed to the canonical database; PIN enrollment
uses a no-echo repeated prompt and no PIN argv. See
[Operator Identity and PIN Credentials](../security/operator-identity-and-pin-credentials.md).
The runtime HTTP authentication and register-lock contract is documented in
[Authenticated Sessions and Register Lock](../security/authenticated-sessions-and-register-lock.md).
Fixed role/resource authorization is documented in
[Authorization and Ownership](../security/authorization-and-ownership.md).
Manager approval, scheduled backup, retention, encryption, and replication
remain unimplemented.

Before activating an upgraded Checkpoint 2 terminal, confirm that at least one
active operator has an enrolled credential:

```text
sudo grocery-pos-auth status
sudo grocery-pos-auth operator list
```

If necessary, create the first manager and enroll its PIN with the explicit
root bootstrap commands above. No account or credential is generated during
package installation, migration, or appliance provisioning, and `/ready` does
not imply that an unlock credential exists.

## Provisioning prerequisite

The implemented first-provisioning sequence remains separate from RPM
installation:

```text
install package/image while service remains disabled
  -> establish /var/lib/grocery-pos
  -> explicitly create/migrate the initial database through canonical code
  -> activate catalog and register/cashier configuration
  -> set grocery-pos ownership and restrictive permissions on pos.db
  -> enable and start grocery-pos-core
```

The canonical lifecycle is documented in
[Appliance Provisioning](appliance-provisioning.md). Fedora/Plasma integration
is owned by the separate `grocery-pos-appliance` package; POS Core retains its
service/database boundary unchanged.

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
inspection/integrity/backup, offline restore, and privacy-minimized support
commands.

This is artifact evidence, not final booted-appliance qualification. Installed
systemd, SELinux, rpm-ostree upgrades, sudden power loss, and endurance remain
later Milestone 6 work.

For appliance lifecycle/status and graphical recovery, see
[Fedora Kinoite Grocery POS Appliance](kinoite-appliance.md) and
[Kiosk Recovery](kiosk-recovery.md).
