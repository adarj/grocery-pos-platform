# ADR-0005: Use Rust for system edge agents

Status: Accepted

Date: 2026-05-23

## Context

The POS terminal needs to interact with hardware and system edges, including receipt printers, barcode scanners, cash drawers, scales, payment terminals, update verification, support bundle generation, display diagnostics, and possibly vendor SDKs or binary protocols.

These tasks benefit from native system access, strong memory safety, structured error handling, and small standalone services.

## Decision

Use Rust for system edge agents and low-level helper tools.

Rust will be used selectively for hardware bridges, protocol adapters, update verification, support bundle tooling, display/device diagnostics, high-volume import helpers, and other system-facing components.

## Consequences

### Positive

- Excellent fit for hardware, protocol, and system-level code.
- Provides memory safety without a garbage collector.
- Supports small supervised sidecar services.
- Helps keep Racket focused on domain logic.
- Useful for update signing/verification, log bundling, and binary parsing.

### Negative

- Adds another language and toolchain.
- Requires careful IPC contracts between Racket and Rust.
- Rust agents must not become a second transaction authority.
- Hardware-in-the-loop testing will be required for production confidence.

## Notes

Racket owns meaning. Rust owns edges.
