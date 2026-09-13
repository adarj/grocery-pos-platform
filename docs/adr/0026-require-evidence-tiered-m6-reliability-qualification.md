# ADR-0026: Require evidence-tiered reliability qualification before Milestone 6 acceptance

## Status

Accepted

## Context

Milestone 6 makes claims at materially different boundaries. Racket and Flutter
behavior can be exercised deterministically in a rootless repository test. A
systemd directive can be inspected in an RPM. Neither proves that Fedora
Kinoite booted the installed service correctly. Likewise, a killed process is
not evidence that physical storage preserved atomicity across lost power.

Collapsing these results into one green check would create false confidence in
the reliability boundary that protects local financial state. Qualification
must also be repeatable and traceable to stable requirements without committing
customer data, machine identifiers, or enormous transient logs.

## Decision

Milestone 6 uses four explicit evidence tiers:

- Tier A: deterministic, rootless repository/CI acceptance;
- Tier B: booted Fedora Kinoite 44 x86_64 appliance qualification;
- Tier C: selected physical register/display/touch/storage qualification;
- Tier D: destructive abrupt-power qualification on a disposable appliance.

Each result maps a stable test ID to one or more stable M6 requirement IDs and
records `passed`, `failed`, `blocked`, `not_run`, or justified
`not_applicable`. A versioned machine-readable ledger distinguishes a test
specification from actual execution evidence.

The repository command `just accept-m6` runs Tier A only. It must never mutate
rpm-ostree, host users, display-manager state, SELinux, canonical appliance
state, or machine power. Tier B has a read-only observation helper and explicit
manual scenarios. Tier C uses a model-level hardware record. Tier D requires at
least 25 controlled physical abrupt-reset cycles, full database validation
after every recovery, and immediate stop on an integrity or financial
invariant failure.

Overall status is:

- `passing` only after every mandatory Tier A/B/C/D result actually passes;
- `conditional` when deterministic repository acceptance passes but required
  external evidence is blocked or absent;
- `failing` when a mandatory result fails.

## Rationale

Evidence tiers preserve the meaning of each reliability claim. Automated tests
give fast repeatable feedback. Booted OS, physical display/storage, and lost
power behavior remain attached to the environments that determine them. The
ledger makes incomplete qualification visible rather than converting it into a
documentation footnote.

## Consequences

Repository implementation can be complete while Milestone 6 qualification is
still conditional. External campaigns require technician time and disposable
equipment. Evidence records remain concise while full logs/artifacts stay local
or in CI storage. Release decisions can trace every pass to a requirement and
an appropriate environment.

## Rejected alternatives

### Treat all green unit tests as appliance qualification

This cannot prove systemd, rpm-ostree, SELinux, PLM, Flatpak sandbox behavior,
physical displays, or storage power-loss behavior.

### Treat SIGKILL as a power-loss test

It proves application-process recovery, not OS/filesystem/storage behavior.

### Mark unexecuted external tests passed from static configuration

Configuration presence is useful Tier A evidence but does not demonstrate the
external behavior.

### Put destructive qualification in ordinary CI or `just check`

That would be unsafe and environment-dependent. Destructive tests are explicit,
manual, and restricted to disposable hardware.
