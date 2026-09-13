# Milestone 6 Reliability Acceptance

Current repository-side status: **conditional**.

Tier A deterministic acceptance is automated by `just accept-m6`. Required
booted Fedora Kinoite, reference-hardware, and physical power-interruption
qualification has not been executed in this development environment. Therefore
Milestone 6 external appliance qualification remains pending, regardless of a
green repository suite.

The evidence set is:

- [requirements.md](requirements.md): stable consequential M6 requirement IDs;
- [test-plan.md](test-plan.md): evidence tiers, commands, and classification;
- [acceptance-results.json](acceptance-results.json): versioned machine-readable
  execution ledger;
- [audit-report.md](audit-report.md): whole-milestone findings and conclusion;
- [reference-hardware.md](reference-hardware.md): Tier C recording template;
- [power-interruption.md](power-interruption.md): destructive Tier D procedure.

## Evidence doctrine

The result ledger distinguishes an executable test specification from evidence
that the test ran. Repository tests cannot mark a booted system, physical
display, storage stack, or power-cut campaign passed. Overall status is:

- `passing` only when every mandatory Tier A/B/C/D item actually passed;
- `conditional` when deterministic acceptance passes but required external
  qualification is blocked or not run;
- `failing` when any mandatory executed test fails.

Large logs, databases, RPMs, Flatpaks, and archives remain under ignored local
or Nix output paths. The committed JSON is concise and contains no host name,
machine ID, serial number, MAC address, credential, customer data, or complete
environment dump.

## Safe commands

```text
just accept-m6
just acceptance-report-m6
just soak-m6
just crash-m6
just qualify-m6-kinoite
```

`acceptance-report-m6` regenerates the ledger from the most recent ignored
Tier A run summary. `qualify-m6-kinoite` is read-only but must be run as root on
the disposable reference appliance so its Unix permission checks are real.
`crash-m6` runs 100 real POS Core process-death/restart cycles by default; it is
bounded and uses temporary test state. None of these commands performs
destructive Tier D testing.
