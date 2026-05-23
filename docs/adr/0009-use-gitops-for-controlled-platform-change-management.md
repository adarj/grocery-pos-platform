# ADR-0009: Use GitOps for controlled platform change management

Status: Accepted

Date: 2026-05-23

## Context

The platform includes application code, infrastructure, database schema, appliance profiles, hardware profiles, release manifests, documentation, and customer/store provisioning data.

These changes need reviewability, traceability, repeatability, and safe promotion across environments. However, the live POS terminal also has local transaction state that must not be casually mutated by Git-driven automation.

## Decision

Use GitOps for controlled platform change management.

Git will define desired platform state for infrastructure, Supabase schema, release manifests, appliance profiles, hardware profiles, documentation, and provisioning templates. CI will validate changes. Production-impacting changes will be promoted through controlled environments.

GitOps will not directly manage active checkout state, local SQLite transaction history, payment recovery state, cash drawer state, or unsynced local runtime queues.

## Consequences

### Positive

- Provides reviewable, versioned operational intent.
- Supports CI validation before changes reach production.
- Enables reproducible infrastructure and database changes.
- Helps manage release channels, appliance profiles, and documentation.
- Creates a strong audit trail for platform evolution.

### Negative

- Requires discipline around secrets, environments, and branch protection.
- Requires clear boundaries between desired platform state and local runtime truth.
- Requires CI/CD workflow maintenance.
- GitOps must be adapted carefully for retail appliance safety.

## Notes

Git defines desired state. The local POS applies changes only when safe.
