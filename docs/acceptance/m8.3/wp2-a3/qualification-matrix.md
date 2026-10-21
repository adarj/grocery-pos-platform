# WP2-A3 qualification matrix

**CANDIDATE — PENDING HUMAN ACCEPTANCE**

This matrix evaluates the available evidence; it does not formally accept new
gate results. The owner explicitly accepted **A3-01 PASS** and **H2.13 PASS WITH
EXPECTED CLEANUP WARNINGS**. All other dispositions below are recommendations
or evidence limitations. See the [audit](audit-report.md) for chronology and
the [evidence index](evidence-index.md) for original filenames/hashes and exact
event locations.

## Criteria authority

No accepted local WP2 charter/decision record was located. The owner clarified
that such a record probably does not exist. The previously supplied
**M8.3.3 WP2 Architecture and Physical-Qualification Charter v0.1** conversation
text provides the reference definitions below, but carried proposed status.
They are not silently promoted to accepted local criteria by this document.
Human confirmation of the governing version/criteria is required before new
formal gate decisions. Existing explicit decisions remain intact.

## Scenario-to-requirement crosswalk

References below use the original event locations in the
[evidence index](evidence-index.md#precise-event-references). Scenario completion
and requirement coverage are separate conclusions.

| Scenario | Related requirement | Evidence | Disposition |
| --- | --- | --- | --- |
| A3-01 — Idle disconnect | H2.07, partially | Owner-accepted initial disconnect; original transcript unavailable (U0). The accepted idle trial does not establish the scan-before-removal setup. | **Previously accepted A3-01 PASS**; H2.07 remains partially substantiated. |
| A3-02 — Held descriptor across reconnect | H2.08 | FD-A remains held and retired through replacement (L3A:15–19,30–32); the bounded nonmigration comparison uses L3A:71–72 together with the fresh acquisition in A3-04. | **Proposed PASS** for the bounded H-VM reconnection trial; pending human acceptance. |
| A3-03 — Replacement identity comparison | H2.09 | Original held metadata and independently verified replacement node, character and sysfs identities differ (L3A:10,30–31; L3B:77). | **Proposed PASS** for observed attachment replacement; pending human acceptance. |
| A3-04 — Independent fresh acquisition | Supporting physical evidence for H2.08; no independent H2 gate | FD-B independently opens and synchronizes (L3B:75–85), then acquires one exact record (L3B:92–94) entirely within FD-A's probe (L3A:71–72). | **Proposed PASS** for independent fresh acquisition during the retired-FD probe; pending human acceptance. |
| A3-05 — Removed-device cleanup | H2.13 | Prior accepted cleanup is owner-attested (U0). Retained FD-A close follows an expected release-ioctl `EIO` (L3A:82–85); FD-B restoration/release/close completes normally (L3B:95–99). | **Previously accepted H2.13 PASS WITH EXPECTED CLEANUP WARNINGS**; no separate A3-05 acceptance is inferred. |

These mappings do not assign H2.07 a full PASS, resolve H2.15, or accept WP2-A3
as a whole. Earlier incomplete coordinated attempts remain incomplete. The
MAJOR criteria gap, both MINOR evidence gaps and the INFORMATIONAL physical
and production-implementation limitations in the
[audit findings](audit-report.md#findings-and-residual-obligations) are unchanged.

## Per-gate evaluation

| Gate | Conversation-reference requirement | Evidence and limits | Accepted decision | Candidate recommendation |
| --- | --- | --- | --- | --- |
| H2.07 — disconnect with live descriptor | Hold CDC open, scan, disconnect; original descriptor reports loss or becomes permanently unusable for authorized input | Accepted A3-01 owner account; retained L2A:16–20 and L3A:15–19 show retirement, disappearance and terminal-loss corroboration. D2 `wait_for_loss` explicitly requests an idle trial. No retained scan through the original attachment before withdrawal establishes the full scan-before-disconnect setup. | A3-01 **PASS**, not an independently supplied H2.07 decision | **PARTIAL** against reference procedure; loss/retirement portion supported. Confirm original criterion/precondition evidence before assigning full H2.07 PASS. Do not revise accepted A3-01. |
| H2.08 — reconnect while old descriptor retained | Reconnect same scanner with old FD held; new attachment must not enable the old FD to read new decoded input | L3A:30–32,71–72 and L3B:77–94: independent B opens/synchronizes/transmits one exact record while retired A returns 50 zero-byte forensic results with HUP/ERR. Full fresh interval contained in probe. Same physical scanner/VM is operator-attested. Samples do not prove every instant or every future kernel; old/new TTY names differ. | None supplied | **Proposed PASS for the bounded H-VM trial**, subject to criteria confirmation and human acceptance; no universal same-path-reuse claim. |
| H2.09 — held-object identity | Compare old/new FD, character and sysfs facts; correlation detects replacement or refuses authority if insufficient | L3A:10,18,30–31 and L3B:77: held A retains old metadata while current USB/interface/TTY/node objects change. Same canonical USB/interface spelling and topology do not revive A. L2A:10,19,32–33 gives another varied replacement comparison. | None supplied | **Proposed PASS for observed replacement detection**, subject to criteria confirmation/human acceptance. No cryptographic authentication or exhaustive race proof. |
| H2.13 — cleanup after removal | No panic, unbounded cleanup, leaked active source or unintended reopen after disconnect/acquisition/restoration | Owner-supplied A3-01 acceptance includes restore/release `EIO` and successful close. L3A:82–85: skip restoration after replacement, release `EIO`, close, exit 3. L3B:95–99: restore/release/close, exit 0. No unexplained coordinated-run cleanup failure. These observations cannot guarantee cleanup after SIGKILL/uninterruptible kernel wait. | **PASS WITH EXPECTED CLEANUP WARNINGS** | **Preserve accepted decision exactly**; new retained cleanup observations support its warning classification, not a blanket waiver for future failures. |
| H2.15 — repeated attachment cycles | Reference text: bounded series of disconnect/reconnect cycles; each attachment independent, with no stale descriptor/parser/queued record surviving replacement | Two retained physical replacement cycles, addresses 7→8 and 8→9; one completed coordinated fresh-acquisition/probe trial. Earlier timeout is unpreserved; second coordinated acquisition incomplete. Diagnostic source and saved synthetic reports support discarded state/separate ownership, not physical execution of Rust buffers. No accepted authoritative local criterion available. | None supplied | **NOT EVALUABLE AGAINST AUTHORITATIVE CRITERIA**. Retained varied-cycle evidence is useful/partial; do not declare three successful repetitions or independently relax the criterion. |

## H2.15 interpretation and bounded follow-up decision

The conversation-reference definition says:

> Run a bounded series of disconnect/reconnect cycles.

Its pass condition is:

> Each attachment is independent; no stale descriptor, parser state or queued
> record survives replacement.

That wording does not specify three identical successful coordinated scans.
It also does not make three operator attempts equal three passing cycles.
With no authoritative accepted local criterion, this audit cannot resolve the
formal disposition by choosing a more convenient interpretation.
The experiment deliberately retains an inert, permanently retired FD-A for
forensics. Human criteria review must also clarify how the phrase "no stale
descriptor ... survives replacement" treats that retained forensic object;
its continued existence is not continued acquisition/publication authority.

The retained evidence supports this narrower account:

| History item | What may count as evidence | What must not be counted |
| --- | --- | --- |
| Accepted A3-01 | Human-accepted retirement/cleanup, with original transcript unavailable | A retained reconnect or coordinated fresh scan |
| First coordinated attempt | Owner-reported operator timeout | Independently verified physical repetition |
| Second coordinated attempt, 4011/4107 | Retained safe removal/replacement, separate fresh preparation and fail-closed pre-arm input handling | Successful coordinated exact-match acquisition |
| Third coordinated attempt, 4433/4525 | Retained safe removal/replacement, independent fresh exact match and contained old-FD probe | Multiple successful coordinated cycles or bare-metal qualification |

The second cycle's replacement facts match the third cycle's original facts;
that is useful observed continuity of the current **replacement** between
experiments, not a revival of the preceding retired descriptor. Both retained
cycles safely close their respective originals. Source inspection/synthetic
results establish parser/queue disposal behavior in the diagnostic. No physical
trial explicitly demonstrates every partial/queued-record removal scenario.

Next human action: confirm the governing H2.15 requirement and decide whether
the documented varied cycles satisfy it. If that requirement actually demands
repeated **successful coordinated acquisitions**, current evidence contains
only one and needs separately authorized, bounded repetition. If it concerns
varied safe retirement/replacement/cleanup, review the two retained cycles
against that condition without pretending the incomplete acquisitions passed.
This audit neither rewrites the criterion nor authorizes a follow-up experiment.

## Residual qualification obligations

- Confirm criteria authority and review all proposed dispositions. Retain the
  earlier accepted decisions without fabricating a local decision ledger.
- Recover missing A3-01/first-attempt/verifier originals if available; otherwise
  explicitly accept or retain the provenance limitations.
- Resolve H2.07's scan-before-disconnect coverage separately from accepted idle
  loss detection. No additional experiment is performed by this audit.
- Preserve the distinction between topology/sysfs spelling reuse, demonstrated
  here, and same node name/major/minor reuse **while that old FD is held**, not
  demonstrated by either retained original/replacement pair.
- Carry exact held-object verification, no automatic reopen, irreversible
  retirement, queue disposal, hangup/error precedence, DTR-high readiness and
  genuine boundary synchronization into later WP2-B/C work and regressions.
- Qualify the eventual Rust implementation and WP3 binding integration. This
  diagnostic did not publish Core/Protocol events or exercise a Racket business
  bridge. Bare-metal, production permissions and multiple scanners remain open.
- Retain raw evidence separately from Git and follow the
  [custody and recovery procedure](evidence-index.md#evidence-custody-preservation-and-recovery).
  The verified second local copy does not provide an independent off-host backup
  or resolve a qualification finding.

Frozen M8.2 evidence was not modified or regenerated and remains historical
evidence for its exact source only. No proposed result in this matrix extends
that historical source qualification to later cumulative Edge code.
