# ADR-0001: Use Fedora Kinoite as the POS operating system

Status: Accepted

Date: 2026-05-23

## Context

The POS terminal needs to behave like a managed appliance rather than a general-purpose desktop. It must support a cashier touchscreen, a customer-facing portrait display, local services, reliable updates, rollback, kiosk-like operation, and field support.

The system also needs a Linux desktop environment suitable for Flutter desktop applications, dual-display configuration, touch input, audio feedback, peripheral integration, and technician diagnostics.

## Decision

Use Fedora Kinoite as the standard POS operating system for register terminals.

Kinoite will provide the atomic Fedora base, KDE Plasma desktop/session layer, rpm-ostree update and rollback model, Flatpak-compatible graphical environment, and a practical foundation for kiosk-style POS operation.

## Consequences

### Positive

- Provides an atomic/rollback-friendly desktop base.
- Aligns the development environment with the target POS appliance environment.
- KDE Plasma gives strong dual-display and kiosk-configuration flexibility.
- Fedora provides modern Linux hardware support.
- Works well with a local service model based on systemd.

### Negative

- Requires careful kiosk/session lockdown.
- Requires hardware validation for touchscreen, display rotation, audio, and peripherals.
- rpm-ostree layering and immutable-desktop patterns may be unfamiliar to some technicians.
- Some configuration must be managed as appliance profile state rather than casual desktop settings.

## Notes

The project should keep the POS application stack mostly desktop-agnostic where practical, but Kinoite is the primary target.
