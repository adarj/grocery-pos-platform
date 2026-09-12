# Fedora Kinoite Grocery POS Appliance

## Reference platform and qualification boundary

Milestone 6 targets an official **Fedora Kinoite 44 x86_64** installation with
KDE Plasma on Wayland. The current delivery model layers project host RPMs
through `rpm-ostree`, installs the cashier terminal as a system Flatpak, and
then runs explicit provisioning. It does not build a custom installer ISO or
bootc image. A project-derived bootable OCI/bootc deployment remains a future
direction after Atomic Desktop delivery is mature enough to qualify.

Checkpoint 6 provides reproducible artifacts and rootless lifecycle tests. It
does not claim final validation on reference dual-display hardware, a booted
Kinoite VM, or SELinux policy; those are Checkpoint 7 acceptance tasks.

## Appliance artifacts

The technician bundle is named like
`grocery-pos-appliance-0.0.0-x86_64.tar.zst` and contains exactly:

- the `grocery-pos-core` noarch host RPM;
- the `grocery-pos-appliance` noarch host RPM;
- `grocery-pos-terminal.flatpak` on branch `stable`;
- `bootstrap-kinoite.sh`;
- a versioned JSON manifest; and
- SHA-256 checksums.

SHA-256 detects corruption and bundle inconsistency; it is not publisher
authentication. Signing and a managed release/update channel remain future
work. The bundle contains no database, backup, catalog, register configuration,
credential, private key, or customer data.

The terminal Flatpak uses application ID `com.grocerypos.pos_terminal`, Fedora
Platform/SDK `f44`, and a source-built Flutter version pinned by `flake.lock`.
Dart dependencies are fixed by `pubspec.lock`. The deployed app includes no
Flutter/Dart SDK and needs neither Nix nor a source checkout.

The sandbox permits Wayland, DRI, and network sharing. Network sharing is
needed solely because the current trusted transport is host-loopback HTTP. The
Flatpak has no host/home filesystem permission, all-device permission, X11
socket, broad D-Bus permission, or direct access to `/var/lib/grocery-pos` or
`/etc/grocery-pos`. Its private Flatpak home/XDG state persists exact cashier
command-recovery intent across app/session/reboot boundaries.

## Identity and state separation

Two Unix identities have different authority:

| Identity | Purpose | Persistent home/state |
| --- | --- | --- |
| `grocery-pos` | non-graphical POS Core service and SQLite owner | `/var/lib/grocery-pos` |
| `grocery-pos-kiosk` | non-admin Plasma/Flutter presentation session | `/var/lib/grocery-pos-kiosk` |

The kiosk account has no fixed UID, locked password, no sudo/wheel membership,
and no membership in the `grocery-pos` group. It cannot access the authoritative
database. A separate human administrator account created during Fedora setup is
the technician boundary; no default/shared technician credential is created.

## Boot and kiosk lifecycle

After completed provisioning and a deliberate reboot, the intended chain is:

```text
Fedora systemd
  -> grocery-pos-core.service
  -> Plasma Login Manager (plasmalogin)
  -> grocery-pos-kiosk autologin to plasma.desktop (Wayland)
  -> graphical-session.target
  -> grocery-pos-terminal.service
  -> system Flatpak in GROCERY_POS_KIOSK=1 fullscreen mode
```

The terminal user unit uses `Restart=always` with a two-second delay. It starts
even while POS Core is temporarily unavailable so Flutter can display its safe
unavailable/retry state. Plasma Login Manager uses `Relogin=true` so a session
exit returns to the kiosk. Autologin configuration is installed last, after a
valid database exists and POS Core reaches `/ready`.

Provisioning disables screen locking, PowerDevil idle dim/display-off and idle
suspend for the kiosk profiles. It masks system sleep, suspend, hibernate, and
hybrid-sleep targets without disabling shutdown/reboot. SELinux remains
enabled; normal Fedora paths and `restorecon` are used without a custom policy.

This is an operational kiosk, not a hostile-physical-user security boundary.
Linux virtual-terminal switching remains available. An administrator can use
`Ctrl+Alt+F3`, log in separately, and run the documented root tools.

## Display topology

The reference hardware has one primary landscape cashier touchscreen and one
extended portrait customer-facing display. The cashier Flatpak creates one
fullscreen window; this checkpoint packages no mirroring rule and launches no
second cashier copy. Connector names, rotation, touch mapping, and placement
remain machine-specific KScreen state and require Checkpoint 7 hardware
qualification. The second display is reserved for a future customer-display
application; no customer-display business behavior is implemented here.

## Local-first operation and update boundaries

POS Core and Flutter still communicate only through literal loopback. No
firewall opening or remote API mode is added, and checkout startup requires no
Supabase, DigitalOcean, or Internet connection. The Flatpak runtime must be
available from the configured Fedora Flatpak source during provisioning; no
Flathub application remote or automatic app update is configured.

Updates are deliberate technician work: close store work according to policy,
create a validated database backup, apply approved rpm-ostree/Flatpak changes,
reboot deliberately, and verify POS Core readiness and kiosk startup. No
unattended reboot agent exists. An rpm-ostree rollback changes immutable `/usr`
deployment content; it does **not** restore the database in persistent `/var`.
Use the explicit [database restore](database-restore.md) workflow for financial
state recovery.

See [Appliance Provisioning](appliance-provisioning.md) for installation and
[Kiosk Recovery](kiosk-recovery.md) for technician operations.

