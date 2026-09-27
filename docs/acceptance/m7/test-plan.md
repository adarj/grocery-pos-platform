# M7 security test plan

## Tier A — deterministic/local

`just accept-m7` records every command, UTC start, status, host/kernel/architecture, and ignored log. The inventory is closed in `scripts/acceptance/m7-report.rkt`; missing groups cannot pass. It runs the Racket, Flutter, real-process integration, complete `just check`, package checks, native RPM derivations, flake check, M7 static audit, source isolation, bounded 10,000-event ledger workload, 25-process SIGKILL command-recovery campaign, private-tmpfs disk-full test, and attempts x86_64 terminal/bundle derivations. The full `just check` intentionally repeats component suites because it is also the project's canonical integrated quality gate.

`m7-report-test.sh` rejects missing/unknown/duplicate evidence and exercises overall-status rules. `m7-runner-test.sh` injects record, summary, and report publication failures using an isolated fake repository and mocked expensive commands. It tests runner control flow only; its mocked passes must never enter the real acceptance ledger. The static gate includes these runner tests and the installed-permission helper's narrow/broadened fixtures.

The security stress creates 10,000 **synthetic typed audit events via the supported append API** (not 10,000 real credential attempts), then performs four real unknown-ID login failures, 20 authenticated foreign-transaction read denials, runtime startup verification within the 30-second readiness bound, real login, shift open, exact-command cash sale and retry, independently approved void and retry, active-sale PIN rotation and pending-command recovery, support privacy checks, validated backup, and isolated restore. A genuine missing-resource read must not fabricate denial evidence. Restored audit rows must match the source exactly, including payload bytes and hashes. Metrics are local observations, not performance guarantees. A default run is bounded; `just stress-m7 50000` is optional extended volume. Existing focused Racket tests cover migration prefixes, actor/approver provenance, grant races, final-writer revision checks, audit corruption/atomicity, restore, and privacy. Existing Flutter/integration tests cover UI/recovery and live HTTP process behavior. Exact focused-test names/results must be cited from their executed logs; this plan alone is not evidence.

The current process-death group reuses the 25-iteration real-Core SIGKILL accepted-command recovery test. It is narrower than a full security-interruption campaign: session/approval/audit/credential interruption still requires the focused repository tests and Tier D physical campaign. The private-tmpfs disk-full group runs both M6's SQLite/backup/support harness and M7's required PIN-reset/audit rollback, approved-void rollback, and best-effort invalid-login denial checks. It proves the failed void leaves no event, receipt, actor/approver evidence, or slot release and preserves the unconsumed grant. Focused audit atomicity tests additionally cover injected failures at individual persistence seams.

The x86_64 derivation attempt may be `blocked` on a host lacking a compatible builder. Manual assembly is not a substitute. Even successful emulated/cross artifact construction does not satisfy Tier B.

## Tier B — booted appliance

Use only a disposable, provisioned Fedora Kinoite 44 x86_64 OSTree appliance. Run `just qualify-m7-kinoite` for safe observations, then explicitly perform the state-changing scenarios in `appliance-qualification.md`. Record exact hardware/build/deployment, commands, UTC time, outputs, and outcome. Do not infer results from package unit tests. Run the ten reboot cycle and upgrade/rollback boundary only with suitable disposable prior deployment; otherwise record `blocked` or `not_run`.

## Tier C — physical reference register

Follow `reference-hardware.md` on the chosen display/touch/kiosk system. Flutter widget tests are not physical evidence.

## Tier D — destructive interruption

Follow `power-interruption-security.md` only on a disposable physical register. A process SIGKILL is not an abrupt-power test. Record intended phase and observed post-boot state; do not claim sub-millisecond cut timing without instrumentation.

## Interpretation and exit

`passing` requires all mandatory tiers actually passed. `conditional` means missing/blocked evidence with no observed failure. `failing` means an executed mandatory failure or unresolved A/B finding. The Tier A runner exits nonzero on a failed or blocked mandatory Tier A group. External evidence cannot be marked passed by `accept-m7`; its records require separate actual execution. No historical M6 evidence is regenerated.
