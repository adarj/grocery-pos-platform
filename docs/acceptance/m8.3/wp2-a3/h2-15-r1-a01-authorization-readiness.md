# M8.3.3 WP2-A3 — H2.15-R1 A01 Physical Execution Authorization and Readiness Record

**CANDIDATE — PENDING HUMAN EXECUTION AUTHORIZATION**

**R1-A01 PHYSICAL EXECUTION IS NOT YET AUTHORIZED.**

Candidate revision 1, prepared 2026-10-22 UTC. This document prepares separate
human decisions and blank native readiness records. It grants no permission,
records no new physical result and creates no execution ledger. All proposed
operations below are conditional on later explicit approval; none was performed
while preparing this candidate.

## Authority and pinned identities

The [ratified criteria](h2-15-qualification-criteria-r1.md) and
[ratification record](h2-15-r1-ratification.md) establish three qualifying
cycles, with historical **R1-C1**, processes 4433/4525, already credited.
**H2.15 remains IN PROGRESS — NOT PASS: 1 credited, 2 remaining.** Ratification
and historical credit do not constitute any of Decisions A, B or C below.

| Identity | Required reference |
| --- | --- |
| Branch | `feat/barcode-scanner-slice` |
| Authorization-candidate preparation baseline | `16ea6253ac2d10ea2a27aacac870edaf5b0c6402`; committed execution-plan location |
| Qualification baseline retained by the plan | `ea3ac49f467e5d246b1ba7dcbe6486119aee3903`; do not silently replace it with the preparation baseline or an arbitrary latest HEAD |
| Criteria | H2.15-R1, SHA-256 `288c66beaf76c34ef00bf25bf4562cff1d42bfa02a56dc7622a0311b25444aad` |
| Execution procedure | [Committed plan](h2-15-r1-execution-plan.md), candidate 1 with Bash clarification, SHA-256 `c3d2c50e84a86c66f66bf80322a523657c37ea62ea201224f447c5b1c1ae451d` |
| Diagnostic | A3.2, `ds2208_a3_2.py`, SHA-256 `cfa4ae38c162eec5a2f048ca2c95c8a0c60da6dfc5f409b6d6c425ccd17d3d7d` |
| Saved source-validation report | S2, `synthetic-tests.txt`, 14,227 bytes, SHA-256 `4e7639d4f9a7bf3311f4eda81b395b50aae8bc60397dff3aba37796bb3dbd785`; 91 saved passing tests |

The preparation baseline had a clean index/worktree. The available original
diagnostic and saved report in `~/Scripts/a3-2/` matched these identities.
Static inspection found 91 test definitions and 91 saved passing entries with
an `OK` footer; neither source nor tests were executed. The
[evidence index](evidence-index.md#storage-preservation-and-privacy) explains
D2/S2 provenance and the owner's attestation linking the saved report to its
native run. A matching hash identifies bytes, not current hardware readiness.

For eventual execution record actual HEAD/status and the approved candidate
revision/digest separately from the pinned qualification baseline. Unexpected
changes require review; do not reset the repository, substitute source or
rerun tests automatically. A mismatch in any required identity is NO-GO.

## Proposed R1-A01 boundary

| Dimension | Proposed scope, pending approval |
| --- | --- |
| Attempt | **R1-A01 only** |
| Target qualifying cycle | **R1-C2**, not yet credited |
| Scanner | One operator-selected physical Zebra DS2208 `05e0:1701` |
| Interface | USB CDC ACM with Linux `cdc_acm`; exact CDC communications/data mapping from the plan |
| Host | Native Fedora Kinoite 44 ARM64 in the established VMware Fusion / Apple M1 VM; actual kernel recorded, not assumed |
| Diagnostic | Exact A3.2 bytes identified above; no revision substitution |
| Operator | Human project owner; actual operator attestation remains PENDING |
| Physical activity | One controlled manual USB disconnect/reconnect, only at the diagnostic's prescribed checkpoints |
| Scanner input | Required synchronization presentation and one expected acquisition presentation, only at their respective armed checkpoints |
| Cleanup | Both original processes and attachment-specific temporary ACL dispositions accounted for |
| Evidence | Original persistent terminal outputs, timing verifier, independent arithmetic, byte counts and SHA-256 hashes |
| Outcome | Later independent evidence review; completion or exit status grants no cycle credit |

Campaign planning allows at most three additional attempts to obtain the two
remaining cycles. This candidate covers only the first proposed attempt.
**R1-A02 and R1-A03 remain unauthorized**, regardless of A01's outcome or
unused slots. No fourth attempt, retry or expanded scope is implied.

## Proposed operations and exclusions

Only after explicit human approval covering the relevant class below:

1. Inspect native environment, tooling and allowlisted USB/sysfs identity
   without scanner opens or serial-descriptor collection.
2. Run A3.2 `preflight --device` for the independently selected A node and,
   after replacement permission, the independently selected B node. This
   diagnostic phase does not open the scanner; its access result is advisory.
3. Perform the plan's temporary identity-scoped ACL backup, grant, verification
   and safe restoration procedure separately for A and B, if approved/needed.
4. Launch `hold-reconnect` through the plan's exact T1 output-only logging
   wrapper, with disconnect/reconnect/comparison limits 30/45/60 seconds.
5. Manually remove and return only the intended scanner at the explicit
   disconnect/reconnect checkpoints. No software USB manipulation is proposed.
6. Launch `fresh-attachment-check` through the exact T2 wrapper after owner
   permission, with current independent replacement facts, inherited absolute
   deadline, `--expected-count 1` and `--seconds 10`.
7. Present one synchronization record when requested, discard it, maintain the
   quiet interval, then present the private expected barcode once when armed.
8. After both processes are accounted for, run the existing pure
   `verify-overlap` operation on this attempt's four recorded endpoints.
9. Independently recompute integer containment and overlap from original logs.
10. Preserve original evidence and complete safe process/ACL cleanup.

Use the [plan's launch templates](h2-15-r1-execution-plan.md#persistent-logging-and-exact-launch-templates)
and [eight-phase choreography](h2-15-r1-execution-plan.md#phase-by-phase-operator-choreography)
unchanged. This record introduces no new flags, shell wrapper, diagnostic mode,
signal policy or timing allowance. The approved diagnostic alone performs its
existing bounded terminal/exclusivity preparation and cleanup; its DTR/RTS
checks are read-only and require the qualified ready state.

The proposed scope excludes diagnostic modification, scanner programming,
arbitrary DTR/RTS changes, root diagnostic execution, broad group/permission
changes, first-node selection, automatic reopen/retry after retirement and
relaunch under the same attempt ID. It excludes automatic acceptance, further
attempts without new human review/authorization, production Rust/Core work or
qualification, and unapproved off-host evidence transfer. No scanner writes,
USB resets, driver manipulation or host-policy changes are proposed.

## Native readiness classes and GO / NO-GO matrix

**Class A — Environment and tooling:** contains two different kinds of work:

- **Read-only inspection:** inspect repository/source identities, hash existing
  files, inspect the native environment and installed tools/interfaces, and
  assess available storage, existing parent permissions and intended evidence
  paths. These checks do not open the scanner or modify its permissions.
- **Conditional local custody preparation:** creating private campaign/attempt
  directories, attempt-local diagnostic/report copies, reserved evidence files
  or permitted logger-readiness output in a private temporary file, and setting
  permissions on newly created private directories/files are filesystem writes.
  Perform them only after separate explicit human authorization covering those
  custody operations. Record the authorization reference; if included in
  Decision B's exact scope, custody preparation must be expressly approved.

Neither read-only completion, plan adoption nor this candidate authorizes those
local writes. Custody-preparation approval alone grants no scanner access,
diagnostic execution, USB action or device ACL change, and does not grant Class
B or C authority. Inspection alone cannot satisfy gates requiring verified
prepared files/directories. This documentation correction creates none of them
and performs no native Fedora readiness check.

**Class B — Selected-device preflight and access preparation:** require explicit
approval for the specified diagnostic and device/ACL operations. Decision A
alone is insufficient. Under Decision B, original-A checks precede attempt
declaration. Replacement-B checks recur only after the plan's
`FRESH_PREPARATION_PERMITTED` checkpoint; B does not exist as a verified
replacement before the timed run.

**Class C — Timed physical execution:** requires explicit Decision B physical
authorization plus the separate Decision C native readiness release. All
prelaunch Class A and original-A Class B gates must be GO. B's future identity
cannot be preapproved: its selected-device gates must pass again before T2
opens FD-B, within the existing shared deadline. Approval of the conditional
procedure is not a prefilled replacement identity or a waived gate.

Every row starts **PENDING**, not GO. Retain the native evidence/reference and
operator assessment for each. Unknown, unsupported or failed checks are NO-GO;
do not install tools, bypass guards or widen scope to clear them.

| Gate / class | GO evidence required | NO-GO treatment | Native result |
| --- | --- | --- | --- |
| A-01 / A — Qualification identity | Branch, actual HEAD/status, pinned qualification baseline, exact criteria/plan hashes and any later documentation commit reviewed | Missing/mismatched identity or unreviewed work: stop for review | PENDING |
| A-02 / A — Diagnostic/report | First inspect/hash existing original D2/S2 read-only and acknowledge saved 91-test provenance; create attempt-local copies only during separately authorized custody preparation, then independently verify each against the approved originals and stated hashes/sizes | Missing, inconsistent or altered originals/copies prevent GO; no substitution, diagnostic execution or automatic synthetic-test rerun follows from verification | PENDING |
| A-03 / A — Environment | Actual Fedora 44 release, aarch64 architecture and kernel; ordinary native user; operator confirms Kinoite/VMware/M1 and intended VM; private same-VM/same-boot reference | Root/container/sandbox, unknown provenance, reboot or environment change: re-review before combining evidence | PENDING |
| A-04 / A — Required tools | Native Bash, Python 3, util-linux `script`, `getfacl`, `setfacl`, `fuser`, `stat`, `sha256sum`; also `git`, `uname`, `cat`, `id`, `wc` and chosen private-directory/copy/capacity tools used by the plan; human `sudo` available only if approved ACL work requires it | Any missing required tool or unsupported command: NO-GO pending separate corrective decision; no installation | PENDING |
| A-05 / A — Child shell | Independently resolve Bash in each terminal using the plan's checks; reject aliases/functions, require matching absolute executable-file paths; both wrappers set `SHELL` to that path | Ambiguous/nonexecutable/different paths or unsupported native `script` interpreter-selection behavior: NO-GO | PENDING |
| A-06 / A — Custody/storage | Read-only: assess unique intended campaign/attempt paths, trusted private parent permissions, capacity and absence of symlinks/collisions; only after explicit custody approval, exclusively create/verify the private directory and necessary files, modes 0700/0600 and umask 077; retain the plan's at-least-64-MiB margin | A planned path is not an existing verified directory; absent approval, uncreated/unverified storage, reused target, unsafe access or insufficient capacity prevents GO; no overwrite or launch | PENDING |
| A-07 / A — Terminals/logger | Two prepared native interactive terminals; native `script` supports `--quiet --flush --return --echo never --log-out --command` and documented `SHELL`; interactive canonical PTY, output-only capture, echo disabled, child return codes retained; private known fixture and checkpoint rehearsal | Unverified native behavior, stdin piping, input/combined logging, tracing or setup left for timed handoff: NO-GO; syntax checks alone are insufficient | PENDING |
| B-01 / B — Intended USB profile | Operator confirms intended scanner; fresh allowlisted USB/interface/driver ancestry, one `05e0:1701`, communications `02/02/01`, data `0a/00/00`, `cdc_acm`, one correlated endpoint | Wrong/absent/ambiguous profile or first-node assumption: no open | PENDING |
| B-02 / B — Node/preflight/users | Selected-node A3.2 preflight; device-node/TTY/character/sysfs facts agree; native `fuser -v` and ownership review account for competing opens | Contradiction, unexpected users or insufficient visibility: stop; no implicit service stop or kill | PENDING |
| B-03 / B — Original access | A's current identity and own ACL/node-key backup verified before any separately approved temporary grant; recheck same identity and effective R/W afterward | Failed guard, missing rights or changed object: no retry by pathname, privilege bypass or owner launch | PENDING |
| B-04 / B — Replacement access | Before launch, review B's procedure and prepare distinct unused paths; during Phase 4 independently verify actual B, preflight/users, own ACL backup/key and any approved grant; recheck access and facts | B facts remain unknown until reconnect; missing/mismatched/ambiguous B evidence blocks T2, never use A's backup | PENDING |
| C-01 / C — Authority/release | Decisions A/B explicit, all prelaunch gates documented GO, Decision C explicitly recorded; conditional B recheck remains mandatory | Any pending decision or prelaunch gate: no attempt declaration or owner launch | PENDING |
| C-02 / C — Launch/handoff | Before launch, exact wrappers/exports prepared and handoff-check procedure rehearsed; during execution, new events supply actual PIDs/deadline and T2 uses the owner's Python interpreter and absolute deadline | Reused historical values, altered argv, absent runtime handoff or deadline renewal: stop | PENDING |
| C-03 / C — Human/quiet state | One human-controlled sequence; scanner aimed away from barcode cards; synchronize only on request, remove card immediately, scan expected fixture only after fresh arm within retired probe | Uncertain device/checkpoint, premature input or uncontrolled presentation: cancel; no speculative acknowledgement | PENDING |

Prelaunch ordering, explaining the existing authorization boundaries:

1. Perform permitted read-only Class A inspections.
2. Obtain explicit human authorization for the specified local custody writes;
   Decision A and the candidate's existence do not supply that authorization.
3. Only then create and verify the private evidence directory, attempt-local
   copies and any permitted logger-readiness artifacts.
4. Complete the applicable prelaunch GO/NO-GO evidence, including original-A
   Class B checks only under their separate authorization; the final readiness
   release is recorded next.
5. Obtain explicit Decision C native readiness release based on completed
   readiness evidence. Decision C need not precede approved custody preparation.
6. Declare R1-A01 according to the committed plan's attempt-declaration rule.
7. Launch the original owner only when separate physical-execution authorization
   and all required gates permit it.

This sequence grants no permission and adds no fourth formal decision. A
readiness NO-GO before declaration remains a readiness record, not a consumed
physical attempt.

For B-04 and C-02, prelaunch GO covers procedure/preparation only. Their actual
replacement and handoff checks remain deferred to the specified runtime
checkpoints; readiness release cannot certify those future observations.

Recheck environment/boot continuity and current selected-device facts when the
second process is prepared. Matching pathnames, major/minor values, topology,
sysfs spellings or retained `fstat()` are corroboration only; none restores
retired FD-A authority. No specific `/dev/ttyACM*` allocation is required.

### Attachment-specific ACL and logging safeguards

The [committed ACL procedure](h2-15-r1-execution-plan.md#device-scoped-acl-procedure--future-human-operations-only)
is the sole proposed procedure, subject to Decision B's actual scope:

- A and B have separate contemporaneous full identities, ACL backups and node
  keys. Verify the direct character node, complete USB correlation and immediate
  key guards before and after any permitted grant. A node key alone is not
  atomic replacement proof.
- Restore a role's original ACL only after its process closes, while that
  exact identity remains valid and no intervening replacement is known.
- If A's node disappeared, record A restoration **not applicable after removal**;
  do not restore A's backup to a recreated pathname. Manage B independently.
- Missing or ambiguous current identity means **refuse restoration by pathname**,
  retain evidence and seek human review. Unexpected cleanup is not a reason to
  apply stale permissions. No permanent `dialout`, world access or root diagnostic.

Future logs must be persistently captured from process start through cleanup,
using the unchanged output-only wrappers with validated `SHELL`, disabled echo,
unchanged exports and return-code files. Never truncate, append to, reuse or
reconstruct originals. Enter the known fixture only at the hidden prompt; do
not put it in flags, environment, transcripts or this record. Output-only
capture and native PTY behavior must be verified before GO. Keep scanner
presentation controlled throughout quiet and terminal-handoff intervals.

## Attempt identity, timing and declaration

Use campaign **H2.15-R1 prospective campaign**, attempt **R1-A01**, target
**R1-C2**, owner **FD-A** and independent replacement **FD-B**. Actual Python
PIDs, shared deadline, USB addresses, nodes and sysfs objects remain unknown
until this execution; do not copy historical R1-C1 values into the new fields.

Proposed private location:
`.local/qualification/m8-3/wp2-a3-r1/<approved-campaign-id>/R1-A01/`.
Create it only under later approved custody preparation, with exclusive
creation, trusted private parents and absent log targets. This task creates
no evidence directory or artifact. The historical archive remains intact.

Per the committed plan, declare the attempt after prelaunch readiness release
and **before launching the owner**. Any incomplete preparation, cancellation
or timeout after declaration consumes the attempt allowance. No relaunch or
resumption under R1-A01 is permitted. A readiness NO-GO before declaration
is a readiness record, not a physical attempt result.

| Control | Preserved limit / consequence |
| --- | --- |
| Owner | One immutable 360-second deadline, including its startup/preparation |
| Fresh | Inherits owner's exact absolute deadline; no new time allowance |
| Manual removal / return | At most 30 / 45 seconds, clipped by remaining work time |
| Comparison | At most 60 seconds from the plan's `fresh-ready` transition |
| Retired probe | 10 seconds, at most 50 read attempts; separate forensic samples are not this interval |
| Fresh acquisition | Configured 10 seconds; entire actual fresh interval must fit inside the already running probe |
| Synchronization | Existing 172-second ceiling and source iteration/discard bounds, clipped by shared work end |
| Cleanup | Existing 8-second reserve; existing per-operation guards and best-effort cleanup limitations unchanged |
| Other limits | Unrelated 180-second watchdog and all read/queue/input/checkpoint bounds remain unchanged |

No acknowledgement resets a deadline. Follow the plan's actual checkpoints
and [timing reconciliation](h2-15-r1-execution-plan.md#timing-reconciliation-and-return-codes),
not independent timers derived from this summary. Human acknowledgement is
not evidence that a physical phase completed. No preactivation, parser-state
or Core-publication authority is introduced by this diagnostic campaign.

## STOP — operator-facing rules

At an acknowledgement prompt use the existing `abort` or `fresh-failed` as
appropriate; during acquisition/probing cancel with Ctrl+C. Account for both
foreground processes and their guarded cleanup. Do not reopen, reconnect
again, alter signals or restart to obtain a pass. A stopped attempt cannot
resume under its old identity. Apply the
[plan's stop rules](h2-15-r1-execution-plan.md#stop-rules-and-disposition).

| Condition | Required disposition / escalation |
| --- | --- |
| Identity ambiguity, contradictory metadata or unexpected competing user | Stop preparation/execution. Expected removal may retire safely; unexplained contradiction requires investigation. Proven wrong-attachment authority is FAIL. |
| Failure to retire FD-A or authorized normal delivery after retirement | Stop campaign; demonstrated safety/continuity violation is FAIL. |
| Positive retired-FD forensic bytes | Stop campaign for investigation; INCONCLUSIVE unless a violation is demonstrated. Do not claim migration or PASS merely from positive bytes. |
| Missing fresh synchronization, premature input, mismatch or extra record | Cancel; INCOMPLETE pending cause review unless a safety/continuity violation is demonstrated. Never guess a boundary or reuse that process. |
| Missed checkpoint, deadline or operator cancellation/uncertainty | Cancel and clean up; INCOMPLETE absent separately demonstrated invariant failure. Do not resume/rearm. |
| Missing/untrustworthy original logs, wrong process attribution or source mismatch | NO-GO before declaration; after declaration stop and mark evidence incomplete/inconclusive. No substituted source or reconstructed logs. |
| Invalid/missing endpoints, partial overlap or missing new verifier output | No cycle credit; INCOMPLETE. Entire fresh interval must be contained, not merely overlapping. |
| Unexpected cleanup or ACL restoration behavior, absent closure | Stop campaign and investigate. INCONCLUSIVE until resolved; demonstrated unsafe restoration/ownership is FAIL. No blanket EIO waiver. |

**QUALIFYING CYCLE** means all mandatory criteria/evidence are satisfied and
independently reviewed; operator completion remains a candidate result until
that review. **INCOMPLETE / INCONCLUSIVE** means qualification evidence is
insufficient without a demonstrated safety defect. **FAIL** means a demonstrated
applicable invariant violation. Exit 0, warning exit 3, an acknowledgement or a
verifier result alone determines none of these. Preserve every attempt and
stop outcome; material anomalies require explicit human investigation before
any further authorization, and later success cannot erase them.

## Human authorization decisions — all PENDING

These are three separate decisions for later completion by the project owner.
The existence, review or eventual commit of this candidate fills none of them.
The actual accepted scope may be narrower; if that prevents a mandatory gate,
record NO-GO rather than improvising a different procedure.

### Decision A — Execution-plan adoption for R1-A01

Proposed decision: adopt the exact committed plan above as R1-A01's operational
procedure. Adoption alone authorizes no local custody preparation, diagnostic,
ACL or USB operation.

| Decision field | Entry |
| --- | --- |
| Adoption decision | **PENDING** |
| Reviewed plan commit / revision / digest | **PENDING** |
| Human decision-maker / timestamp / authority reference | **PENDING** |
| Accepted scope / conditions or exclusions | **PENDING** |

### Decision B — Physical execution authorization

Proposed decision: expressly authorize the listed bounded operations for
**R1-A01 only**, including Class B selected-device preflight and any specified
temporary ACL operations. The original/replacement are constrained by the
verified profile and full plan procedure, not a hardcoded node. Timed Class C
actions remain conditional on separate Decision C release and runtime gates.

If local custody preparation is included in Decision B's exact scope, expressly
identify the permitted local writes and private destinations. Otherwise retain
a separately explicit human custody-preparation authorization reference before
those writes. Neither plan adoption nor unspecified physical/logging approval
implies custody-preparation approval; custody approval alone confers no device
or physical-execution authority.

| Decision field | Entry |
| --- | --- |
| Physical/device-operation authorization decision | **PENDING** |
| Exact approved A01 scope, environment, diagnostic identity and operator | **PENDING** |
| Permitted local custody preparation (if approved), USB, preflight, A/B ACL, logging, cleanup and post-run verification operations | **PENDING** |
| Attempt limit, stop conditions and any narrower restrictions | **PENDING** |
| Human decision-maker / timestamp / authority reference | **PENDING** |

### Decision C — Native readiness release

Proposed decision: after actual native readiness evidence is retained, explicitly
release the one timed attempt. Verify all prelaunch Class A and original-A
Class B gates, both earlier decisions, quiet scanner, terminal/logger
preparation and the conditional replacement recheck procedure. Decision C cannot
replace Decision B or certify the replacement before it appears.
It is the final prelaunch release after completed approved custody preparation
and verification, not a prerequisite for obtaining custody approval or carrying
out that approved local preparation.

| Decision field | Entry |
| --- | --- |
| Native GO / NO-GO and release decision | **PENDING** |
| Completed readiness rows / original evidence references / remaining conditions | **PENDING** |
| Confirmation of Decisions A/B and exact authorized scope | **PENDING** |
| Actual environment, selected A identity, private evidence directory and operator | **PENDING** |
| Human readiness releaser / timestamp / authority reference | **PENDING** |
| Attempt declaration and owner-launch clearance | **PENDING** |

No new signature, human name, approval time, physical result or qualifying credit
is supplied here. Additional physical testing remains unauthorized until the
appropriate explicit decisions actually exist.

## Blank private readiness / authorization manifest

This is a template for a later separately authorized private record; it is not
a completed manifest or a machine-readable qualification ledger. Keep private
runtime identities in that record, outside tracked source.

```text
Campaign / attempt / target (proposed): H2.15-R1 / R1-A01 / R1-C2
Candidate revision / externally recorded digest: PENDING
Decision A: PENDING; reviewed plan commit / revision / digest: PENDING
Decision B: PENDING; exact approved physical/device/ACL scope: PENDING
Decision C: PENDING; native release evidence and authority: PENDING
Human execution authorization reference / decision dates: PENDING
Qualification baseline / actual branch / HEAD / reviewed status: PENDING
Criteria / plan / diagnostic / saved-report verification references: PENDING
Qualified diagnostic revision / digest and saved-run provenance: PENDING
Native readiness row results / evidence paths: PENDING
Actual OS / kernel / same-VM-same-boot provenance: PENDING
Attempt declaration / time / allowance accounting: PENDING
Private attempt evidence directory / access / capacity: PENDING
Actual operator / attestation: PENDING
FD-A PID / actual A node / USB-character-sysfs identities: PENDING
FD-B PID / actual B node / USB-character-sysfs identities: PENDING
Shared absolute deadline / four interval endpoints: PENDING
Original log / verifier / arithmetic / cleanup / ACL references: PENDING
Stop conditions adopted / anomalies / actions: PENDING
Artifact relative paths / byte counts / SHA-256: PENDING
Post-attempt disposition / conditions: PENDING
Independent reviewer / date / evidence decision / cycle credit: PENDING
```

## Evidence and independent post-attempt review

Use the plan's [evidence bundle](h2-15-r1-execution-plan.md#per-attempt-evidence-bundle-and-blank-manifest-template)
and [ten-criterion matrix](h2-15-r1-execution-plan.md#independent-requirement-to-evidence-matrix)
for all H2.15-R1-001 through H2.15-R1-010. Preserve:

- Source/report/criteria/plan identity, environment and native readiness evidence.
- Both complete original terminal outputs and exit files; select actual Python
  owner/fresh PIDs, not logger/preflight PIDs. Shared deadline, attempt and
  phase must agree; keep other process output intact but distinguish it.
- Original/replacement facts, first retirement cause, subsequent loss/forensic
  outcomes, irreversible retirement, separate FD-B preparation and real CRLF
  synchronization discard.
- Fresh exact-match evidence, all four monotonic endpoints, the **actual new
  timing-verifier transcript** and independent containment/overlap arithmetic.
  The whole fresh interval must lie within the retired probe on the same VM/boot.
- Both processes' restoration/release/closure and exit outcomes; separate A/B
  ACL backup/grant/cleanup dispositions and any explained warning.
- Original artifact byte counts/SHA-256, operator attestations and identified
  limits; retain incomplete/failed evidence and named independent review.

The missing-verifier exception applies **only to R1-C1**. Do not reconstruct
missing originals from chat, expose the private barcode/fixture, store raw input
buffers or read USB serial descriptors. Follow the existing
[private custody policy](evidence-index.md#evidence-custody-preservation-and-recovery);
do not modify historical archives. Same-VM copies are not an off-host backup;
no off-host transfer is authorized.

No R1-C2 credit may be granted before independent human examination against
all ten requirements. Even reviewed A01 success would leave a further cycle
and separate campaign review; **R1-A02 remains unauthorized** until a new human
decision. An incomplete A01 is not a qualifying cycle and consumes its slot
after declaration. Preserve the distinction between physical observations,
saved diagnostic tests, attestations, arithmetic and human decisions.

## Findings, qualification boundaries and preparation checks

| Severity | Finding / remaining obligation |
| --- | --- |
| BLOCKER | No material baseline/source mismatch or documentation-readiness blocker identified. A future digest discrepancy, absent authority or failed native gate prevents execution. |
| MAJOR | No new confirmed defect identified in this documentation preparation. The historical prospective criteria-authority gap was resolved by ratification, not recovered as an earlier standard; H2.15 still lacks two qualifying cycles. |
| MINOR | Original A3-01/first-attempt/verifier transcripts remain unavailable; H2.07's scan-before-disconnect evidence gap remains separate. C1's narrow exception neither recovers originals nor waives new evidence. |
| INFORMATIONAL | All actual native readiness outcomes are PENDING. Source/report inspection and hashes do not establish current device, tool, permission, PTY or physical readiness. |
| INFORMATIONAL | H-VM, one-scanner and sampled-probe coverage is bounded; same-path/major-minor reuse within a retained pair remains unproven physically. Python diagnostic framing is not Rust WP1 execution. |

The [historical audit](audit-report.md) and
[qualification matrix](qualification-matrix.md) remain unchanged. H2.08/H2.09
remain proposed bounded PASS findings; H2.13 retains its accepted **PASS WITH
EXPECTED CLEANUP WARNINGS**, and A3-01 retains accepted PASS for idle disconnect.
This candidate neither closes H2.07 nor accepts another gate or WP2-A3 as a
whole. Production Rust/Core/Racket integration, business mutation, bare-metal,
multiple-scanner and deployed DAC/SELinux qualification remain excluded.

Preparation checks are repository/index cleanliness, governing/source/report
digests, read-only CLI/report inventory, link/heading and scope/status/count
consistency, privacy, Markdown/whitespace and final one-file inventory. No
native preflight, diagnostic/test/verifier execution, device access, termios,
USB, ACL, evidence-copy operation or broad product test was performed. Frozen
M8.2 evidence and all prior records remain untouched. Staging and Git history
operations are outside this task. Stop for independent review and explicit
human authorization.
