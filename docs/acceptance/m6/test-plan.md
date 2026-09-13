# Milestone 6 Acceptance Test Plan

Acceptance evidence is divided by what the test can honestly prove. A process
`SIGKILL` is Tier A process-crash evidence; it is not a power-loss test. A unit
file inspection is Tier A packaging evidence; it is not proof of booted systemd
behavior.

## Tier A — deterministic repository acceptance

Run:

```text
just accept-m6
```

This rootless command executes and records:

| Evidence group | Primary command/evidence | Main requirements |
| --- | --- | --- |
| Racket regression | `just test-racket` | CP1/2/4/5 plus concurrency and privacy |
| Flutter regression | `just test-flutter` | endpoint and recovery-state contracts |
| Real-process integration | `just test-pos-integration` | process crash, HTTP, readiness, local cash flow |
| Bounded acceptance workload | `racket scripts/acceptance/m6-soak.rkt 100` | restart, exact-ID, cash, backups, final integrity |
| Isolated ENOSPC | `scripts/acceptance/m6-enospc.sh` | SQLite/backup/support fail-closed behavior |
| Static boundary audit | `scripts/acceptance/check-m6-static.sh` | raw SQLite, migration, HTTP, service, Flatpak, RPM audit |
| Nix source isolation | `scripts/acceptance/check-nix-source-filter.sh` | ignored local/generated state cannot contaminate deployable derivations |
| Native package checks | `nix flake check path:. --print-build-logs` | core/appliance RPM and pure bootstrap contracts |
| x86 artifact checks | targeted x86_64 Flatpak and bundle check derivations | built Flatpak metadata/payload and bundle tamper rejection |

The runner stores transient logs under ignored
`.local/acceptance/m6/`. The committed ledger contains concise statuses and
evidence references, not those logs. A mandatory Tier A failure or unavailable
isolated capability makes `accept-m6` exit nonzero.

`just soak-m6` runs the larger optional 1,000-iteration workload. An explicit
positive iteration count may be supplied. It is bounded and never runs
forever. Mandatory real-process integration runs three controlled SIGKILL
cycles alternating accepted scan and completion boundaries; `just crash-m6`
runs the same campaign for 100 iterations by default.

Major database workloads end with full integrity, foreign-key, exact migration
history, and Grocery POS schema validation. Package tests build and inspect the
real artifacts outside the repository layout. Deployable source snapshots omit
ignored `.local`, `.dart_tool`, build, coverage, dependency-cache, and result
paths while retaining uncommitted source through `path:.`. Nix may return a
cached identical derivation when rebuilding the same pinned input; that proves
stable inputs and artifact contracts but is not claimed as two independent
bit-for-bit rebuilds.

## Tier B — booted Kinoite qualification

Use a disposable, provisioned Fedora Kinoite 44 x86_64 appliance. The read-only
helper:

```text
sudo packaging/acceptance/qualify-kinoite.sh
```

collects safe observations for OS identity, OSTree, packages, SELinux,
systemd/readiness, installed ownership, Unix group separation, behavioral kiosk
DB denial, Flatpak permissions, PLM, and sleep masks. It does not mutate the
machine. Its success is necessary but not sufficient: technicians must also run
and record the service, reboot, update/rollback, offline checkout, support, and
restore scenarios listed in `acceptance-results.json` and the appliance
operations runbooks.

State-changing Tier B scenarios are manual and explicit. In particular, the
missing-DB guard test must preserve the DB, start the unit with the canonical
path absent, prove that no new DB appears, and restore only through deliberate
cleanup. Run ten reboot cycles and record each cycle separately. Never use store
or production data.

## Tier C — reference hardware qualification

Complete [reference-hardware.md](reference-hardware.md) without serial numbers.
Verify the documented two-display topology, touch mapping, reboot/reconnect
persistence, kiosk fullscreen, technician VT access, idle policy, and selected
storage. These behaviors cannot be replaced by CI mocks.

## Tier D — destructive qualification

Follow [power-interruption.md](power-interruption.md) on a disposable physical
appliance only. At least 25 recorded abrupt-reset cycles must cover idle,
transaction, completion, and backup states. Full integrity and business
invariants are mandatory after every recovery.

## Result classification

- `passed`: the specified test actually executed successfully in the required
  evidence tier.
- `failed`: it executed and violated the expected result.
- `blocked`: execution began or was requested but a required environment
  capability was unavailable.
- `not_run`: no execution evidence was supplied.
- `not_applicable`: the requirement genuinely does not apply to the recorded
  reference configuration; a justification is required.

Findings are class A (release/data/security boundary), class B (M6 operational
blocker), or class C (noncritical follow-up). An A/B result cannot be deferred to
make the ledger green.
