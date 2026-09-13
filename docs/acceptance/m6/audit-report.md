# Milestone 6 Whole-Milestone Audit Report

## Executive result

**Current status: conditional.**

The deterministic repository acceptance in
[acceptance-results.json](acceptance-results.json) is the machine-readable
source of executed Tier A results. Required Tier B booted Fedora Kinoite, Tier C
reference-hardware, and Tier D physical power-interruption campaigns have not
been executed in this development environment. No A-class or B-class repository
defect is known, but Milestone 6 external appliance qualification remains
pending.

## Scope

The audited implementation spans the parent of Checkpoint 1 (`11630c6`) through
Checkpoint 6 (`0f4cc148`), plus the uncommitted Checkpoint 7 acceptance changes.
It covers the SQLite policy, maintenance/backup, runtime/API, Fedora service,
restore/support, and Kinoite/kiosk checkpoints. It does not turn later
authentication, payments, hardware, cloud, or fleet work into M6 requirements.

## Architecture invariants

The audit found no intentional change to exact integer money, tax, typed
transaction commands, command-ID idempotency, same-ID uncertain retry,
`expected_version`, append-only events, deterministic replay, receipt schemas,
transaction Unit of Work, `BEGIN IMMEDIATE`, register/shift rules, cash
accountability, local-first checkout, or Flutter/Racket/SQLite authority.

Flutter remains presentation-only. Racket and the canonical administrative
operations remain the intended SQLite writers. Support and backup candidate
inspection are read-only. Restore is an explicit offline privileged filesystem
operation followed by ordinary POS startup. No Rust or cloud component writes
transaction truth.

## Persistence audit

- Production raw `sqlite3-connect` is confined to
  `sqlite-connection.rkt` and the dedicated read-only inspection boundary in
  `sqlite-maintenance.rkt`. Other raw calls are intentional test fixtures.
- The production constructor still establishes/verifies WAL, applies
  synchronous FULL, foreign keys, 1,000-page autocheckpoint, and bounded
  connector retry of 10 attempts with 0.1-second delay.
- No `PRAGMA busy_timeout` or whole-command retry loop exists in production.
- The migration list remains exactly v1-v6. There is no migration v7. Fresh,
  prefix-forward, current, and unsupported-future histories remain protected by
  the migration suite.
- Startup migration remains distinct from read-only inspection/readiness.
- Backup uses live `VACUUM INTO`, a separately validated partial candidate, and
  atomic no-overwrite publication. There is no raw live DB/WAL copy fallback.
- Restore validates twice, preserves displaced DB/WAL/SHM/journal evidence, and
  neither selects another backup nor automatically rolls back.

The focused acceptance workload completed 1,000 cash transactions with 1,000
production-connection reconstructions and exact completion-command retries. It
created 10 independently validated backups and ended with full integrity,
foreign-key, current-history, schema, cash-count, and immutable reconciliation
checks passing. This is bounded process/persistence stress, not physical power
evidence.

The backup-under-load test publishes three validated snapshots while a separate
WAL writer completes 20 valid sales. The financial round trip proves that sale A
exists after choosing the older snapshot, later sale B does not, and displaced
pre-restore state still contains both. That absence is correct recovery-point
semantics, not data-loss concealment.

## Runtime and API audit

Configuration accepts only literal `127.0.0.1` and `::1`; no remote-listener
escape flag exists. Racket's native server safety object retains the frozen 64
concurrent/64 waiting, 10-second request read, 64 KiB body, 30-second response,
and 10-second send limits. Real-server coverage rejects an oversized body
before a transaction fact/receipt and then processes a valid request.

`/health` remains persistence-free liveness. `/ready` uses a fresh production
read/write policy connection, a lightweight query, and exact current migration
history without creating, migrating, or integrity-scanning the target. The real
process remains live and becomes not-ready when the authoritative path
disappears.

A real POS Core `SIGKILL` campaign alternates accepted scan and completion
responses, restarts after every kill, retries each exact persisted command ID,
and observes one business effect. Mandatory Tier A uses three iterations;
`just crash-m6` provides the bounded 100-iteration extended run. This is
explicitly application-process death, not sudden power loss. Two hundred
repeated readiness requests use a broad `/proc` file-descriptor growth threshold
and leave the server usable; it is leak detection, not a performance SLA.

## Service and appliance audit

The noarch POS Core RPM remains Fedora-Racket source deployment with no Nix
runtime, source checkout, database payload, provisioning scriptlet, or automatic
enable/start. The unit retains the `grocery-pos` identity, canonical
`/var/lib/grocery-pos/pos.db`, nonempty-file assertion, state/runtime
directories, journald, `Restart=on-failure`, bounded start/stop behavior, and
the qualified hardening baseline.

The noarch appliance RPM remains declarative. The cashier Flatpak explicitly
grants Wayland, DRI, and shared networking for loopback HTTP and grants no host
or home filesystem, all-device, X11, or broad D-Bus access. The bundle contract
checks expected artifacts/hashes and rejects a tampered artifact. Nix is a
build/check authority, not an appliance runtime dependency.

The bootstrap/provisioning test seams remain rootless and cannot prove a booted
rpm-ostree/PLM system. The read-only Tier B helper checks the real installed OS,
packages, SELinux, systemd, permissions, Flatpak metadata, identities, PLM, and
sleep masks when run as root on the reference appliance.

The audit found that `path:.` evaluation allowed ignored `.local` and Flutter
generated state to change deployable derivation inputs. A focused regression
first reproduced both changes. The flake now constructs filtered deployable
source snapshots which retain uncommitted source for checkpoint testing but
exclude generated/developer state; the regression proves those ignored changes
no longer alter the RPM or terminal derivations.

## Diagnostics and recovery audit

Support collection remains an allowlist. It excludes database/sidecar/backup/
recovery contents, raw journal messages, complete configuration/environment,
stable machine identifiers, transaction/receipt/catalog/cashier data, and raw
exception text. Sentinel archive tests remain release-blocking. Collection does
not stop POS Core or run quick/full integrity scans.

Recovery still requires root at the appliance boundary, stops and confirms the
service inactive, preserves evidence, publishes without overwrite, restores
ownership/mode, and requires bounded `/ready` verification. Verification
failure leaves the service stopped and does not make another recovery choice.

## Isolated failure testing

A 512 KiB private tmpfs inside an unprivileged user/mount namespace provides
real ENOSPC without filling the host filesystem. SQLite write failure is
explicit; after freeing the filler, the database reopens and passes full
validation. An oversized `VACUUM INTO` publishes no final backup and leaves the
source valid. A full support destination publishes no final archive. No test
automatically deletes backup or recovery evidence to resolve ENOSPC.

Boot/reboot, actual systemd start limiting, installed permissions, SELinux,
Flatpak behavioral denial, rpm-ostree update/rollback, displays/touch, idle
hardware behavior, and abrupt physical power remain `not_run`, not passed.

## Failure-mode reference

| Failure | Expected behavior |
| --- | --- |
| POS Core process dies | systemd restart; SQLite replay; exact-ID retry resolves one effect |
| Flutter process dies | kiosk user service restarts it; private pending state survives |
| Plasma session dies | PLM relogin recreates the kiosk session; backend remains independent |
| DB missing at service start | `AssertFileNotEmpty` fails closed; no DB or migration is created |
| DB disappears during runtime | `/health` may remain live; `/ready` returns sanitized not-ready |
| Backup interrupted | no invalid final file; an abrupt partial remains clearly unpublished |
| Restore verification fails | service stopped; both installed candidate and displaced evidence remain; no auto rollback |
| Internet disappears | local Racket/SQLite cash checkout remains independent |
| Disk becomes full | explicit failure; no false backup/support publication or evidence pruning |
| Support source unavailable | safe partial structural metadata where allowed; no raw exception |
| rpm-ostree rolls back | `/usr` deployment changes; `/var` financial DB does not roll back |
| Physical power is cut | allow normal WAL/journal recovery, then validate; never manually delete hot sidecars |

## Security-boundary observations

Static/package evidence supports distinct backend/kiosk identities, a
non-world-readable DB contract, root-owned application payload, literal-loopback
API, root-only restore/provisioning, no automatic support upload, minimal
Flatpak metadata, and no Nix appliance runtime. Actual installed ownership,
kiosk DB denial, and SELinux behavior still require Tier B execution.

This is an M6 reliability-boundary review, not a penetration test or payment/
regulatory certification.

## Findings

### A — release blockers

None found in executed repository acceptance.

### B — M6 blockers

One packaging-input defect was found and fixed: ignored `.local` and
`.dart_tool` state affected deployable derivation identities. The regression is
`scripts/acceptance/check-nix-source-filter.sh`; no known B-class defect remains.
Unexecuted Tier B/C/D campaigns are qualification prerequisites, not silently
downgraded findings.

### C — follow-up/documentation

The audit found stale statements claiming SQLite busy retry, foreign keys,
server body/readiness behavior, and explicit restore were still deferred. Those
statements were corrected to point at ADR-0018/0022 and the current server
boundary. No behavior changed.

Before the source-input defect was fixed, two independently executed
cross-architecture Flatpak builds produced the same OSTree commit. The final
filtered-source build produced commit
`6eb47170ed01652da672889afd21b6a4c5c1001feee9c3d0889604744406e63f` and passed
the built-bundle contract. Nix pins inputs and the new regression proves ignored
developer state does not change derivations. This is useful repeatability
evidence, but the audit does not extend it into an unsupported claim that every
RPM/archive byte is reproducible; build timestamps/IDs must still be qualified
if a future release process requires byte identity.

## Deferred product scope

Milestone 6 does not complete employee authentication/RBAC, manager approval,
card/payment recovery, printer/drawer/scanner/scale agents, refunds, inventory,
cloud synchronization, fleet signing/updates, remote support, or customer
display business behavior.

## Acceptance conclusion

Repository-side M6 reliability implementation is acceptance-ready when the
machine-readable Tier A ledger is green. The evidence supports a local,
cash-only, single-register reliability/appliance foundation at repository
boundaries. Because the required external campaigns are not present, the only
honest milestone status is **conditional**, not production-qualified.
