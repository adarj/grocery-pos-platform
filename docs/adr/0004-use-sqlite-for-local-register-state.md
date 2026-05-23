# ADR-0004: Use SQLite for local register state

Status: Accepted

Date: 2026-05-23

## Context

A grocery POS terminal must keep operating during network outages, cloud outages, temporary Supabase unavailability, peripheral errors, and local application restarts. It must preserve transaction state, payment recovery state, receipt state, drawer state, local catalog cache, and sync queues.

The local database should be durable, simple to deploy, easy to back up, and suitable for a single-register appliance.

## Decision

Use SQLite as the local register database.

SQLite will store local transaction events, current transaction projections, tender attempts, payment operations, receipts, shifts, drawer events, catalog cache, sync outbox, remote command inbox, audit events, device status, and schema migrations.

## Consequences

### Positive

- Enables local-first checkout.
- Does not require a local database server.
- Works well for single-register local workloads.
- Supports crash recovery and offline operation.
- Simplifies deployment on Fedora Kinoite.
- Allows support bundles and local diagnostics.

### Negative

- Not suitable as a shared multi-register database over a network filesystem.
- Requires disciplined single-writer ownership through the Racket backend.
- Requires careful migration, backup, integrity-check, and retention policies.
- Requires explicit sync logic with Supabase.

## Notes

Racket should be the normal owner of SQLite writes. Flutter should not write directly to SQLite.
