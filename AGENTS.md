# Grocery POS Platform — Codex Guidance

## Purpose

This repository is both a serious software-engineering project and a learning project.

Optimize for:

1. correctness;
2. security;
3. clear architecture;
4. testability;
5. developer understanding.

Do not optimize merely for producing the largest amount of code in the shortest time.

## Collaboration Mode

Prefer pair-programming and teaching over wholesale implementation.

For a non-trivial or unfamiliar change:

1. explain the relevant design and language concepts;
2. identify the domain invariants involved;
3. identify the files expected to change;
4. propose the smallest independently testable checkpoint;
5. implement only the agreed scope.

Keep changes small enough that the developer can meaningfully inspect and understand them.

When introducing a significant Racket, Dart/Flutter, Rust, SQL, Nix, security, networking, or distributed-systems concept, explain why it fits the problem rather than merely generating code that uses it.

Do not hide important architectural choices inside implementation details.

## Test-Driven Development

Use test-driven development where practical, especially for POS domain behavior.

For domain changes:

1. identify the expected behavior or invariant;
2. write or update the focused test;
3. observe the appropriate failure when useful;
4. implement the smallest correct behavior;
5. run the focused tests;
6. refactor only after behavior is protected;
7. run the wider relevant test suite.

Do not weaken, delete, skip, or rewrite a legitimate failing test solely to make a change pass.

## Canonical Commands

Use `just` as the normal project command surface.

Important commands include:

```text
just doctor
just check
just analyze-flutter
just test
just test-racket
just test-flutter
just run-racket
just run-pos
just run-pos-plain
```

Prefer existing `just` recipes over inventing undocumented command sequences when an equivalent recipe exists.

Before considering a code change complete, run the relevant focused tests.

Run the complete local quality gate:

```text
just check
```

before a change is considered broadly ready for commit unless there is a documented reason that a portion of the suite cannot run.

## Architecture Boundaries

### Flutter owns presentation

Flutter handles human-facing interfaces and interaction.

Flutter must not independently become authoritative for:

* transaction totals;
* tax;
* promotions;
* payment completion;
* refund validity;
* authorization;
* transaction lifecycle;
* receipt truth.

### Racket owns POS meaning

The local Racket POS Core owns:

* transaction state;
* business rules;
* catalog interpretation;
* pricing;
* taxation;
* promotion logic;
* tender orchestration;
* payment orchestration;
* receipt semantics;
* authorization decisions;
* persistence semantics;
* synchronization semantics.

### SQLite owns local durability

SQLite is the implemented durable local journal for accepted transaction facts
in the current cash-sale slice. Racket reconstructs authoritative transaction
state from that journal.

As additional subsystems are implemented, SQLite will also hold other local
durable register concerns such as payment recovery, receipts, drawers, catalog
cache, and synchronization state. SQLite owns durability, not business
semantics.

Racket is the normal application writer.

Do not allow arbitrary components to mutate transaction truth directly.

### Rust owns system edges

Rust is appropriate for:

* hardware and peripheral protocols;
* low-level system integration;
* payment-terminal bridges;
* update agents;
* support agents;
* native protocol parsers and adapters.

Rust agents must not independently redefine POS business truth.

### Cloud coordinates; local validates

Supabase and DigitalOcean provide cloud coordination and auxiliary infrastructure.

Normal local checkout must not depend on cloud availability.

Remote commands must be validated locally before application.

## Transaction Safety

Treat the transaction state machine as a critical correctness boundary.

Invalid state transitions must be rejected explicitly.

Commands that can be retried must be designed with idempotency in mind.

Never represent money with binary floating-point values.

### Payment invariant

If payment outcome is unknown:

**never blindly retry the charge.**

Persist enough payment intent and correlation information to support inquiry, reconciliation, and safe recovery.

## Security Expectations

Treat the following as security-sensitive boundaries:

* payment handling;
* manager authorization;
* employee authentication;
* remote commands;
* support access;
* software updates;
* inventory imports;
* cloud synchronization;
* receipt and transaction integrity;
* logging and support bundles.

Call out security consequences when modifying these areas.

Never place the following in ordinary logs, test fixtures derived from real production data, or support bundles:

* full PAN;
* CVV/CVC;
* magnetic-stripe track data;
* sensitive raw EMV data;
* PINs;
* private keys;
* passwords;
* long-lived tokens;
* unsanitized secret-bearing device responses.

Do not weaken validation, authorization, sandboxing, audit behavior, cryptographic verification, or other security controls simply to make a test pass.

## Local-First Reliability

Checkout-critical behavior should work from local components whenever possible.

A cloud outage must not silently become a checkout outage.

External inventory integration, telemetry, reporting, update infrastructure, or cloud synchronization must not be introduced into the synchronous checkout-critical path without an explicit architectural decision.

## API Work

Consult:

```text
docs/architecture/local-api.md
```

before modifying the Flutter ↔ Racket API boundary.

Prefer explicit commands and structured errors.

Do not expose raw backend exceptions directly to Flutter.

Do not create a broad speculative API surface ahead of tested domain requirements.

## Documentation

Consult relevant ADRs before changing architectural boundaries.

When behavior, architecture, or operational requirements change, update the corresponding documentation in the same change.

Create an ADR for consequential architectural decisions rather than silently replacing an accepted design.

## Dependencies

Do not add or replace production dependencies casually.

Before adding a meaningful dependency:

1. explain the capability it provides;
2. explain why existing project dependencies are insufficient;
3. identify security and maintenance implications;
4. keep the dependency surface as small as practical.

Do not update unrelated dependencies as part of a focused feature change.

## Git

Do not commit, push, force-push, rebase, reset branches, create releases, or alter Git history unless explicitly requested.

The developer normally reviews changes and creates signed commits manually.

When suggesting commit messages, use Conventional Commits.

Examples:

```text
feat(pos-core): add transaction creation
test(pos-core): cover invalid tender transition
fix(pos-terminal): handle unavailable backend
docs(api): document transaction command contract
chore(dev): update development tooling
```

## Scope Discipline

Avoid large “complete subsystem” implementations when a smaller vertical slice will establish the design.

Prefer:

```text
one invariant
→ one focused test
→ smallest implementation
→ review
→ next invariant
```

over:

```text
generate the entire POS subsystem
→ debug a large unfamiliar codebase afterward
```

The developer should remain able to explain the important code and architectural decisions produced during collaboration.
