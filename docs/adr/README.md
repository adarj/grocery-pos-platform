# Architecture Decision Records

This directory contains Architecture Decision Records (ADRs) for the Grocery POS Platform.

ADRs document important architectural decisions, their context, and their consequences. They are not meant to be exhaustive design documents; they are durable decision records that explain why the project is shaped the way it is.

## Index

- [ADR-0001: Use Fedora Kinoite as the POS operating system](0001-use-fedora-kinoite.md)
- [ADR-0002: Use Flutter for human-facing applications](0002-use-flutter-for-human-facing-applications.md)
- [ADR-0003: Use Racket as the local POS backend](0003-use-racket-as-local-pos-backend.md)
- [ADR-0004: Use SQLite for local register state](0004-use-sqlite-for-local-register-state.md)
- [ADR-0005: Use Rust for system edge agents](0005-use-rust-for-system-edge-agents.md)
- [ADR-0006: Use Supabase as the cloud control plane](0006-use-supabase-as-cloud-control-plane.md)
- [ADR-0007: Use DigitalOcean for auxiliary cloud infrastructure](0007-use-digitalocean-for-auxiliary-cloud-infrastructure.md)
- [ADR-0008: Use a local-first POS architecture](0008-use-local-first-pos-architecture.md)
- [ADR-0009: Use GitOps for controlled platform change management](0009-use-gitops-for-controlled-platform-change-management.md)
- [ADR-0010: Use an append-only event journal for transaction truth](0010-use-append-only-event-journal-for-transaction-truth.md)
- [ADR-0011: Use durable command receipts and expected stream versions for idempotent transaction commands](0011-use-durable-command-receipts-and-expected-stream-versions.md)
- [ADR-0012: Use an atomic local catalog snapshot for checkout reference data](0012-use-atomic-local-catalog-snapshot-for-checkout-reference-data.md)
- [ADR-0013: Snapshot exact line tax in transaction events](0013-snapshot-exact-line-tax-in-transaction-events.md)
- [ADR-0014: Represent cashier corrections as append-only transaction events](0014-represent-cashier-corrections-as-append-only-transaction-events.md)
- [ADR-0015: Derive canonical receipts from completed transaction replay](0015-derive-canonical-receipts-from-completed-transaction-replay.md)
- [ADR-0016: Snapshot register, cashier, shift, and operational time in transaction history](0016-snapshot-register-cashier-shift-and-operational-time.md)
- [ADR-0017: Use an append-only shift cash ledger for drawer accountability](0017-use-an-append-only-shift-cash-ledger-for-drawer-accountability.md)
- [ADR-0018: Use WAL with FULL synchronous durability for the local POS database](0018-use-wal-with-full-synchronous-durability.md)
- [ADR-0019: Use validated VACUUM INTO snapshots for local POS database backups](0019-use-validated-vacuum-into-snapshots.md)
- [ADR-0020: Keep the POS Core API loopback-only and separate liveness from readiness](0020-keep-pos-core-api-loopback-only-and-separate-liveness-from-readiness.md)
- [ADR-0021: Package POS Core as a Fedora-native service with isolated persistent state](0021-package-pos-core-as-a-fedora-native-service.md)
- [ADR-0022: Restore POS databases offline while preserving displaced state](0022-restore-pos-databases-offline-while-preserving-displaced-state.md)
- [ADR-0023: Build support bundles from allowlisted operational metadata](0023-build-support-bundles-from-allowlisted-operational-metadata.md)
- [ADR-0024: Base the M6 appliance on Fedora Kinoite 44 with persistent rpm-ostree layering](0024-base-m6-appliance-on-fedora-kinoite-44.md)
- [ADR-0025: Run the cashier UI as a dedicated Plasma kiosk account and system Flatpak](0025-run-cashier-ui-as-dedicated-plasma-flatpak-kiosk.md)
- [ADR-0026: Require evidence-tiered reliability qualification before Milestone 6 acceptance](0026-require-evidence-tiered-m6-reliability-qualification.md)
- [ADR-0027: Separate operator identity from cashier attribution and store local PIN credentials with Argon2id](0027-separate-operator-identity-and-pin-credentials.md)
- [ADR-0028: Use process-local bearer sessions with persistent login throttling](0028-use-process-local-bearer-sessions-with-persistent-login-throttling.md)
- [ADR-0029: Enforce fixed server-side authorization with ownership and command actors](0029-enforce-fixed-server-side-authorization-with-ownership-and-command-actors.md)
- [ADR-0030: Require separate scoped approval for whole-sale voids](0030-require-separate-scoped-approval-for-whole-sale-voids.md)
- [ADR-0031: Keep a separate hash-chained local security audit ledger](0031-keep-a-separate-hash-chained-local-security-audit-ledger.md)
- [ADR-0032: Rotate local PIN credentials by revision and recover through root administration](0032-rotate-local-pin-credentials-by-revision.md)
- [ADR-0033: Use a semantic local edge protocol for POS hardware](0033-use-a-semantic-local-edge-protocol-for-pos-hardware.md)
