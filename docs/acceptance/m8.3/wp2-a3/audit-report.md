# M8.3.3 WP2-A3 — physical evidence audit

**CANDIDATE — PENDING HUMAN ACCEPTANCE**

Prepared on 2026-10-21. Recommendation: **PASS WITH CONDITIONS —
documentation-only evidence checkpoint**, not formal acceptance of WP2-A3, WP2
or a Rust physical adapter.
Only the two previously supplied human decisions below retain accepted status.
The [evidence index](evidence-index.md) identifies available original files,
hashes, line references and missing material; the
[qualification matrix](qualification-matrix.md) separates gate recommendations
from accepted decisions.

## Baseline, scope and authority

Branch: `feat/barcode-scanner-slice`. Starting HEAD:
`31ab790c62a829fbf9b977d70d21b7c28d05e7b5`
(`feat(edge): add bounded DS2208 CDC framing engine`). The initial evidence audit
began with a clean index and worktree. Final documentation refinement began
with a clean index and exactly the three existing untracked candidate Markdown
files; no unexpected changes were present. The local upstream was
`origin/feat/barcode-scanner-slice`,
ahead 0 / behind 0; no remote fetch was performed. The preceding commits include
`4d8c23c` (observation binding/events) and `f387568` (configuration/discovery).

This is a documentation-only source-and-evidence review. No diagnostic,
physical experiment, acceptance runner or test suite was executed. Original
artifacts were read and copied byte-for-byte into ignored local storage.
Production code, diagnostic originals, tests, existing device/system permissions
and scanner settings were not changed. This document does not create a
machine-readable acceptance ledger or imply that the M8.2 runner qualified
WP2-A3.

The final refinement adds the
[A3 scenario-to-requirement crosswalk](qualification-matrix.md#scenario-to-requirement-crosswalk)
and [evidence custody/recovery record](evidence-index.md#evidence-custody-preservation-and-recovery).
All 16 primary artifacts and their originals were reverified, then 16 additional
copies were created and verified in the private home-directory archive. Existing
evidence contents were unchanged. Both copies remain on the same VM/storage;
no independent off-host backup is claimed. No qualification finding was
downgraded by this preservation work.

Flutter presents. Racket decides. SQLite remembers. Rust talks to edges.
The cloud coordinates. A diagnostic barcode match is neither a Core observation
nor a business mutation. SQLite remains v12; Protocol 1.1 is unchanged.

## Accepted decisions and evidence classes

The owner's task explicitly supplies these earlier formal decisions:

| Decision | Accepted disposition | Provenance available here |
| --- | --- | --- |
| WP2-A3 A3-01 | **PASS** | Owner's explicit statement; original terminal log and separate decision record unavailable |
| H2.13 | **PASS WITH EXPECTED CLEANUP WARNINGS** | Owner's explicit statement; preserved unchanged |

During this audit the owner clarified that an accepted charter/decision record
probably does not exist locally. No such record was found in the inspected
repository or supplied artifact directories. The conversation contains the WP2
charter v0.1 text with proposed status; it is a reference for gap analysis, not
a newly accepted local criteria document. This audit does not retract the two
explicit decisions or infer acceptance of the rest of that charter.

Evidence classes used throughout:

| Class | Meaning and limit |
| --- | --- |
| Human decision | Explicit acceptance supplied by the owner, without an independently located signed/local record |
| Retained H-VM observation | Diagnostic events in the preserved terminal logs; dependent on the diagnostic, operator actions and reported VM environment |
| Saved synthetic result | Existing reports of 52 / 74 / 91 passing tests; inventories and source hashes checked, tests not rerun |
| Operator attestation | Source inspection, native execution, physical actions and same-VM provenance reported by the owner |
| Independent calculation | Integer arithmetic recomputed from timestamps actually present in the retained successful logs |
| Analytical inference | A bounded conclusion drawn from those observations and source, not another physical measurement |
| Unavailable | Original A3-01 transcript, first coordinated-attempt transcript, verifier transcript, and authoritative local charter/acceptance record |

The logs report Fedora 44, `aarch64`, kernel
`7.2.11-200.fc44.aarch64`. VMware Fusion/Apple M1 and the physical DS2208 model
are owner-supplied environment facts. These are **H-VM**, not bare-metal
appliance evidence. A matching file hash identifies bytes; it does not
authenticate the operator, prove which bytes executed, or establish hardware
authenticity.

## Complete qualification history

### A3-01 — accepted initial disconnect

The owner reports a held CDC descriptor, deliberate removal, simultaneous
`POLLIN` / `POLLHUP` / `POLLERR`, irreversible retirement before any publication,
and disappearance of the original node/sysfs objects. Held `fstat()` remained
possible. One forensic read returned zero bytes. Termios restoration and
exclusive-release ioctl returned `EIO`; close succeeded and the diagnostic
exited 3 with cleanup warnings.

**A3-01 PASS** and **H2.13 PASS WITH EXPECTED CLEANUP WARNINGS** remain the
accepted decisions. The original output is unavailable here, so these detailed
observations remain owner-reported rather than newly log-verified.

### First coordinated attempt — incomplete operator coordination

The A3.1 180-second global watchdog expired at
`WAIT_FOR_TERMINAL_2_READY`. The replacement reportedly appeared as
`/dev/ttyACM1`. The original terminal output was not retained. This is an
incomplete coordination attempt, not a physical continuity failure or a
successful repetition. Unpreserved observations are not used as independent
physical evidence.

### Second coordinated attempt — useful partial evidence, acquisition incomplete

Preserved logs L2A/L2B identify owner PID **4011** and fresh PID **4107**, sharing
deadline `2215636742221`. The owner opened USB address 7 at `/dev/ttyACM0`,
retired it on terminal readiness loss, observed disappearance, and identified
replacement address 8 at `/dev/ttyACM1`. The fresh process independently opened
that replacement with new framing state and reached synchronization.

The fresh process then rejected input before its scanning arm:
`unexpected_input_before_scanning_arm` (L2B:103–109). Its descriptor was retired
and cleanup succeeded; exit 2. The owner later stopped at
`checkpoint_expired_incomplete`, closed FD-A, and exited 2 with an exclusive
release `EIO` (L2A:100–104). This demonstrates useful retirement, replacement
and fail-closed pre-arm behavior, but **no completed coordinated exact-match
acquisition**. Its probe is not substituted for the successful trial's probe.

### Third coordinated attempt — completed bounded acquisition/comparison

Only owner PID **4433** and fresh PID **4525** supply successful-run evidence.
Their shared absolute monotonic deadline is **3185446161584**
(L3A:3; L3B:69). PID 4011 and the preflight-only processes are excluded.

The original attachment was opened with unknown framing alignment and no
reopen. In this trial the **first** retirement reason was
`identity_evidence_lost_or_changed`, with identity-check code
`unexpected_usb_interface_count`, during removal (L3A:15–16). The subsequent
snapshot showed the old node, character index and USB/interface/TTY objects
missing (L3A:18). The forensic probe then observed
`POLLIN` / `POLLHUP` / `POLLERR` and a zero-byte read (L3A:19).
This is fail-closed handling of changing sysfs, not evidence that every
disconnect is first detected through a poll hangup.

After manual reconnection the original owner retained retired FD-A and
reported the replacement without reopening it. PID 4525 independently opened
FD-B, verified its own metadata, confirmed DTR/RTS high, and discarded a
synchronization record through CRLF before arming acquisition
(L3B:76–84). One subsequent record matched the privately supplied fixture
exactly (L3B:93–94); no payload is included here. The owner-completion event
explicitly remained `PENDING_HUMAN_EVIDENCE_REVIEW` (L3A:81). An acknowledgement
or exit status alone is not a physical qualification verdict.

## Successful attachment comparison

L3A:10/30–31 and L3B:77 independently record:

| Fact | Original A, PID 4433 | Replacement B, PID 4525 |
| --- | --- | --- |
| USB VID:PID | `05e0:1701` | `05e0:1701` |
| Driver / communications interface | `cdc_acm` / `00` | `cdc_acm` / `00` |
| USB bus / address | `1` / `8` | `1` / `9` |
| TTY node | `/dev/ttyACM1` | `/dev/ttyACM0` |
| Character major:minor | `166:1` | `166:0` |
| Node filesystem / inode | `7` / `861` | `7` / `877` |
| USB sysfs filesystem / inode | `[28, 48407]` | `[28, 48572]` |
| Interface sysfs filesystem / inode | `[28, 48459]` | `[28, 48624]` |
| TTY sysfs filesystem / inode | `[28, 48477]` | `[28, 48642]` |

The owner identifies topology `1-3.2`; the retained canonical USB/interface
paths agree and their path spellings were reused. Object metadata changed.
After reconnection, held FD-A still returned its **old** character/inode facts
while the current snapshot described B. Successful `fstat()` is not
connectivity. The diagnostic did not reopen or substitute FD-A; B had a separate
descriptor, terminal state and parser.

These facts show replacement corroboration under this kernel. They are not
cryptographic authentication or universally immutable identity. The two retained
cycles use `ttyACM0 → ttyACM1` and `ttyACM1 → ttyACM0`. Thus names and major/minor
values recur **across** cycles, but neither retained old/new pair demonstrates
the **same** pathname and major/minor being reused while its corresponding
old descriptor remains held. That race remains a separate qualification case.

## Independent timing audit

The four interval endpoints were read from L3A:71–72 and L3B:92–94, rather than
inferred from operator acknowledgements:

| Interval | Start, monotonic ns | End, monotonic ns | Duration, ns |
| --- | --- | --- | --- |
| Retired FD-A probe | `3001106686794` | `3011107111841` | `10000425047` |
| Fresh FD-B acquisition | `3005896380094` | `3009545968881` | `3649588787` |

Integer comparisons establish
`3001106686794 <= 3005896380094 < 3009545968881 <= 3011107111841`.
The whole fresh interval is contained, with start margin **4789693300 ns**,
end margin **1561142960 ns**, and overlap **3649588787 ns**
(3.649588787 seconds). Both intervals precede the shared deadline.

L3A:72 records 50 forensic read attempts, all
`ZERO_READ_NOT_REMOVAL_PROOF`, combined `POLLIN` / `POLLHUP` / `POLLERR`, and
continued retirement. L3B:94 records one completed exact match during that
window. This supports bounded nonmigration behavior while B was actually
transmitting successfully. A zero-byte result alone would not support it.

The owner separately reports `verify-overlap` returned `VERIFIED`, full
containment true, overlap `3649588787`, and no inferred physical PASS. Its
original output was not located. Independent arithmetic agrees with that
reported result, without reconstructing a verifier log or executing it.
The same-native-VM/same-boot premise is an operator attestation; matching
deadlines and reported environments corroborate it. Sampled forensic reads
are not continuous monitoring, and acquisition timestamps do not identify the
exact physical decode instant or certify universal Linux behavior.

## Cleanup audit

| Attachment | Retained result | Interpretation |
| --- | --- | --- |
| Successful run FD-A | Restoration skipped after replacement/uncertainty; exclusive release `EIO`; close completed; exit 3 (L3A:82–85) | Expected removed-attachment warning class; no restore on B and no reopen |
| Successful run FD-B | Original terminal restored, exclusivity released, close completed; exit 0 (L3B:95–99) | Independent fresh cleanup completed |
| Incomplete second attempt | FD-A release `EIO` but close completed; FD-B restore/release/close completed (L2A:101–104; L2B:105–109) | Cleanup still occurred on incomplete coordination |

No unexplained cleanup failure appears in the retained coordinated logs.
The observed removed-FD `EIO` is consistent with the previously accepted H2.13
warning, not a rule that every future cleanup failure is harmless. The original
A3-01 restoration-`EIO` report remains owner-attested. Source watchdogs and
closure paths do not prove cancellation of uninterruptible kernel calls or
cleanup after `SIGKILL`.

## Source-contract reconciliation and implementation handoff

These are existing contracts, not claims of a production CDC implementation.
References are repository paths at the baseline HEAD; line numbers are useful
review anchors, not new authority.

| Existing boundary | Verified source / invariant | WP2-B / WP2-C obligation |
| --- | --- | --- |
| Physical candidate | [discovery.rs](../../../../rust/edge/crates/edge-supervisor/src/discovery.rs), `DiscoveryCandidate` at 169; [linux.rs](../../../../rust/edge/crates/edge-supervisor/src/linux.rs), snapshot at 92 | Resolve exact canonical USB → interface → TTY → character identity; eligibility/path equality alone is insufficient |
| Held preparation | [binding.rs](../../../../rust/edge/crates/edge-supervisor/src/binding.rs), `RuntimeFactory` at 20–42; fresh revalidation at 199–245 | Keep one owned attachment; `check_attachment` verifies that handle without releasing/reopening; fresh global authorization remains required |
| Runtime ownership | [runtime.rs](../../../../rust/edge/crates/edge-core/src/runtime.rs), `PreparedRuntime` at 28–63, install at 73–106 | Failed preparation/revalidation drops ownership; no constructor grants Core binding authority |
| Observation lifetime | [adapter API](../../../../rust/edge/crates/edge-adapter-api/src/lib.rs), `ObservationSource` at 111–125 | Bounded synchronous poll/Drop, no autonomous surviving I/O, binding/continuity loss explicit; WP2 does not implement this bridge |
| Physical profile | [profile.rs](../../../../rust/edge/crates/edge-scanner-cdc/src/profile.rs), 1–24 | CDC `05e0:1701`; nonempty UTF-8 payload without CR/LF; 4,096 bytes, queue 16, bounded 4,098-byte feed/sync prefix |
| Alignment and loss | [framing.rs](../../../../rust/edge/crates/edge-scanner-cdc/src/framing.rs), `new` at 88–103, trusted constructor at 105–115, failure at 223–230 | Start unsynchronized; a genuine CRLF boundary, not open/idle/flush/activation, establishes alignment; discard old partial/queued records and never migrate them |

The diagnostic source corroborates one-open ownership, irreversible retirement,
hangup/error precedence, pre-delivery verification, discarded queues and separate
fresh framing. Its Python `Frames` is a diagnostic parser; physical success did
not execute the Rust WP1 parser. The existing
[observation contract](../../../architecture/edge-observations.md),
[agent architecture](../../../architecture/edge-agent.md),
[configuration/discovery contract](../../../architecture/edge-configuration-v1.md),
[Protocol 1.1](../../../architecture/edge-protocol-v1.md),
[ADR-0033](../../../adr/0033-use-a-semantic-local-edge-protocol-for-pos-hardware.md)
and [threat model](../../../security/edge-agent-threat-model.md) remain unchanged.

Later implementation must preserve descriptor-lifetime ownership, no automatic
reopen, permanent retirement, fresh preparation and fresh Core binding authority.
Prioritize known loss over queued records. Preserve the A2-qualified DTR-high
readiness requirement; this run only confirms DTR/RTS were high, not that it
retested their causal necessity. Keep acquisition, synchronization and Core
authorization distinct. The startup/arming policy and bounded Linux cleanup
still require implementation and qualification; no generic lifecycle change is
authorized by this audit. Subscriber overflow and physical input continuity
remain different failure domains.

## Findings and residual obligations

| ID / severity | Finding and disposition |
| --- | --- |
| A3-Q01 — MAJOR, qualification criteria gap | No authoritative accepted local WP2 charter/criteria record is available; owner cautions one may not exist. H2.15 is **NOT EVALUABLE AGAINST AUTHORITATIVE CRITERIA**. Human criteria confirmation is required before formal disposition; do not silently accept the proposed charter. |
| A3-Q02 — MINOR, historical provenance gap | Original A3-01, first coordinated attempt and verifier output unavailable. Preserve existing acceptance/attestations; recover originals if available, otherwise explicitly retain the provenance limitation. |
| A3-Q03 — MINOR, scenario coverage gap | Conversation-reference H2.07 includes scanning before removal; the inspected disconnect path explicitly requests an idle trial. No retained original-attachment scan establishes that precondition. Human review must distinguish the accepted idle A3-01 from full H2.07 coverage. |
| A3-Q04 — INFORMATIONAL, physical scope limit | Two retained removal/replacement cycles and one coordinated successful acquisition; not three successful coordinated repetitions. Same-name/rdev reuse within a retained old/new pair was not exercised. Add deterministic replacement tests and separately authorize any necessary physical follow-up. |
| A3-Q05 — INFORMATIONAL, implementation boundary | H-VM diagnostic evidence does not qualify a Rust held attachment, Core integration, production access policy, multiple scanners or bare-metal appliance behavior. |

No BLOCKER was identified in this documentation review. A3-Q01 prevents an
unconditional gate/whole-WP2 qualification claim; it is not evidence of a new
production runtime defect. Before formal review, confirm the applicable criteria,
then decide whether the retained varied cycles satisfy them. Do not equate
attempt count with successful repetition or require extra identical cycles
without an authoritative requirement. Any new physical experiment or later
implementation needs separate authorization.

## Documentation validation and historical evidence

Validation consists of baseline/index inspection, byte/hash checks for the
16 preserved artifact files and their originals, verification of the 16 new
private copies and access modes, static source/test-inventory review, PID-scoped
event/reference checks, integer timing recomputation, local Markdown-link and
fragment checks, cross-document disposition checks, privacy review and
`git diff --check`. The three untracked documents also receive explicit
whitespace and table-format checks, since ordinary Git diff does not include
them. Saved synthetic reports show 52, 74 and
91 passing tests; those counts overlap and are not summed as independent tests.
No new test execution, physical qualification or `just check` is claimed.
A broader code gate is unnecessary for three Markdown candidates with no code
changes; M8.2's acceptance campaign was not run.

Frozen M8.2 evidence was not modified or regenerated and remains historical
evidence for its exact source only. M8.3.1/M8.3.2 and WP1 are newer cumulative
source; these diagnostics do not replace later cumulative M8 qualification.
HEAD/history and the index remain unchanged. The documentation candidate is
unstaged; raw originals/copies remain outside tracked source. Human review is
the next step.
