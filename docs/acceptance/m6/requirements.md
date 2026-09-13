# Milestone 6 Reliability Requirements

These stable identifiers name the consequential reliability claims established
by Milestone 6. They intentionally describe outcomes rather than every
implementation detail. Acceptance evidence in `acceptance-results.json` maps
back to one or more of these identifiers.

## Checkpoint 1 — SQLite operating policy

- `M6-CP1-001`: Every authoritative production connection uses WAL,
  `synchronous=FULL`, foreign keys, a 1,000-page autocheckpoint, and the
  connector's bounded 10-attempt/0.1-second busy retry.
- `M6-CP1-002`: A normal read/write connection cannot create a missing
  authoritative database.
- `M6-CP1-003`: A typed mutation and its durable command receipt are atomic;
  retrying the exact same command ID recovers one original effect.
- `M6-CP1-004`: `BEGIN IMMEDIATE` and expected stream versions arbitrate
  writers without a process-global business-operation mutex or whole-command
  retry.
- `M6-CP1-005`: Cash movements and immutable shift reconciliation remain
  transactionally coupled to accepted POS facts.

## Checkpoint 2 — inspection, integrity, and backup

- `M6-CP2-001`: A live backup uses `VACUUM INTO`, independently validates a
  same-directory partial candidate, and publishes it with a no-overwrite atomic
  rename only after validation.
- `M6-CP2-002`: Inspection and backup validation are read-only, do not create or
  migrate their target, and failed/interrupted candidates never become a final
  backup.
- `M6-CP2-003`: Full backup validation requires integrity, foreign keys, exact
  current migration history, and Grocery POS schema/application invariants.

## Checkpoint 3 — runtime and local API

- `M6-CP3-001`: The ordinary listener accepts only literal `127.0.0.1` and
  `::1`; there is no remote-listener escape hatch.
- `M6-CP3-002`: Native Racket safety limits bound connections, waiting clients,
  request reading/body size, and response handling before application decoding.
- `M6-CP3-003`: `/health` is cheap liveness; `/ready` independently verifies the
  active runtime and exact current production persistence boundary.
- `M6-CP3-004`: Local checkout and startup do not require Supabase,
  DigitalOcean, or Internet connectivity.

## Checkpoint 4 — POS Core service boundary

- `M6-CP4-001`: The Fedora service runs under `grocery-pos`, keeps immutable
  code/configuration separate from `/var/lib/grocery-pos`, and refuses a
  missing or empty canonical `pos.db`.
- `M6-CP4-002`: The noarch POS Core RPM uses Fedora Racket, has no Nix runtime
  dependency, performs no database provisioning in package scriptlets, and
  supports bounded SIGTERM/restart durability.

## Checkpoint 5 — restore and support diagnostics

- `M6-CP5-001`: Explicit offline restore validates both the selected backup and
  its same-filesystem staged copy before canonical state changes.
- `M6-CP5-002`: Restore preserves displaced DB/WAL/SHM/journal evidence, uses
  no-overwrite publication, and never automatically rolls back or chooses a
  different backup.
- `M6-CP5-003`: Support bundles use allowlisted structural metadata, exclude POS
  data/log/environment contents, publish mode `0600`, and never upload
  automatically.

## Checkpoint 6 — Kinoite appliance and kiosk

- `M6-CP6-001`: Fedora Kinoite 44 x86_64 with rpm-ostree layering is the M6
  appliance baseline; bootc/Fedora 45 remain deferred.
- `M6-CP6-002`: The cashier terminal is a source-pinned system Flatpak with
  loopback-only endpoint validation and persistent private recovery state.
- `M6-CP6-003`: The `grocery-pos-kiosk` graphical identity is distinct from the
  backend identity, is non-admin, and receives no direct DB/filesystem access.
- `M6-CP6-004`: The technician bundle validates its manifest/hashes and the
  bootstrap refuses unsupported hosts or unrelated pending deployments.
- `M6-CP6-005`: Provisioning builds and validates the initial database off to
  the side, publishes without overwrite, resumes safely, and installs autologin
  only after POS Core is ready.

## Checkpoint 7 — qualification and audit

- `M6-CP7-001`: Real process death followed by restart preserves accepted
  transaction facts and resolves an ambiguous exact-ID retry exactly once.
- `M6-CP7-002`: Flutter analysis/tests preserve presentation-only authority and
  write-before-POST recovery identity.
- `M6-CP7-003`: A bounded restart/transaction workload preserves exact cash and
  reconciliation invariants.
- `M6-CP7-004`: Backups remain independently valid and coherent during ordinary
  concurrent WAL writes.
- `M6-CP7-005`: An explicit older backup round trip restores only facts at that
  recovery point while preserving later displaced state as evidence.
- `M6-CP7-006`: Real process integration remains locally operable without cloud
  fixtures or synchronous cloud calls.
- `M6-CP7-007`: Isolated ENOSPC failures produce no false SQLite, backup, or
  support-publication success and leave the database reopenable.
- `M6-CP7-008`: Project-generated diagnostic output does not leak authoritative
  POS data, secrets, raw exceptions, or complete environments.
- `M6-CP7-009`: The whole-M6 static audit finds no unexplained raw production
  SQLite connection, migration 7, remote listener escape, broad Flatpak access,
  or destructive RPM behavior.
- `M6-CP7-010`: Mandatory Tier B behavior passes on an actual booted Fedora
  Kinoite 44 x86_64 appliance.
- `M6-CP7-011`: Mandatory display, touch, idle, VT, and storage behavior passes
  on selected reference hardware.
- `M6-CP7-012`: At least 25 controlled abrupt-power cycles pass on a disposable
  appliance with integrity and financial invariants verified after each boot.
- `M6-CP7-013`: Deployable Nix derivations exclude ignored local and generated
  developer state while path-based evaluation continues to include new,
  uncommitted source files for checkpoint validation.
