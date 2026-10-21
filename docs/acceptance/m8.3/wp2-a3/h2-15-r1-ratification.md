# M8.3.3 WP2-A3 — H2.15-R1 Formal Ratification and Historical Cycle Credit

**RATIFIED CRITERIA — HISTORICAL CYCLE CREDIT APPROVED — CAMPAIGN IN PROGRESS**

**H2.15: IN PROGRESS — NOT PASS. One of three qualifying cycles is credited;
two remain. Additional physical testing authorized by this decision: NO.**

This document records two explicit human decisions already made. It is not an
execution ledger, a new experiment, an overall H2.15 PASS or an authorization
to perform more physical work.

## Decision provenance and authority

Human authority: **Grocery POS Platform project owner**.
Decision timestamp: **2026-10-21 07:23:03 UTC**.
Effective decision date: **2026-10-21 UTC**.

The owner declared in the Grocery POS Platform development conversation:

> I hereby ratify H2.15-R1 and approve credit for the completed `4433/4525` trial.

The declaration, supplied as authoritative provenance in the present
documentation task, establishes two distinct decisions:

1. Formal ratification of **H2.15-R1** as the governing prospective criteria
   within the bounded H-VM scope below.
2. Formal approval of the completed **4433/4525** experiment as **qualifying
   cycle 1 of 3**, including the one-time missing-verifier-transcript exception.

Codex performs administrative finalization under the present documentation-only
task. No additional human signature, approval timestamp or Git commit is
invented. The eventual signed Git commit remains a separate owner action.

Original reviewed-proposal baseline: branch `feat/barcode-scanner-slice`,
commit `31b003b501a010a0c7f488a4ee6476e7f58e1edc`. That commit contains the
[conditional audit](audit-report.md), [evidence index](evidence-index.md) and
[qualification matrix](qualification-matrix.md). Those three documents remain
unchanged; their historical statements remain valid for their authorship time.

No earlier authoritative accepted local H2.15 repetition criterion was
recovered. R1 is a newly adopted prospective standard, not a reconstructed
historical contract. The owner made a separate, explicit historical-credit
decision; credit does not follow automatically from ratification.

## Criteria digests and normative preservation

Criteria revision: **H2.15-R1**.
Finalized standard: [ratified criteria](h2-15-qualification-criteria-r1.md).

**A. Original independently reviewed proposal SHA-256:**

```text
93e92c272387be7116e280786d17d55799b6cb16c0298d0ec98d65753e64f9e4
```

**B. Final ratified administrative-edition criteria SHA-256:**

```text
288c66beaf76c34ef00bf25bf4562cff1d42bfa02a56dc7622a0311b25444aad
```

Digest A was verified against the original local draft before editing.
Digest B identifies the complete finalized criteria file, not this record.
The two byte sequences differ in status/decision metadata and associated
administrative explanations. **All ten requirement bodies,
H2.15-R1-001 through H2.15-R1-010, remain byte-identical: 9,861 body bytes.**
Their individual headings also remain byte-identical. No normative-body change
was made or requires a substantive-change justification.

The three-cycle threshold, exact descriptor ownership, irreversible retirement,
fresh preparation/synchronization, full interval containment, nonmigration,
cleanup, evidence and stop rules are preserved. Existing diagnostic limits,
including the 360-second shared coordination deadline, 10-second/50-read probe
and 8-second cleanup reserve, remain unchanged. The criteria explain that
proposal-era wording retained inside the requirement bodies records their
origin; those requirements are now ratified.

To reproduce the digest check, compute SHA-256 over the finalized criteria's
complete original bytes without normalizing line endings and compare with B.
The criteria do not embed their own final digest; this record does not embed
its own digest. Any later criteria edit requires recalculation of B, update of
this reference and appropriate review. It cannot silently inherit approval
for changed substantive requirements.

## Ratified scope

The ratified standard governs:

- **One selected Zebra DS2208 `05e0:1701`**, USB CDC ACM using Linux `cdc_acm`.
- **Fedora Kinoite 44 ARM64**, in the documented VMware Fusion / Apple M1
  H-VM configuration; actual environment/kernel facts remain per-attempt evidence.
- The existing externally run **A3.2** diagnostic, subject to verified source
  identity and prior validation evidence. Its original SHA-256 is
  `cfa4ae38c162eec5a2f048ca2c95c8a0c60da6dfc5f409b6d6c425ccd17d3d7d`.
  The evidence index identifies source **D2**, saved **91-test** report **S2**
  and the provenance limits of those saved results.
- **Three individually qualifying coordinated disconnect/reconnect cycles**
  under the ratified criteria, with separate evidence for each cycle.

This establishes no authorization or qualification for other scanners,
multiple-scanner operation, other operating systems, bare-metal appliances,
production Rust integration, actual Core/Racket observations or deployed
device-access enforcement. It grants no device permissions or configuration
change, including within the laboratory. VID/PID, topology and filesystem
metadata remain operational corroboration, not cryptographic authentication.

## Approved historical cycle 1

The owner approved the completed trial as cycle 1 of 3 under R1, with the
narrow exception below. It was not performed under previously accepted R1
criteria. The evidence remains the retained original physical trial, not a
new run or a reconstructed transcript.

L3A and L3B identify the original files and hashes in the committed
[evidence index](evidence-index.md#storage-preservation-and-privacy).
The [precise event references](evidence-index.md#precise-event-references) and
[audit](audit-report.md#third-coordinated-attempt--completed-bounded-acquisitioncomparison)
provide their interpretation:

| Property | Approved historical evidence | Original reference |
| --- | --- | --- |
| Qualifying cycle | **1 of 3** | Owner's explicit credit decision above |
| Original owner process | `4433` | L3A |
| Independent fresh process | `4525` | L3B |
| Shared monotonic deadline | `3185446161584` | L3A:3; L3B:69 |
| Original attachment | `/dev/ttyACM1`, USB address `8` | L3A:10 |
| Replacement attachment | `/dev/ttyACM0`, USB address `9` | L3A:30–31; L3B:77 |
| Retired probe start | `3001106686794` | L3A:71–72 |
| Retired probe end | `3011107111841` | L3A:72 |
| Fresh acquisition start | `3005896380094` | L3B:92–94 |
| Fresh acquisition end | `3009545968881` | L3B:94 |
| Full containment overlap | `3649588787` ns | Original interval endpoints; independent arithmetic |
| Fresh acquisition | One exact matched record; payload omitted | L3B:93–94 |
| Original retirement | Permanent; no authorized barcode delivery | L3A:15,19,71–72 |
| Original cleanup | Restoration skipped after replacement/uncertainty; exclusive release `EIO`; close succeeded; exit 3 | L3A:82–85 |
| Fresh cleanup | Terminal restored; exclusivity released; close succeeded; exit 0 | L3B:95–99 |

FD-A first retired with **`identity_evidence_lost_or_changed`** and identity
code **`unexpected_usb_interface_count`** (L3A:15–16). HUP/ERR observations
followed. The credited chronology is not rewritten as exclusively
POLLHUP-initiated retirement.

The probe recorded 50 `ZERO_READ_NOT_REMOVAL_PROOF` results while FD-A remained
retired. FD-B independently opened, established its own terminal/framing state,
discarded the synchronization record, and matched the expected physical record.
The entire fresh interval is contained:

```text
3001106686794 <= 3005896380094 < 3009545968881 <= 3011107111841
```

Independent integer recomputation gives overlap **3,649,588,787 ns**, start
margin **4,789,693,300 ns** and end margin **1,561,142,960 ns**. The
[timing audit](audit-report.md#independent-timing-audit) distinguishes sampled
forensic observations from continuous monitoring, exact decode timing or
universal kernel behavior. Same-native-VM/same-boot provenance includes the
owner's attestation; timing arithmetic does not authenticate that premise.

## Narrow historical exception

The original **`verify-overlap` terminal transcript was not preserved**. The
retained original terminal logs contain the four interval endpoints, and
independent arithmetic confirms full containment. The owner separately reported
that the verifier returned **`VERIFIED`**.

With knowledge of that limitation, the owner explicitly approved credit for
the 4433/4525 trial, including the one-time exception. **The approved exception
applies only to the missing original verifier transcript for that trial.**
It waives no other requirement, reconstructs no missing evidence and creates
no automatic precedent. No replacement verifier transcript is created.
**Every new qualifying cycle must preserve its actual original verifier
output**, together with interval evidence and independent calculation under
H2.15-R1-006 and H2.15-R1-009.

## Qualification progress and execution authority

| Item | Recorded disposition |
| --- | --- |
| Ratified requirement | **3 qualifying cycles** |
| Formally credited | **1 qualifying cycle**, 4433/4525 |
| Remaining qualifying cycles | **2** |
| Overall H2.15 | **IN PROGRESS — NOT PASS** |
| Maximum proposed additional physical attempts | **3**, subject to separate human execution authorization |
| Additional physical testing authorized by this decision | **NO** |

Earlier incomplete attempts remain incomplete and receive **no cycle credit**:
the first coordinated attempt ended at its operator handoff timeout; the second
trial, 4011/4107, retained useful partial evidence but did not complete
coordinated acquisition. Their history remains in the committed audit.

Ratification and credit authorize no new USB cycle, diagnostic execution,
device-permission change or WP2-B/C/WP3 implementation. The remaining campaign
is a proposed execution boundary only. A future H2.15 PASS requires separately
authorized work and a separately reviewed execution/evidence record showing
satisfaction of every applicable ratified requirement, preserving all attempts,
stop-rule outcomes and unresolved anomalies. Three operator attempts cannot
be substituted for three qualifying cycles.

## Residual findings and qualification boundaries

The earlier three-file audit is preserved unchanged. Its findings are
interpreted with the later human decisions explicitly identified:

| Finding | Historical status and remaining obligation |
| --- | --- |
| A3-Q01 — historically MAJOR | The prospective criteria-authority gap is resolved by the owner's ratification on 2026-10-21 at 07:23:03 UTC. The earlier absence of an accepted local criterion remains an accurate provenance limitation; no historical standard was recovered. This resolves criteria authority, not the two remaining cycles or overall H2.15 qualification. |
| A3-Q02 — MINOR | Original A3-01, first coordinated-attempt and verifier transcripts remain unavailable. The narrowly approved verifier exception permits credit only for 4433/4525; it does not recover evidence or waive future preservation. |
| A3-Q03 — MINOR | H2.07's scan-before-disconnect precondition remains incompletely evidenced. Accepted A3-01 idle-disconnect behavior is unchanged. |
| A3-Q04 — INFORMATIONAL | Physical/platform scope remains bounded. Same-path and major/minor reuse within one original/replacement pair while its old descriptor remained held was not physically demonstrated. |
| A3-Q05 — INFORMATIONAL | The Python diagnostic is not the production Rust framing implementation. No production binding, Core event or Racket observation path was qualified. Deployed Linux security, bare-metal appliances and multiple scanners remain future qualification. |

H2.08 and H2.09 remain **proposed bounded PASS findings**; H2.13 remains the
previously accepted **PASS WITH EXPECTED CLEANUP WARNINGS**. A3-04 remains a
successful supporting physical scenario. No adjacent gate acquires formal
acceptance from H2.15 ratification or cycle credit, and H2.07's separate gap is
not closed. No new BLOCKER or unresolved MAJOR documentation defect is
identified by this administrative recording.

Original raw evidence remains outside Git under the established
[custody and recovery policy](evidence-index.md#evidence-custody-preservation-and-recovery).
The ignored repository archive and private home-directory copy share VM/storage
failure risks; neither establishes an off-host backup. No archive content or
original artifact is changed by this record. Frozen M8.2 acceptance evidence
is unchanged and remains historical evidence for its exact source only.
