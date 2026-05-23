# ADR-0008: Use a local-first POS architecture

Status: Accepted

Date: 2026-05-23

## Context

A grocery POS terminal must continue selling during internet outages, cloud outages, and temporary sync failures. Checkout cannot depend on a round trip to the cloud for every item scan, tender action, receipt print, or drawer operation.

The system must also support cloud management, reporting, remote support, catalog publication, and multi-register/store oversight.

## Decision

Use a local-first POS architecture.

Each register will operate locally using Flutter, Racket, SQLite, and device agents. Supabase and DigitalOcean will provide cloud management, reporting, support, update, and sync functions, but the register must remain operational when cloud services are unavailable.

## Consequences

### Positive

- Checkout can continue during cloud/network outages.
- Local SQLite state supports recovery and auditability.
- Payment recovery, receipt state, and drawer accounting remain register-local.
- Sync can be asynchronous and idempotent.
- Better fit for real retail environments.

### Negative

- Requires explicit sync, conflict handling, and outbox/inbox design.
- Requires careful cloud/local source-of-truth boundaries.
- Requires local backup, migration, and recovery procedures.
- Remote management commands must be validated locally before application.

## Notes

Cloud can request. Local Racket validates and applies only when safe.
