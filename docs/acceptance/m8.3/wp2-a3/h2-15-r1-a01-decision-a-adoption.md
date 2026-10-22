# M8.3.3 WP2-A3 — H2.15-R1 A01 Formal Decision A: Execution-Plan Adoption

**DECISION A APPROVED — DECISIONS B AND C PENDING — PHYSICAL EXECUTION NOT AUTHORIZED**

This record documents an explicit human decision already made. It adopts the
identified procedure for **R1-A01 only**; it grants no permission to execute
that procedure. **R1-A01 physical execution remains NOT AUTHORIZED.**

## Human declaration and provenance

Human authority: **Grocery POS Platform project owner**.
Human decision timestamp: **2026-10-22 19:42:54 UTC**.

The owner declared in the Grocery POS Platform development conversation:

> I formally adopt the H2.15-R1 Physical Qualification Campaign Execution Plan, candidate revision 1, committed at `16ea6253ac2d10ea2a27aacac870edaf5b0c6402` with SHA-256 `c3d2c50e84a86c66f66bf80322a523657c37ea62ea201224f447c5b1c1ae451d`, as the operational procedure for R1-A01 only.
>
> This adoption does not authorize local custody preparation, scanner diagnostic execution, USB operations, device ACL changes or physical experimentation. Decisions B and C remain separate and pending.

The supplied declaration is the source of Decision A's approval and its
restrictions. Codex records it under the present documentation-only task,
without independently approving, expanding or reinterpreting that scope.
No additional human signature, approval, review timestamp or execution
authorization is asserted. A later signed Git commit is a separate owner action.

Preparation baseline: branch `feat/barcode-scanner-slice`, HEAD
`125e4395087142ee0819691750d359168674f590`. The adopted plan's pinned
qualification baseline remains `ea3ac49f467e5d246b1ba7dcbe6486119aee3903`;
this record does not substitute its own preparation baseline for that identity.

## Recorded Decision A

| Decision field | Recorded value |
| --- | --- |
| Decision identifier | **H2.15-R1 / R1-A01 / Decision A** |
| Decision type | Formal adoption of execution procedure |
| Disposition | **APPROVED** |
| Human authority | Grocery POS Platform project owner |
| Human decision timestamp | **2026-10-22 19:42:54 UTC** |
| Governing plan | [H2.15-R1 Physical Qualification Campaign Execution Plan](h2-15-r1-execution-plan.md), candidate revision 1 |
| Governing plan commit | `16ea6253ac2d10ea2a27aacac870edaf5b0c6402` |
| Governing plan SHA-256 | `c3d2c50e84a86c66f66bf80322a523657c37ea62ea201224f447c5b1c1ae451d` |
| Authorized procedural scope | **R1-A01 only** |
| Target qualifying cycle | **R1-C2**, not yet credited |
| Custody preparation | **NOT AUTHORIZED** |
| Scanner diagnostic execution | **NOT AUTHORIZED** |
| USB and physical operations | **NOT AUTHORIZED** |
| Device ACL operations | **NOT AUTHORIZED** |
| Native readiness release | **NOT GRANTED** |

**Authorized procedural scope means adoption of a procedure, not permission
to execute its steps.** This record is not a revised execution plan, a replacement
authorization candidate, a native readiness report, an execution ledger, evidence
of another qualifying cycle or authorization to operate the scanner.

## Governing references and verified identities

| Item | Pinned reference |
| --- | --- |
| [Ratified H2.15-R1 criteria](h2-15-qualification-criteria-r1.md) | SHA-256 `288c66beaf76c34ef00bf25bf4562cff1d42bfa02a56dc7622a0311b25444aad` |
| [Formal ratification and historical cycle credit](h2-15-r1-ratification.md) | Commit `ea3ac49f467e5d246b1ba7dcbe6486119aee3903` |
| [Original A01 authorization/readiness candidate](h2-15-r1-a01-authorization-readiness.md) | Commit `125e4395087142ee0819691750d359168674f590`; SHA-256 `94a508ef760897956c5e13fad06316bd869e9a78b9786d8992b62fa2dbd460fc` |
| A3.2 diagnostic, source D2 in the [evidence index](evidence-index.md#storage-preservation-and-privacy) | SHA-256 `cfa4ae38c162eec5a2f048ca2c95c8a0c60da6dfc5f409b6d6c425ccd17d3d7d` |

The applicable current files and the criteria, plan and candidate bytes at
their referenced commits were checked against their required digests before
authoring. The available original diagnostic also matched its stated digest;
it was not executed. The ratification record was verified unchanged against
its committed bytes. These checks establish document/source identity, not
native hardware readiness or a new verification of human identity/signatures.

## Chronology and the original authorization candidate

The committed A01 candidate predates the owner's declaration. Its fifteen
human-decision fields were correctly **PENDING** when authored and committed.
Those entries and the original governing records remain unchanged historical
snapshots; they were not erroneous and are not rewritten here.

The later authoritative state is:

| Decision | Current disposition | Basis / unresolved fields |
| --- | --- | --- |
| Decision A — Execution-plan adoption | **APPROVED** | Owner's declaration above resolves its four candidate fields by reference to this record |
| Decision B — Physical execution authorization | **PENDING** | All five candidate fields remain unresolved |
| Decision C — Native readiness release | **PENDING** | All six candidate fields remain unresolved |

Decision A's four fields are resolved as follows:

1. Adoption decision: **APPROVED** by the supplied human declaration.
2. Reviewed plan commit, revision and digest: the exact plan identified in
   [Recorded Decision A](#recorded-decision-a).
3. Human decision-maker, timestamp and authority reference: the project owner,
   **2026-10-22 19:42:54 UTC**, and the declaration reproduced above.
4. Accepted scope and conditions: **R1-A01 procedural adoption only**, with
   every restriction in that declaration preserved.

The other **eleven Decision B/C fields remain unresolved**. All **fourteen
native GO/NO-GO readiness rows remain PENDING**; this record supplies no new
physical or native-environment evidence and does not mark any row GO.
Future authorization records should cite this formal Decision A record when
evaluating procedural adoption, while retaining the candidate's preparation
chronology. Adoption does not automatically satisfy Decision B, Decision C
or any readiness row.

## Explicit limits of adoption

Decision A does **not** authorize:

1. Creating private prospective evidence directories.
2. Copying diagnostic/report files into attempt-local custody.
3. Native PTY/logger runtime tests that create files.
4. Scanner diagnostic preflight, owner or fresh modes, including `preflight`,
   `hold-reconnect` and `fresh-attachment-check`.
5. Manual scanner USB disconnect/reconnect or other physical experimentation.
6. Device ACL grants, restoration or other permission changes.
7. Scanner reprogramming or modem-control changes.
8. Attempt declaration or owner-process launch.
9. R1-A02 or R1-A03.
10. Any new qualifying-cycle credit.

Non-invasive read-only inspection remains distinct from filesystem custody
writes, diagnostic/device access and physical operations requiring explicit
authorization. This record grants none of those permissions. Custody preparation
still needs its separately explicit human approval; plan adoption cannot supply
it. This documentation task performs no native readiness assessment.

## Qualification state retained

| Item | Disposition |
| --- | --- |
| H2.15-R1 criteria | **RATIFIED** |
| Historical R1-C1, 4433/4525 | **FORMALLY CREDITED** |
| R1-A01 operational procedure | **FORMALLY ADOPTED** |
| R1-A01 physical execution | **NOT AUTHORIZED** |
| R1-C2 qualification | **NOT YET EARNED** |
| R1-C3 qualification | **NOT YET EARNED** |
| H2.15 overall | **IN PROGRESS — NOT PASS** |
| Remaining qualifying cycles | **2** |
| Proposed maximum additional attempts | **3**, subject to individual authorization |

The existing [audit](audit-report.md),
[qualification matrix](qualification-matrix.md) and later ratification retain
their distinct chronology and authority. H2.07 remains **partially
substantiated**; H2.08/H2.09 remain **proposed bounded PASS findings**. H2.13
retains its previously accepted **PASS WITH EXPECTED CLEANUP WARNINGS**, and
A3-01 retains its accepted idle-disconnect PASS. No adjacent gate is accepted
or evidence gap closed by Decision A.

The narrow missing-verifier-transcript exception remains limited to historical
R1-C1. Every new qualifying cycle requires its original verifier output and all
other mandatory evidence. Earlier incomplete attempts gain no cycle credit.
No production Rust adapter, Racket/Core binding or observation path, bare-metal
appliance, multiple-scanner behavior or deployed security policy is qualified.
H-VM diagnostic observations, saved synthetic evidence and future production
qualification remain separate layers.

## Remaining authorization checkpoints

### Decision B — Physical execution authorization

**PENDING**

The future decision must expressly define R1-A01's precise permitted operations,
including any approved local custody preparation, scanner diagnostic, temporary
identity-scoped ACL handling, manual USB activity, logging and cleanup. It must
identify the governing plan and diagnostic by their approved hashes and retain
all campaign stop rules. No Decision B outcome is proposed or preapproved by
this record. Unused campaign slots authorize no additional attempt.

### Decision C — Native readiness release

**PENDING**

This future decision requires actual native readiness evidence, completed
applicable prelaunch GO/NO-GO checks, Decision B authorization and explicit
confirmation that the timed attempt may be declared. Approved custody
preparation precedes final readiness release as specified in the existing
candidate; Decision C is not a prerequisite for obtaining that custody approval.
Replacement-device verification still occurs at the prescribed runtime
checkpoint and cannot be completed or waived by initial readiness release.

Repository inspection, saved synthetic tests, documentation checks and the
owner's Decision A declaration establish no native readiness. The adopted
procedure's timing, checkpoint, failure-accounting, evidence and stop rules
remain unchanged. There is no automatic retry or execution permission here.

## Documentation verification and work boundary

Verification for this record consists of branch/HEAD/index/worktree inspection,
required current and historical committed-file digest checks, unchanged-governing
record checks, declaration/timestamp comparison, status/count/scope review,
local links/fragments, privacy, Markdown/whitespace and final one-file inventory.
The new record's digest is reported separately, not embedded inside itself.
No diagnostic, synthetic suite, native readiness or physical test is run.

Only this new Markdown record is created. The original candidate, adopted plan,
criteria, ratification, historical audit/evidence, diagnostic/report files,
production source and frozen M8.2 records remain unchanged. No USB/TTY access,
ACL operation, prospective evidence-directory creation, file copying, logger
runtime test, staging or Git history operation occurs. Stop after documentation
handoff; Decision B and all physical work remain outside this task.
