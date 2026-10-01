# M8.2 Generic Edge Foundation — Tier A

**Phase 1 builds the qualification instrument. No authoritative acceptance result is published here yet.** M8.2 Tier-A passing does not mean whole-M8 Tier-A or Tier-B/C/D passing, a production hardware daemon, or durable exactly-once physical effects.

The generic path is Racket → filesystem UDS HTTP/1.1 → strict codec → single-owner Core → real FIFO/executor → simulator → Core events → NDJSON → Racket EdgeSession. Tier A can qualify this software contract, boundedness and failure handling. Same-user `SO_PEERCRED` checks are repository evidence; separate deployed service UID/DAC/SELinux enforcement is Tier B. Real selected devices are Tier C; integrated lanes are Tier D. Controlled edge process death is not physical power loss.

[Requirements](requirements.md), the [test plan](test-plan.md), and the [E1–E30 matrix](invariant-matrix.md) define scope and planned evidence. Plans/source filenames do not prove execution. The future machine-readable `acceptance-results.json` records execution; `audit-report.md` interprets it and cannot override a failed/blocked entry.

## Two commits

1. Phase 1 implements and self-tests the closed runner/reporter, source audit and campaigns. Constituent development runs use no acceptance ledger. A human adversarially reviews, manually signs/commits/pushes this machinery.
2. A separate Phase-2 task verifies that exact commit SHA and a clean tree, runs `just accept-m8-2`, and freezes its actual ledger and prose audit in a documentation-only commit. The runner has **no dirty-tree override**. It also refuses publication if HEAD/worktree changes during the campaign.

If Phase 2 finds a product or qualification-tool defect, stop the evidence freeze. Correct it, re-audit, manually commit the corrected source, and rerun against that new exact clean commit. A source change after a run invalidates that run for the changed tree; do not retain its ledger as certification of the fix.

Run commands inside the repository's pinned Nix shell (`nix develop`):

```sh
just accept-m8-2
just acceptance-report-m8-2
just stress-m8-2 50000
```

`accept-m8-2` runs all fourteen mandatory groups with finite outer deadlines, stores one log per group under ignored `.local/acceptance/m8-2/`, records exact commands/UTC/environment/exit status, and atomically publishes the summary and final ledger. Ordinary test failures are collected; evidence recording/publication failures stop the runner. `acceptance-report-m8-2` regenerates only from a completed local summary; it never runs tests. Do not use an old summary for a different source tree. `stress-m8-2` is optional and cannot replace mandatory load evidence.

The runner prepares both outputs in ignored storage and checks HEAD and tracked/staged/nonignored-untracked state immediately before publication. Failed Git inspection is fatal. An exclusive local run lock prevents concurrent campaigns from mixing records; after SIGKILL, inspect the abandoned run before manually removing its stale lock. Signal cleanup stops the supervised group and removes unpublished outputs. Each run resets its own JSONL/summary, without consuming development logs. A completed failing/blocked campaign replaces the old ledger with its nonpassing result. Infrastructure/provenance failure preserves any previous ledger, whose reference commit and timestamp still identify the **previous** run; it is not evidence that the interrupted/new run passed.

Reporter self-tests use clearly non-authoritative temporary summaries. Runner mocks live in an isolated fake repository and are deleted. Neither may enter the real ledger. Passing requires every closed mandatory Tier-A group to have passed; executed failure is failing; blocked/not_run evidence is conditional. Malformed, missing, duplicate or unknown groups are rejected rather than guessed.

Evidence JSON also rejects duplicate decoded object keys, including escaped spellings; a later `passed` key cannot overwrite an earlier `failed`. Requirement mappings are fixed by the reporter and describe each group's actual evidence contribution, with runtime and static evidence kept distinct.

Exit 77 is the runner's sole blocked-capability signal. The reporter rejects an ordinary nonzero assertion exit relabeled as `blocked`, so a software failure cannot become a conditional result.

## Deferred contract

M8.1 calls for eventual strict bounded production configuration. The complete `edge.toml`, discovery candidate selectors/ambiguous physical matching, production simulator launch policy, production daemon/bootstrap and OS policy remain deferred; validated Core seeds and fixture isolation do not certify them. Barcode, stable/unstable weight, paper-out and internal device-observation overflow remain later device-specific implementation/qualification. This is an explicit narrowing of this generic foundation's claim, not a rewrite of M8.1.

The private `nix/racket-http-client-bounds.patch` is part of the trusted M8.2 transport boundary while it exists. Changes to it, pins or relevant source require renewed qualification. Future M8.8 should reference this frozen record rather than rewrite it.

## Phase-2 audit report expectations

Record scope/disposition, exact reference commit/environment, executed evidence table, E1–E30 dispositions, identity/retention, effects/uncertainty, bindings/events, transport/Racket, actual capacity/load and process-death observations, dependency/patch/source findings, real fixes and residual qualification. Copy observations from logs/ledger, not from this plan. Record any failed/blocked case plainly; prose cannot turn it into passing.
