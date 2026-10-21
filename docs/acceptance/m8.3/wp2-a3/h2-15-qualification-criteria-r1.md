# H2.15 — Repeated Attachment-Cycle Qualification Criteria, Revision 1

**RATIFIED — QUALIFICATION CRITERIA ONLY; H2.15 IN PROGRESS**

Effective human decision date: **2026-10-21 UTC**. The project owner ratified
Revision 1 and separately approved historical cycle-1 credit at
**2026-10-21 07:23:03 UTC**, as recorded in the
[formal ratification record](h2-15-r1-ratification.md).
**H2.15: IN PROGRESS — NOT PASS; 1 of 3 qualifying cycles credited, 2 remain.**
Further physical experimentation remains **unauthorized**.

This document defines the ratified prospective qualification standard. It is
not an execution ledger, test report or physical-test authorization. Criteria
ratification, historical cycle credit, authorization of new experiments and
acceptance of campaign results remain separate human decisions. Codex records
the supplied decisions without making or expanding them.

Prepared against branch `feat/barcode-scanner-slice`, HEAD
`31b003b501a010a0c7f488a4ee6476e7f58e1edc`, which records the conditional
WP2-A3 evidence audit. The [audit report](audit-report.md),
[evidence index](evidence-index.md) and
[qualification matrix](qualification-matrix.md) remain unchanged historical
records. Their statements remain valid for their authorship time. The later
human decisions are recorded separately without editing those historical
documents or granting adjacent-gate acceptance.

## Basis and prospective authority

The conversation-reference H2.15 definition states:

> Run a bounded series of disconnect/reconnect cycles.

Its reference pass condition states:

> Each attachment is independent; no stale descriptor, parser state or queued
> record survives replacement.

The previous audit found no independently established authoritative accepted
local version specifying a repetition count. R1 now adopts a new engineering
threshold and an explicit interpretation of retired-descriptor authority.
It is **not recovery of the missing historical definition**. Broader proposed
engineering-laboratory targets do not establish that missing authority.
The earlier **NOT EVALUABLE AGAINST AUTHORITATIVE CRITERIA** disposition remains
an accurate historical statement. The owner's later ratification resolves
prospective criteria authority; the separate historical-credit decision credits
one cycle. Neither decision establishes an overall H2.15 PASS.

## Bounded qualification scope

The ratified initial scope is one selected physical **Zebra DS2208
`05e0:1701`**, USB CDC ACM with Linux **`cdc_acm`**, on **Fedora Kinoite 44
ARM64 in the documented VMware Fusion / Apple M1 configuration**. Record the
actual kernel/environment for every attempt; the retained successful trial
reports `7.2.11-200.fc44.aarch64`. An environment or device-profile change
requires review before combining results under this scope.

Use the existing externally run Python diagnostic **A3.2** only after verifying
its original source hash and saved validation evidence. Its SHA-256 is:

```text
cfa4ae38c162eec5a2f048ca2c95c8a0c60da6dfc5f409b6d6c425ccd17d3d7d
```

The [evidence index](evidence-index.md#storage-preservation-and-privacy) identifies
source D2, saved 91-test report S2, run-local copies and provenance limits.
A source change requires a separately reviewed diagnostic/validation task;
ratification does not authorize editing or executing the diagnostic.

This H-VM scope excludes other scanners, multiple-scanner operation, other
operating systems, bare-metal appliances, production Rust adapters, actual
Core binding/events, deployed DAC/SELinux enforcement and universal USB
behavior. Generic USB metadata is operational corroboration, not cryptographic
device authentication. No barcode payload or USB serial descriptor belongs
in tracked criteria/evidence summaries or routine diagnostics.

Flutter presents. Racket decides. SQLite remembers. Rust talks to edges.
The cloud coordinates. Diagnostic reception does not establish a sale line,
business command or SQLite mutation.

## Ratified acceptance criteria

The ten requirement bodies below are reproduced byte-for-byte from the
independently reviewed proposal. Proposal-era wording within those preserved
bodies records the threshold's origin; the requirements are now ratified.

### H2.15-R1-001 — Repetition count

Require at least **three individually qualifying coordinated
disconnect/reconnect cycles**. Each must have separately attributable identity,
retirement, fresh-acquisition, comparison and cleanup evidence. Assign each
attempt its own identity and retain process/phase boundaries; never combine
one attempt's successful phase with another's to manufacture a complete cycle.

Three operator attempts do not equal three qualifying cycles. The count of
three is a **newly proposed engineering threshold**, not an inherited
historical requirement or a statistical reliability guarantee.

### H2.15-R1-002 — Original attachment ownership

Begin each cycle with a verified, independently opened original attachment,
FD-A. Retain that exact original descriptor through controlled manual USB
disconnect/reconnect and the comparison probe. Record its held-object and
current USB/interface/TTY correlation before removal. The original owner must
not reopen, retarget or silently substitute a replacement descriptor.

### H2.15-R1-003 — Permanent retirement

Confirmed loss or insufficient identity evidence irreversibly retires FD-A.
Loss indications take precedence over queued input. Clear partial framing
state and completed-but-undelivered records; no buffered state may acquire
authority under the replacement.

Once retired, FD-A cannot resume normal authorized barcode acquisition even
if `fstat()` succeeds, a pathname reappears, metadata matches or a forensic
read returns. Here, **no stale descriptor survives replacement means no
surviving acquisition/publication authority**. An inert retired descriptor may
remain held solely for the explicit bounded forensic probe. Diagnostic
acquisition authority is not a Core binding witness or public event authority.

### H2.15-R1-004 — Replacement corroboration

Independently discover and verify the intended replacement. Preserve actual
USB bus/device address, topology, interface identity/profile, driver, TTY
pathname, device-node filesystem/inode identity, character major/minor,
`/sys/dev/char` correlation and relevant USB/interface/TTY sysfs object facts.
Record disappeared, changed, reused and unavailable facts distinctly.

A pathname, major/minor, canonical sysfs spelling or topology alone does not
authenticate continuity. A generic USB serial descriptor is not unique-unit
proof and must not be collected as a shortcut. Do not demand a particular
`/dev/ttyACM*` name or pick the first endpoint. Missing, inconsistent or
ambiguous evidence fails preparation closed and requires the outcome review
defined below.

### H2.15-R1-005 — Independent fresh preparation

Open FD-B independently in the separate fresh process, with its own verified
descriptor, termios preparation, buffers and parser/framing state. Preserve
DTR-high operational readiness and A3.2's read-only DTR/RTS readiness checks;
no automatic signal or scanner-programming change is authorized here.

Alignment starts **unknown**. Establish it through a genuine CRLF boundary,
discarding the synchronization record before arming the expected acquisition.
Opening, flushing, inactivity, acknowledgement and Core activation do not
establish alignment. Import no parser, partial record, queue or authority from
FD-A. Unexpected pre-arm input follows the existing fail-closed diagnostic
behavior and cannot be counted as the expected scan.

### H2.15-R1-006 — Coordinated acquisition

For each qualifying cycle:

1. Arm the bounded retired-FD probe and record its native monotonic start/end.
2. Independently arm FD-B's fresh acquisition through the human checkpoints.
3. Present exactly the expected physical barcode only when scanning is armed.
4. Require **one exact matched record** from FD-B, preserving the categorical
   result without the fixture or payload value.
5. Independently verify that the **entire** reported fresh interval lies inside
   FD-A's probe interval, using all four endpoints:
   `probe_start <= fresh_start < fresh_end <= probe_end`.
6. Require FD-A to remain permanently retired with no authorized barcode
   delivery throughout; preserve all probe outcomes and readiness flags.

Use native monotonic timestamps from the **same host and boot**, supported by
operator provenance and process/deadline evidence. Positive, correctly ordered
intervals and their full containment are required; partial overlap is
insufficient. For every new cycle, preserve the actual diagnostic
`verify-overlap` output **and** an independent arithmetic check. The reported
verifier result cannot replace interval evidence or physical review.

Preserve the documented **10-second / 50-read probe ceiling**, bounded reads
and source retirement; human checkpoints cannot extend the probe or renew
the global deadline. Positive bytes from FD-A stop the experiment for
investigation and cannot silently qualify. They may be old buffered bytes or
otherwise uncertain; positive forensic bytes without demonstrated unauthorized
delivery do not automatically prove migration. Zero-byte reads alone do not
prove removal or successful fresh transmission. Sampled probe results do not
establish continuous monitoring or every physical decode instant.

### H2.15-R1-007 — Parser and queued-state limitations

Confirm the exact diagnostic source and its saved 91-test evidence protect:

- Removal after partial input and discard of completed-but-undelivered records.
- Queue clearing on retirement and independent fresh parser state.
- No authority restoration through reused names or metadata.
- No automatic descriptor reopening.

The evidence index's
[source anchors and synthetic protections](evidence-index.md#diagnostic-source-anchors-and-synthetic-protections)
identify the existing regressions. Source inspection and synthetic outcomes
support the software model; they do not assert that every condition was
physically injected. The Python diagnostic did not execute Rust WP1's parser.
Production Rust parser/queue conformance and held-attachment behavior remain
separate WP2-B/C obligations; Core integration remains later qualification.

### H2.15-R1-008 — Cleanup

Both processes must terminate through documented bounded cleanup of their own
held descriptors, with no automatic reopen or restoration on a replacement.
Preserve individual restoration, exclusive-release, closure and exit outcomes.

An expected `EIO` releasing exclusivity on removed FD-A may be a warning when
the original descriptor closes successfully and no unsafe replacement
restoration occurs. Preserve A3.2's skip-restoration policy after replacement
or uncertain readability. A documented completed-with-warnings exit is not
automatically an invariant failure or an automatic qualification PASS.

Fresh FD-B must restore its terminal state, release exclusivity and close
successfully, absent a separately investigated anomaly. Other unexpected
cleanup errors stop the experiment for investigation; they cannot be relabeled
as expected without evidence and explicit review. Missing required cleanup
proof cannot qualify a cycle. Python watchdogs do not guarantee cancellation
of uninterruptible kernel operations or cleanup after `SIGKILL`.

Restore device-scoped temporary ACLs only when their original attachment/node
identities remain valid and no intervening replacement is known. Never apply
FD-A's old ACL backup to the replacement; verify and manage the new node
independently under separate physical-task authorization. No ACL operation is
authorized by this document.

### H2.15-R1-009 — Evidence integrity

Each qualifying cycle must preserve:

- Diagnostic version/source hash and validation provenance.
- Original terminal outputs, process IDs and shared absolute deadline.
- Actual environment and before/after device-identity snapshots.
- Retirement cause, identity/loss observations and permanent-retirement status.
- Fresh framing synchronization and exact-match outcome without barcode data.
- Four monotonic interval endpoints, original verifier output for new cycles,
  independent containment calculation and retired-FD probe outcomes.
- Both processes' cleanup/exit outcomes and applicable ACL disposition.
- SHA-256 hashes and byte counts of the retained original evidence.
- Operator and reviewer attestations identifying physical actions,
  same-host/same-boot provenance and their explicit evidentiary limits.

Keep human decisions, physical observations, synthetic results, attestations,
calculations, inferences and unavailable evidence distinct. Acknowledgement,
exit status, matching source hash or verifier output alone cannot qualify a
physical cycle. Use a separately reviewed prose execution/evidence record;
this criteria document is not that record.

Retain original bytes outside tracked source under the established
[private custody and recovery policy](evidence-index.md#evidence-custody-preservation-and-recovery).
Index artifact identities and hashes without barcode values, USB serial
descriptors, credentials or raw input buffers. Never reconstruct missing logs.
Existing same-VM copies are local duplication; an off-host archive still
requires separate authorization.

### H2.15-R1-010 — Failure accounting and stop rules

| Outcome | Required interpretation |
| --- | --- |
| **QUALIFYING CYCLE** | All mandatory cycle criteria and evidence are satisfied and reviewed; historical credit additionally requires the explicit exception below. This is not whole-campaign acceptance. |
| **INCOMPLETE / INCONCLUSIVE** | Operator timeout, coordination failure, missing required observation or unresolvable provenance prevents a valid result without demonstrating a confirmed safety defect. |
| **FAIL** | An applicable safety or continuity invariant is demonstrably violated. |

Preserve every attempt in chronological order, including incomplete and failed
ones. No automatic retry-to-green policy is permitted. A material identity,
stale-authority, unexpected-positive-read or unsafe-cleanup anomaly stops the
experiment/campaign for investigation. Do not continue to a later attempt
until explicit human review permits it. Positive forensic bytes may remain
inconclusive absent demonstrated unauthorized publication; retain that limit.
A later success cannot erase an earlier failure or make an incomplete attempt
qualify.

## Historical cycle credit — approved one-time exception

The project owner explicitly approved the previously completed **4433/4525
trial as qualifying cycle 1 of 3**, including the narrow historical evidence
exception below, at **2026-10-21 07:23:03 UTC**. This was a separate decision
from ratification. The trial was not conducted under previously accepted R1
criteria; the later approval does not reconstruct earlier authority.

| Historical fact | Retained reference |
| --- | --- |
| FD-A / FD-B process IDs | `4433` / `4525`; L3A / L3B in the evidence index |
| Shared monotonic deadline | `3185446161584`; L3A:3, L3B:69 |
| Original attachment | `/dev/ttyACM1`, USB address `8`; L3A:10 |
| Replacement attachment | `/dev/ttyACM0`, USB address `9`; L3A:30–31, L3B:77 |
| Initial retirement | `identity_evidence_lost_or_changed`, then identity code `unexpected_usb_interface_count`; L3A:15–16. HUP/ERR observations followed; this was not exclusively HUP-initiated retirement. |
| Retired-FD probe interval | `3001106686794` to `3011107111841`; L3A:71–72 |
| Fresh acquisition interval | `3005896380094` to `3009545968881`; L3B:92–94 |
| Containment / overlap | Whole fresh interval contained; `3649588787` ns overlap |
| Probe and fresh result | 50 zero-byte forensic reads with retirement retained; independently acquired one exact fresh record; L3A:72, L3B:94 |
| Cleanup | Original FD-A closed with expected release `EIO` warning, exit 3; fresh FD-B restored/released/closed, exit 0; L3A:82–85, L3B:95–99 |

The [independent timing audit](audit-report.md#independent-timing-audit) and
[precise original-event references](evidence-index.md#precise-event-references)
support those facts. The four endpoints establish
`3001106686794 <= 3005896380094 < 3009545968881 <= 3011107111841`.
The retained original terminal logs and independent mathematical recomputation
exist. The owner separately reported verifier **VERIFIED**, but its original
transcript was not retained.

The approved **historical exception is limited to the missing original
verifier transcript for the 4433/4525 trial**. With knowledge of that limitation,
the owner approved historical cycle credit using the retained log endpoints,
independent calculation and separately labeled verifier-result attestation.
The [ratification record](h2-15-r1-ratification.md#narrow-historical-exception)
records this one-time exception. It waives no other requirement, does not
recover the missing transcript and sets no automatic precedent for future
cycles. **Every new qualifying cycle must preserve its original verifier
output.** No replacement transcript is created.

The first coordinated attempt remains incomplete after its 180-second operator
handoff timeout; its original transcript is unavailable. The second attempt,
owner `4011` / fresh `4107`, retained useful replacement/synchronization evidence
but stopped on `unexpected_input_before_scanning_arm` and never completed
coordinated acquisition. **Neither may count as a qualifying cycle.** Keep
those attempts in the chronology without mixing them into the 4433/4525 trial.

## Remaining campaign — execution not authorized

R1 is ratified and historical cycle 1 is credited. **Two additional qualifying
cycles remain.** The prospective campaign plan proposes **at most three
additional physical attempts**, subject to separate human execution
authorization, to obtain those two cycles. The ratification declaration and
this documentation task authorize **no additional physical testing**.

Each attempt must be individually identified and documented. Operator-caused
incomplete attempts consume that allowance; starting another process or
checkpoint cannot renew an attempt or its deadline. A confirmed invariant
violation stops the campaign for investigation and cannot be overwritten by
later passes. The other anomaly stop rules above also apply. Expanding the
allowance requires a new human decision. If the remaining cycles are not
obtained within a separately authorized allowance, return the campaign plan
to human review; no extra attempt is implied.

Preserve existing A3.2 timing and acquisition safeguards without diagnostic
changes:

| Control | Existing bound to preserve |
| --- | --- |
| Owner coordination | One immutable 360-second deadline; fresh process inherits the owner's absolute deadline |
| Manual physical windows | Disconnect at most 30 seconds; reconnect at most 45 seconds |
| Comparison | At most 60 seconds, also bounded by remaining global work time |
| Retired-FD probe | 10-second budget and at most 50 forensic read attempts |
| Active work | Existing bounded read/retry/poll budgets and fresh-acquisition window; full fresh interval must fit the probe |
| Synchronization and cleanup | Existing 172-second synchronization ceiling and 8-second cleanup reserve, constrained by the shared deadline |

Acknowledgements do not reset deadlines. Unrelated phases retain their existing
180-second limit. Changing any diagnostic budget requires a separately reviewed
implementation task. Human coordination must fit these bounds; this document
does not extend them.

Record actual Linux allocation. No particular TTY name or character-number
reuse is required for a cycle. Existing retained pairs used different names
within each pair; same-name/major-minor reuse while that old FD remains held
was not physically demonstrated. Forced identity-reuse adversarial coverage
belongs to deterministic tests and must not be claimed from incidental name
reuse across different cycles.

## Relationship to existing dispositions and qualification layers

| Existing item | Disposition as of the recorded human decision |
| --- | --- |
| A3-01 | Formally accepted **PASS** for idle disconnect; no historical revision |
| H2.07 | **Partially substantiated** against the reference scan-before-disconnect procedure; separate evidence gap remains |
| H2.08 / H2.09 | Existing **proposed bounded PASS** findings remain proposed |
| A3-04 | Successful physical scenario supporting H2.08; no independent H2 gate or automatic acceptance |
| H2.13 | Formally accepted **PASS WITH EXPECTED CLEANUP WARNINGS** |
| H2.15 | **IN PROGRESS — NOT PASS** under ratified R1; 1 of 3 qualifying cycles credited, 2 remain |

R1 ratification and cycle credit do not automatically accept any adjacent gate,
close H2.07's separate precondition gap, accept WP2-A3 as a whole or rewrite
historical decisions.
Future H2.15 acceptance requires a separately reviewed execution/evidence
record covering the ratified criteria, all attempts and unresolved anomalies.

Three layers retain separate authority:

| Layer | What its evidence can establish |
| --- | --- |
| Diagnostic source validation | Exact Python A3.2 source, saved 91-test evidence and model protections; no automatic physical result |
| Physical H-VM qualification | Actual bounded attachment lifecycle, independent fresh scanning and coordinated comparison under ratified R1 criteria; campaign still in progress |
| Production Rust/Edge qualification | Eventual held-resource ownership, fresh binding epochs, parser/queue conformance, loss behavior, Core integration and appliance enforcement; requires its own source and physical qualification |

Even a complete H2.15-R1 H-VM campaign does not pass production adapter
qualification. The existing
[observation ownership contract](../../../architecture/edge-observations.md),
[binding lifecycle](../../../architecture/edge-agent.md#identity-selectors-and-binding-lifecycle),
[compiled factory contract](../../../../rust/edge/crates/edge-supervisor/src/binding.rs),
[prepared-runtime ownership](../../../../rust/edge/crates/edge-core/src/runtime.rs),
[adapter API](../../../../rust/edge/crates/edge-adapter-api/src/lib.rs),
[ADR-0033](../../../adr/0033-use-a-semantic-local-edge-protocol-for-pos-hardware.md)
and [threat model](../../../security/edge-agent-threat-model.md#hostile-input-replacement-and-spoofing)
remain unchanged. Physical attachment, framing alignment and Core authorization
remain distinct. Protocol 1.1, SQLite v12 and business authority are unchanged.
Frozen M8.2 evidence is historical evidence for its exact source only; it is
not modified or extended by these recorded decisions.

## Outstanding findings

No BLOCKER-level documentation defect is identified by this administrative
finalization. Preserve the
[existing audit findings](audit-report.md#findings-and-residual-obligations)
and distinguish their historical status from the later human decision:

| Finding | Historical status and current obligation |
| --- | --- |
| A3-Q01 — historically MAJOR | Prospective criteria-authority gap resolved by the owner's ratification at 2026-10-21 07:23:03 UTC. No earlier accepted criterion was recovered. The original finding remains historically accurate; overall H2.15 still needs two qualifying cycles and separate result review. |
| A3-Q02 — MINOR | Original A3-01, first coordinated-attempt and verifier transcripts remain unavailable; the approved narrow historical exception does not recover them. Missing verifier output is excepted only for the credited 4433/4525 trial. |
| A3-Q03 — MINOR | H2.07 scan-before-disconnect evidence remains incomplete |
| A3-Q04 — INFORMATIONAL | Physical/platform/identity-reuse coverage remains bounded; three cycles would not establish universal behavior |
| A3-Q05 — INFORMATIONAL | Production Rust attachment, Core integration, bare-metal/multiple-scanner and deployed enforcement qualification remain open |

## Recorded human decision

The authoritative declaration and reviewed/finalized criteria digests are in
the [separate ratification record](h2-15-r1-ratification.md).
Codex performs administrative finalization under the present documentation
task, without adding a human signature, decision timestamp or Git commit.

| Decision field | Recorded entry |
| --- | --- |
| Criteria revision and digest | **Ratified H2.15-R1**; final administrative-edition SHA-256 is recorded externally in the ratification record |
| Human authority | Grocery POS Platform project owner; declaration supplied in the development conversation |
| Decision timestamp | **2026-10-21 07:23:03 UTC**; effective date **2026-10-21 UTC** |
| Scope accepted | The bounded one-scanner H-VM qualification scope above |
| Historical cycle credit | **Approved: cycle 1 of 3**, processes **4433/4525**, including the one-time missing-verifier-transcript exception |
| Outstanding obligations | Two more qualifying cycles; separate execution authorization and later result review; residual findings above |
| Further physical testing authorized | **NO — unless separately approved** |
| Result | **Criteria RATIFIED; historical cycle credit APPROVED; H2.15 IN PROGRESS — NOT PASS** |

The final criteria file's digest is stored only in the separate ratification
record, avoiding a self-referential hash. Any later text change requires a new
digest and appropriate review. Ratification establishes qualification criteria;
the separate credit decision recognizes one historical cycle. Neither decision
means H2.15 has passed or authorizes another USB cycle.
