# ADR-0025: Run the cashier UI as a dedicated Plasma kiosk account and system Flatpak

Status: Accepted

Date: 2026-09-12

## Context

Flutter owns presentation while Racket/SQLite own POS meaning and durability.
The backend already runs as a dedicated non-graphical identity. The cashier UI
needs persistent exact-command recovery state, but it needs no direct database,
host filesystem, hardware-device, root, or service-group access. Kinoite
naturally separates desktop applications from host deployment content.

Fedora 44 KDE/Kinoite uses Plasma Login Manager as its display-manager
direction. The local Flutter-to-Racket contract remains literal loopback HTTP.

## Decision

Create `grocery-pos-kiosk` as a dedicated locked, non-admin graphical user with
persistent home `/var/lib/grocery-pos-kiosk`. It is distinct from and not a
member of backend identity/group `grocery-pos` or `wheel`.

Run Plasma Wayland through Plasma Login Manager autologin and supervise the
terminal with a systemd user unit tied to the graphical session. Package the
source-built terminal as a system Flatpak. Enable explicit native Linux kiosk
fullscreen/no-header behavior while preserving ordinary windowed development.

Grant only Wayland, DRI, and network sharing. Do not grant host/home filesystem,
all-device, X11, or broad bus permissions. Network sharing is currently needed
for loopback HTTP. Accept a configurable POS Core base URI only when it is HTTP
to literal `127.0.0.1` or `::1`; default remains
`http://127.0.0.1:7340`.

Retain virtual-terminal access for a separate administrator. Disable kiosk
locking/idle power actions and system sleep states, but do not claim hostile
physical-user containment. Do not mirror or duplicate the cashier application
onto the reserved customer-facing display.

## Rationale

The sandbox and Unix identities reinforce “Flutter presents”: UI compromise
does not automatically grant SQLite access. Flatpak supplies an appropriate
Kinoite application boundary, while app-private XDG state persists the existing
write-before-POST recovery protocol. Separate user-service and login-manager
restart policies recover application and session failures at different scopes.

## Consequences

- The terminal can restart without losing pending cashier command identity.
- The application starts even if POS Core is temporarily unavailable and shows
  that state rather than leaving an empty desktop.
- Flatpak network sharing is broader than ideal for loopback and may be removed
  if a future authenticated/UDS transport is designed.
- Physical kiosk containment and actual two-display behavior still require
  reference-hardware qualification.
- Customer-display behavior remains a separate future application/protocol.

## Rejected or deferred alternatives

Running Flutter as root or `grocery-pos`, direct SQLite access, kiosk membership
in `wheel`, native source-tree/Nix execution, X11-first operation, a different
kiosk compositor, host/home/device-wide Flatpak access, duplicated cashier UI
on the customer display, and a secret technician key chord are rejected.
Authentication/RBAC, customer display, hardware agents, and remote/update
control remain later work.

