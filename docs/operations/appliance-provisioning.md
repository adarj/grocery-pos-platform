# Grocery POS Appliance Provisioning

## Prerequisites

Start with a supported official Fedora Kinoite 44 x86_64 installation. Retain a
separate administrator account with sudo access. Obtain a trusted local Grocery
POS appliance bundle plus store-specific canonical catalog and register/
cashier configuration snapshots. The bundle intentionally does not contain
those store inputs.

Do not delete an existing `/var/lib/grocery-pos/pos.db` to force provisioning.
An existing database is authoritative state and requires deliberate diagnosis,
backup, or restore handling.

## Phase 1: bootstrap the rpm-ostree deployment

Extract the appliance bundle, review its manifest, and run as root:

```text
./bootstrap-kinoite.sh
```

Before mutation the bootstrap verifies the exact Fedora ID, release 44,
Kinoite variant, x86_64 architecture, ostree boot marker, bundle schema/member
set, and every SHA-256 checksum. It queries rpm-ostree for an existing pending
deployment and refuses to discard or replace one it did not create. It then
layers the local `grocery-pos-core` and `grocery-pos-appliance` RPMs together.

Success reports `reboot_required: true`; it never reboots by default. Reboot
deliberately into the new deployment. Package installation creates no DB,
kiosk user, autologin state, or store business data and does not start POS Core.

## Phase 2: provision the register

After reboot, run from the installed package as root:

```text
grocery-pos-appliance provision \
  --terminal-flatpak /path/grocery-pos-terminal.flatpak \
  --catalog /path/store-catalog.json \
  --register-config /path/register-configuration.json
```

Provisioning preflights root privilege, the same host contract, installed
inputs, terminal application ID/`x86_64/stable` ref, and both canonical JSON
snapshot codecs before OS or database mutation. It records hashes—not contents—
in root-only `/var/lib/grocery-pos-appliance/provisioning-v1.json`.

The small resumable state machine advances only after each step succeeds:

```text
preflight
  -> terminal_installed
  -> kiosk_user_ready
  -> database_published
  -> core_ready
  -> kiosk_configured
  -> complete
```

It installs the Flatpak system-wide, creates locked non-admin
`grocery-pos-kiosk`, and prepares `/var/lib/grocery-pos` as mode `0750` owned by
`grocery-pos:grocery-pos`. It builds the initial database at an unpublished
same-filesystem path through canonical POS migration/catalog/register code,
reaches schema v9, performs full current-schema/SQLite/foreign-key validation,
and publishes a
standalone candidate as `pos.db` with no-overwrite atomic rename. The final DB
is `grocery-pos:grocery-pos`, mode `0640`. Provisioning never overwrites an
existing canonical DB. Each configured cashier gains a same-ID `cashier`
operator stub with no credential. Enrollment is not a `/ready` prerequisite,
but at least one active enrolled operator is required to unlock the Checkpoint
2 cashier terminal. Use the root-only bootstrap procedure before kiosk handoff.

Only then does it enable/start `grocery-pos-core.service` and wait up to 30
seconds for `/ready`. PLM autologin, the kiosk user service, lock/power policy,
and display-manager selection are finalized only after readiness succeeds.
Success reports another deliberate reboot requirement.

## Failure and resume

Before DB publication, handled failures remove safe unpublished candidates.
After publication, the DB is never deleted merely because a later service or
kiosk step failed. Rerun the same command with byte-identical critical inputs;
the recorded phase is verified and completed work is not destructively
repeated. Changed Flatpak/catalog/register hashes are rejected. A completed
appliance refuses accidental re-provisioning.

Use:

```text
grocery-pos-appliance status
```

to inspect sanitized host, provisioning, package/Flatpak, POS Core liveness/
readiness, kiosk-user, display-manager, and maintenance state. Investigate a
failure rather than deleting the state marker or authoritative database.

## Final verification

After the reported reboot, verify POS Core `/health` and `/ready`, automatic
Plasma Wayland kiosk login, fullscreen terminal startup, and persistence across
a terminal/session restart. Reference-hardware display placement, touch
mapping, SELinux denials, AC-loss firmware behavior, and endurance remain
Checkpoint 7 qualification.
