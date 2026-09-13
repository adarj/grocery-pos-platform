# ADR-0021: Package POS Core as a Fedora-native service with isolated persistent state

Status: Accepted

Date: 2026-09-10

## Context

POS Core now has an explicit SQLite durability policy, validated backup and
integrity tooling, and a loopback runtime reliability contract. The target
register OS is Fedora Kinoite; Nix provides reproducible development and build
environments.

An installed register must not require a source checkout or development
environment. Application updates must remain separate from authoritative
SQLite state. Most critically, service restart after database loss must not let
create-capable application startup bootstrap an empty register in place of
missing financial history.

The repository has no declared project license and its only current
application version is `0.0.0-dev`.

## Decision

Package POS Core as an internal Fedora-native noarch RPM named
`grocery-pos-core`. Fedora supplies Racket; the RPM installs
architecture-independent source and requires neither a Nix-built runtime nor
Nix on the appliance.

Use root-owned application code under `/usr/libexec/grocery-pos-core`,
root-controlled machine configuration under `/etc/grocery-pos`, authoritative
state under `/var/lib/grocery-pos` with canonical DB
`/var/lib/grocery-pos/pos.db`, transient state under `/run/grocery-pos`, and
journald for logs.

Declare a stable `grocery-pos` user and group through `sysusers.d`, without
fixed numeric IDs. systemd runs as that identity and supplies `StateDirectory=`
and `RuntimeDirectory=` with mode `0750`; application/config payloads remain
root-owned.

Use `Type=exec`, `Restart=on-failure`, a five-second delay, three starts per 60
seconds, and a 30-second SIGTERM stop timeout. Retain host-loopback networking
and a conservative hardening baseline without a private network namespace or
unqualified Racket/JIT restrictions.

The editable environment file controls only environment name and loopback API
host/port. A root-owned launcher forces
`SQLITE_DB_PATH=/var/lib/grocery-pos/pos.db` before `/usr/bin/racket`, so the
file cannot redirect state. `AssertFileNotEmpty` on the canonical DB prevents
`ExecStart` when it is missing or empty.

RPM installation does not initialize/migrate a database, create business
state, enable the service, or start it. Provisioning will create/migrate the
first DB, activate reference/operational data, establish ownership, and only
then enable/start the unit.

Nix builds and rootlessly validates the Linux artifact. Tests inspect metadata,
dependencies, payload, ownership/modes, systemd/sysusers policy, exclusions,
and absence of installed `/nix/store` references. They execute extracted code,
verify liveness/readiness, commit durable state, stop with SIGTERM, restart and
recover, and exercise packaged maintenance tooling.

Map `0.0.0-dev` to RPM `Version: 0.0.0`, `Release: 0.1.dev`. Use provisional
`LicenseRef-Project-Undecided` metadata because no project license has been
chosen. This is not a license grant or evidence of Fedora repository readiness.

## Rationale

This matches immutable-OS separation between deployment content and mutable
state and provides a normal Fedora service/update boundary. Nix remains where
it already excels—reproducible construction—without joining the appliance
runtime trust surface.

Source deployment avoids asserting that Nix-built executable/library paths are
portable elsewhere. A dedicated user supplies a stable least-privilege state
boundary. The database assertion prevents missing authoritative state from
being confused with initial bootstrap.

## Consequences

### Positive

- Packaged code runs outside the repository and without Nix at runtime.
- Application updates and authoritative state have separate paths.
- systemd owns bounded restart, shutdown, directory, logging, and hardening
  policy.
- Missing/empty production DB fails before create-capable startup.
- Existing maintenance tools are available through small launchers.

### Negative

- Fedora must supply a compatible Racket and required collections.
- Live systemd, SELinux, rpm-ostree, and final Kinoite behavior remain
  unqualified.
- Source is executed instead of a standalone compiled distribution.
- Provisioning must supply a valid nonempty DB with correct ownership.

## Rejected or deferred alternatives

### Nix runtime or `raco distribute`

Requiring Nix/`nix-daemon`/`/nix/store` is rejected. `raco exe` and
`raco distribute` remain deferred until portability needs justify bundling and
loader qualification; no `patchelf` workaround is introduced.

### Containerization

Rejected because it adds SQLite mount, filesystem, network namespace, and
update boundaries without solving a current problem.

### `/opt`, root/cashier identity, or `DynamicUser=yes`

Rejected. Code belongs under `/usr`, state under `/var/lib`, and a stable named
identity provides the intended durable-state and future IPC boundary.

### `PrivateNetwork=yes` or aggressive hardening

Private networking breaks the Flutter host-loopback topology.
`MemoryDenyWriteExecute`, aggressive syscall filters, and custom SELinux policy
are deferred pending Racket/appliance qualification.

### Automatic initialization, enablement, or recovery

Install-time DB/business-state creation, automatic service enable/start,
restore, backup fallback, and data repair are rejected. Provisioning and
explicit recovery remain separate.

### Full appliance and UI deployment

Kinoite/rpm-ostree composition, Flutter kiosk packaging, graphical lifecycle,
hardware agents, and signed updates remain later checkpoints or milestones.
