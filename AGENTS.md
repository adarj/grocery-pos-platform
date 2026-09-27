# Grocery POS Platform — Codex Guidance

## Purpose and priorities

This is serious engineering and a learning project. Prioritize correctness,
security, clear architecture, testability, and developer understanding—in that
order—not code volume or speed alone.

For consequential or unfamiliar work, explain the important invariant,
language/architecture concept, and tradeoff needed for human review. Keep the
developer able to explain important code; do not hide design decisions or give
ritual tutorials for familiar local work.

## Core architecture

**Flutter presents. Racket decides. SQLite remembers. Rust talks to edges.
The cloud coordinates.**

- Flutter owns presentation, never authoritative totals, tax, promotions,
  payment completion/refund validity, authorization, transaction lifecycle, or
  receipt truth.
- Racket owns POS/domain decisions, persistence/synchronization semantics, and
  normal authoritative application writes. Other components must not directly
  mutate transaction truth.
- SQLite owns local durability, not business semantics. Racket reconstructs
  transaction state from the durable journal.
- Rust owns system/device/protocol edges, not POS business truth.
- Cloud coordinates; ordinary checkout must not depend on cloud availability.
  Validate remote commands locally. Do not silently introduce cloud, inventory,
  reporting, telemetry, or update dependencies into the synchronous checkout
  path; such a change requires an explicit architectural decision.

## Critical correctness invariants

- Represent money exactly in authoritative integer units, never binary floating
  point. Reject invalid state transitions explicitly.
- Consequential transaction mutations use the typed, idempotent command boundary
  with a stable command ID and caller-supplied expected stream version. Do not
  bypass it with identity-free writes or silently refresh `expected_version`.
- Retry the same logical command with the same command ID. Transaction events
  are authoritative business truth; command receipts record retry identity and
  original outcomes, not authoritative transaction snapshots or replay input.

> **Unknown payment outcome: never blindly retry the charge.** Persist enough
> intent and correlation information for inquiry, reconciliation, and recovery.

## Security

Authentication and authorization are server-side Racket authority, not UI
visibility. Treat payments, operator authentication, manager approval, remote
commands, support, updates, imports, synchronization, transaction/receipt
integrity, logging, and support bundles as security-sensitive; call out security
consequences when changing them.

Never weaken validation, authorization, audit, sandboxing, cryptographic
verification, or other security controls merely to make tests pass. Never expose
secrets or prohibited data—PINs, passwords, private keys, credential verifiers,
tokens/capability digests, full PAN, CVV/CVC, track data, sensitive raw EMV, or
unsanitized secret-bearing device responses—in logs, fixtures, support bundles,
agent output, or external documentation queries. Give external tools only
necessary non-secret context.

## Development discipline

- Prefer narrow, independently reviewable slices: one invariant → one focused
  test → smallest implementation → review → next invariant. Implement only the
  agreed scope, with explicit invariants and limited blast radius.
- Use TDD where practical, especially for domain behavior; start with the
  smallest relevant test. Never weaken, delete, skip, or rewrite a legitimate
  failing test solely to make work pass. Widen validation with blast radius.
- Use existing `just` recipes as the normal command surface; run `just --list`
  for current commands. Prefer the narrowest relevant recipe during development
  over inventing an equivalent undocumented command.
- Run relevant focused checks before completion and `just check` when broadly
  ready, unless scope-specific documentation provides a justified different or
  stronger gate. Report unavailable validation honestly. Acceptance campaigns
  are qualification evidence, not ordinary development tests.

## Context routes

Read only the routes relevant to the task—not every linked document up front.

- Flutter ↔ Racket API: [local API](docs/architecture/local-api.md), before
  changing that boundary.
- Transaction behavior, schemas, replay, and receipts: [journal](docs/architecture/transaction-journal.md),
  [command schema](docs/architecture/transaction-command-schema.md),
  [event schemas](docs/architecture/transaction-event-schema.md),
  [command receipts](docs/architecture/transaction-command-receipts.md), and
  [canonical receipts](docs/architecture/receipts.md), as applicable.
- Persistence/durability/backup/restore: [runtime](docs/architecture/racket-runtime.md),
  [maintenance](docs/operations/database-maintenance.md),
  [restore](docs/operations/database-restore.md), and ADRs 0018–0019/0022 in the
  [ADR index](docs/adr/README.md).
- Authentication/authorization/approval/audit/credentials: relevant
  [security documentation](docs/security/), ADRs 0027–0032 in the ADR index, and
  [M7 acceptance](docs/acceptance/m7/README.md).
- Appliance/reliability/operational qualification: [appliance operations](docs/operations/kinoite-appliance.md),
  relevant ADRs 0020–0026, [M6 evidence](docs/acceptance/m6/README.md), and M7 evidence.
- Integration testing: [integration guide](docs/development/integration-testing.md).
- Agent/Codex workflow: [progressive-disclosure workflow](docs/development/codex-workflow.md).

## Documentation, decisions, and dependencies

Consult relevant ADRs before changing architectural boundaries. Update affected
behavior/architecture/operational documentation in the same change. Create an
ADR for consequential decisions rather than silently replacing an accepted
design. Prefer explicit commands and structured API errors; never expose raw
backend exceptions to Flutter or invent a speculative API ahead of tested need.

Do not casually add/replace production dependencies. Explain the needed
capability, why existing dependencies are insufficient, and security/maintenance
implications; keep the surface small. Do not update unrelated dependencies.

## Git

Do not commit, push, force-push, rebase, reset, merge, rewrite history, or create
releases unless explicitly instructed. Do not discard unrelated work or stage
merely for tooling. The developer normally reviews changes and creates signed
commits manually. Suggest Conventional Commits; a suggestion is not permission
to perform the operation.
