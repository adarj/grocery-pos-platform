# ADR-0002: Use Flutter for human-facing applications

Status: Accepted

Date: 2026-05-23

## Context

The platform requires multiple user-facing applications:

- Cashier touchscreen terminal.
- Customer-facing transaction display.
- Manager desktop app.
- Optional manager web app.
- Optional manager mobile app.
- Technician/support workflows.

These surfaces should share design language, data models, UI components, and interaction patterns where possible.

## Decision

Use Flutter as the primary framework for human-facing applications.

Flutter will be used for the POS terminal UI, customer display, manager desktop app, and later optional web/mobile manager applications.

## Consequences

### Positive

- Enables a shared UI stack across desktop, web, and mobile.
- Provides a strong path for a polished cashier/customer experience.
- Supports Linux desktop, which is required for the Kinoite POS terminal.
- Allows reuse of models, formatting, design system components, and API clients.
- Reduces the need to maintain separate UI stacks for POS and manager apps.

### Negative

- Flutter desktop hardware integration may require careful testing.
- Multi-window and multi-display behavior must be validated on Kinoite/KDE.
- Some platform-specific behavior may require plugins, platform channels, or local helper services.
- Flutter must not become the authority for transaction, payment, or inventory truth.

## Notes

Flutter should render backend state and send commands. The Racket backend owns authoritative POS behavior.
