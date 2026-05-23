# ADR-0003: Use Racket as the local POS backend

Status: Accepted

Date: 2026-05-23

## Context

The POS terminal needs a local backend that owns transaction meaning, basket state, pricing, tax, discounts, tender orchestration, receipt generation, manager approvals, audit events, local persistence, and sync semantics.

Grocery POS systems contain many rule-heavy workflows, including barcode interpretation, weighted items, PLUs, tax categories, promotions, manager overrides, drawer operations, and inventory movement.

## Decision

Use Racket as the primary local POS backend language.

Racket will run locally on the POS terminal as the core service behind the Flutter UI. It will own the local API, transaction engine, rule evaluation, SQLite writes, sync outbox semantics, and management API.

## Consequences

### Positive

- Excellent fit for rule-heavy and language-oriented POS logic.
- Enables future DSLs for promotions, barcode rules, receipt templates, imports, and policies.
- Encourages a clean domain model and testable transaction engine.
- Works well as a local service behind Flutter.
- Provides a strong foundation for simulation, fixtures, and TDD.

### Negative

- Smaller ecosystem than more common backend languages.
- Some hardware/vendor integrations may be better delegated to Rust.
- Team members may need Racket-specific onboarding.
- Deployment packaging must be handled deliberately.

## Notes

Racket owns sale meaning. Rust may own low-level hardware edges. Flutter owns presentation.
