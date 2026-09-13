# ADR-0023: Build support bundles from allowlisted operational metadata

Status: Accepted

Date: 2026-09-11

## Context

Technicians need useful register diagnostics, but databases, receipts, future
payment state, device responses, configuration, environments, and logs can
contain sensitive information. Collecting broadly and redacting afterward is a
fragile security boundary. Diagnostic collection must also work when POS Core,
SQLite, RPM queries, or individual operating-system sources are unavailable.

## Decision

The ordinary support bundle contains a fixed allowlist of versioned JSON
sections: manifest, platform, installed-package, selected systemd state,
sanitized structural database information, safe `/health` and `/ready` state,
and capacity for the state filesystem.

It excludes authoritative database contents and sidecars, backups, recovery
evidence, transaction/receipt/catalog/cashier/shift contents, raw journal
messages, whole configuration files, process environments, stable machine
identifiers, network/device identifiers, arbitrary exception output, and
credentials. Collection is observational: it does not stop POS Core, run
migrations, checkpoint SQLite, or run `quick_check`/`integrity_check`.

Each provider is sanitized through an exact-field serializer. An unavailable
noncritical provider yields a stable availability value rather than exception
text. The collector builds a private `.tar.gz` candidate, publishes it with a
non-overwriting atomic rename, sets mode `0600`, and leaves the artifact local.
It never uploads automatically.

## Rationale

Data minimization is safer than attempting to redact arbitrary collected data.
The selected fields address common service, schema-version, API, WAL, and disk
capacity failures without exporting transaction truth. Existing explicit
maintenance tools remain the correct second stage for deep integrity work.

## Consequences

- Some cases require explicit local inspection, including deliberate
  `journalctl` or integrity-check use.
- Raw logs are not immediately available to remote support.
- The bundle still contains sensitive operational metadata and must be
  protected.
- Future authenticated transfer and support-agent permissions remain separate
  security work.

## Rejected or deferred alternatives

Copy-everything-then-redact, including `pos.db` or sidecars/backups/recovery
state, raw journal export by default, environment dumps, automatic integrity
scans, automatic upload, remote support transport, and a support-agent identity
are rejected or deferred.
