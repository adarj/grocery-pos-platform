# M8.3.3 WP2-A3 — H2.15-R1 A01 Formal Decision B: Physical Execution Authorization

**DECISION B APPROVED — DECISION C PENDING — TIMED PHYSICAL EXECUTION NOT RELEASED**

Decision B is an actual human approval of bounded operations for **R1-A01
only**, targeting **R1-C2**, not another pending proposal. The human operator
may perform the permitted preparation below under the adopted plan's guards.
**Declaration of R1-A01 and timed physical execution require separate explicit
Decision C approval.** No readiness result, attempt start, experiment success
or qualifying-cycle credit is recorded here.

This particular Codex task records the existing authorization only. It does
not perform any permitted preparatory or physical operation.

## Human approval and incorporated declaration

Human authority: **Grocery POS Platform project owner**.
Human decision timestamp: **2026-10-22 20:09:23 UTC**.

The owner's direct approval sentence was:

> I formally approve Decision B using the declaration above.

This approval expressly incorporated the immediately preceding proposed
declaration titled **H2.15-R1 — Formal Decision B: R1-A01 Physical Execution
Authorization**. That longer declaration was proposed in the preceding
conversation and adopted by reference; it was not an independently typed
second owner message. Only the short sentence above is presented as the
owner's direct quotation. The operative scope below records the incorporated
declaration's meaning supplied in this documentation task.

The approval establishes R1-A01-only preparation, selected-device preflight
and temporary ACL authority, a physical experiment conditional on Decision C,
and post-attempt verification/preservation/cleanup. It authorizes no later
attempt, expanded diagnostic behavior or production qualification. Codex does
not independently grant, modify, expand or revoke that scope. This task's
preparation time is not another approval timestamp; no new signature or
independent human review is invented.

## Recorded Decision B

| Field | Recorded value |
| --- | --- |
| Decision identifier | **H2.15-R1 / R1-A01 / Decision B** |
| Human authority | Grocery POS Platform project owner |
| Decision timestamp | **2026-10-22 20:09:23 UTC** |
| Disposition | **APPROVED** |
| Attempt | **R1-A01 only** |
| Target cycle | **R1-C2**, not yet credited |
| Governing criteria | [Ratified H2.15-R1](h2-15-qualification-criteria-r1.md) |
| Governing execution plan | [Candidate revision 1](h2-15-r1-execution-plan.md), formally adopted through [Decision A](h2-15-r1-a01-decision-a-adoption.md) |
| Execution-plan commit | `16ea6253ac2d10ea2a27aacac870edaf5b0c6402` |
| Execution-plan SHA-256 | `c3d2c50e84a86c66f66bf80322a523657c37ea62ea201224f447c5b1c1ae451d` |
| Diagnostic | Exact approved A3.2 source; SHA-256 `cfa4ae38c162eec5a2f048ca2c95c8a0c60da6dfc5f409b6d6c425ccd17d3d7d` |
| Host | Established native Fedora Kinoite 44 ARM64 VMware Fusion / Apple M1 environment; actual kernel/environment recorded during readiness |
| Physical execution release | **CONDITIONAL — DECISION C REQUIRED** |
| Further attempts | **NOT AUTHORIZED** |

The operator is the human project owner. The scanner scope is one independently
selected physical Zebra DS2208 `05e0:1701`, USB CDC ACM using Linux `cdc_acm`.
Approval establishes bounded permission, not present readiness to launch.
The record is not an execution procedure or completed readiness report.

## Governing identities and documentation baseline

| Reference | Verified identity |
| --- | --- |
| Ratified criteria | SHA-256 `288c66beaf76c34ef00bf25bf4562cff1d42bfa02a56dc7622a0311b25444aad` |
| [Ratification record](h2-15-r1-ratification.md) | Commit `ea3ac49f467e5d246b1ba7dcbe6486119aee3903` |
| [Original A01 authorization candidate](h2-15-r1-a01-authorization-readiness.md) | Commit `125e4395087142ee0819691750d359168674f590`; SHA-256 `94a508ef760897956c5e13fad06316bd869e9a78b9786d8992b62fa2dbd460fc` |
| Decision A record | Commit `3b767d4bd62bc7e43dbe40d3ded82cf08131fb40`; SHA-256 `010a7299ebe2fc489f01aac2218c7f0eef4ffebab85dc96bc6392d3df6b44f29` |
| Saved synthetic report S2 | SHA-256 `4e7639d4f9a7bf3311f4eda81b395b50aae8bc60397dff3aba37796bb3dbd785`; 14,227 bytes, 91 saved passing tests |

Preparation baseline: branch `feat/barcode-scanner-slice`, HEAD
`3b767d4bd62bc7e43dbe40d3ded82cf08131fb40`, initially clean index/worktree.
The adopted plan's qualification baseline remains
`ea3ac49f467e5d246b1ba7dcbe6486119aee3903`; an arbitrary current HEAD cannot
replace it. Required current and pinned committed-file identities, plus the
available original diagnostic/report hashes, were verified before authoring.
No source version was substituted or executed. D2/S2 provenance and saved-run
limits remain those in the [evidence index](evidence-index.md#storage-preservation-and-privacy).

## Operations authorized under Decision B

These are recorded permission boundaries, not replacement launch instructions.
All actions must follow the adopted plan's identity checks, exact logging
wrappers, checkpoint sequence, bounds and stop rules. In particular, selecting
an endpoint never permits bypassing the source-defined one-scanner checks.

### Native readiness inspection

The human operator is authorized to inspect actual Fedora release, architecture
and kernel; required native tools; Git branch/HEAD/worktree; criteria and plan
identities; A3.2 source and saved-report identities; intended USB/interface/TTY
correlation; competing device users; available private storage; and terminal
and logger readiness.

The actual kernel is evidence to record, not a hardcoded historical version.
Source inspection and saved synthetic-report verification are not new physical
qualification. No automatic synthetic-suite rerun is included in these checks.

### Local evidence custody preparation

The human operator is authorized to prepare **one R1-A01 private attempt
directory** under the plan's prospective root:
`.local/qualification/m8-3/wp2-a3-r1/<approved-campaign-id>/R1-A01/`.
Use exclusive creation, trusted private parents, no symlink/path collision,
directory mode `0700`, file mode `0600` and `umask 077`.

Permitted preparation includes verified copies of the existing approved
diagnostic and report, original/fresh transcript destination preparation,
private evidence/manifest templates, and non-scanner util-linux `script`/PTY
readiness checks using private temporary files. Verify supported logger
commands, matching validated absolute Bash selection through `SHELL`,
interactive PTY behavior and output-only capture with disabled echo and
preserved child return codes, exactly as the adopted plan requires.

Preserve absent final transcript targets as required by the plan; logger
readiness artifacts are separate private temporary files, not fabricated
owner/fresh experiment logs. No historical archive or previous evidence may
be overwritten or modified. Templates must visibly remain unexecuted, and no
file may falsely suggest an experiment occurred. Custody preparation grants
no release to start the timed experiment.

### Selected-device preflight

The approved A3.2 `preflight --device` operation is authorized for independently
identified original A, and for independently identified replacement B **only
after the appropriate runtime checkpoint**, including
`FRESH_PREPARATION_PERMITTED`. Retain the exact one-scanner `05e0:1701` CDC
ACM profile and source-defined interface, driver, character and sysfs checks.

Preflight does not authorize arbitrary device opening or first-matching-node
selection. Neither a successful preflight exit nor a pathname establishes
attachment continuity or readiness release. No particular TTY name is assumed.

### Temporary device-scoped ACL handling

Human-controlled ACL preparation is authorized strictly under the
[adopted ACL procedure](h2-15-r1-execution-plan.md#device-scoped-acl-procedure--future-human-operations-only):

- Independently verify current A and, later, current B using full attachment
  and node evidence; retain separate full ACL backups and node keys.
- Require immediate pre-grant and post-grant identity checks. A node key alone
  is not sufficient physical proof; failed/ambiguous checks stop preparation.
- Human-supervised `sudo` is limited to approved selected-device ACL operations.
- Restore only when that exact original attachment/node identity remains valid
  and no intervening replacement is known, after its process has closed.
- Never apply A's stale backup to B. If A disappeared, record restoration not
  applicable to the removed node; manage B through its independent evidence.
- Refuse ambiguous restoration, retain the facts and obtain review rather
  than restoring by pathname or broadening access.

This permits no permanent group membership change, world access, broad
filesystem-permission change or root execution of the diagnostic.

### Conditional physical experiment

The following are conditionally authorized **only after Decision C is
explicitly approved** and all required gates permit them:

1. Declare R1-A01 under the adopted plan's attempt-declaration rule.
2. Launch the exact A3.2 `hold-reconnect` owner through the committed
   output-only logging procedure.
3. Perform one human-controlled disconnect/reconnect of the intended scanner
   at the prescribed physical checkpoints.
4. Independently launch the exact `fresh-attachment-check` mode with newly
   verified replacement facts and the owner's absolute deadline.
5. Perform the required synchronization presentation, discard that record at
   a genuine CRLF boundary, then present the expected acquisition record only
   when instructed and armed.
6. Perform the prescribed bounded forensic probe of permanently retired FD-A
   and the prescribed safe cleanup.

Retirement is irreversible. No old descriptor, parser, partial input or queued
record may gain replacement authority. The inert original remains forensic
only; it cannot reopen or return to normal acquisition. No second attempt,
rearm or automatic retry is authorized.

### Post-attempt verification, preservation and cleanup

For R1-A01 only, the human is authorized to run the existing pure
`verify-overlap` operation, perform independent monotonic-interval arithmetic,
hash/count original artifact bytes, preserve original transcripts, provide
operator attestations, maintain private evidence indexing, complete safe
permitted process/ACL cleanup and submit evidence for independent review.

Preserve both original terminal transcripts, correct process/phase attribution,
new attachment identities, shared deadline, retirement/synchronization/match
events, four interval endpoints, probe outcomes, cleanup/exit/ACL outcomes
and evidence hashes. Follow the plan's
[evidence bundle and custody requirements](h2-15-r1-execution-plan.md#per-attempt-evidence-bundle-and-blank-manifest-template).

The historical missing-verifier-transcript exception applies **only to R1-C1**.
R1-A01 must retain its actual original verifier output and independent timing
calculation. No reconstructed log, process exit, acknowledgement or verifier
result alone grants physical PASS or R1-C2 credit. Do not expose private
barcode values, expected fixtures, raw input buffers or USB serial descriptors.

## Limits and stop requirements

| Control | Preserved bound |
| --- | --- |
| Owner global deadline | One immutable 360-second deadline |
| Manual disconnect | At most 30 seconds |
| Manual reconnect | At most 45 seconds |
| Comparison | At most 60 seconds |
| Retired FD-A probe | 10 seconds; at most 50 read attempts |
| Fresh acquisition | Configured 10 seconds, entirely within the actual probe interval |
| Synchronization | Existing 172-second ceiling and existing source bounds |
| Cleanup | Existing guarded operations and 8-second reserve |
| Attempt allowance under Decision B | **R1-A01 only** |

The fresh process must inherit the owner's absolute deadline. All subordinate
limits remain clipped by the existing shared work deadline; none adds a new
allowance. Unrelated phases retain their existing 180-second bound. Acknowledgements
neither extend deadlines nor establish successful physical observations.

The ratified criteria and adopted plan's
[timing controls](h2-15-r1-execution-plan.md#timing-reconciliation-and-return-codes)
and [stop/escalation rules](h2-15-r1-execution-plan.md#stop-rules-and-disposition)
remain unchanged. Identity contradictions, stale authority, positive forensic
bytes and unsafe/unexplained cleanup stop the campaign for investigation.
Positive forensic bytes without demonstrated unauthorized delivery remain
inconclusive, not automatic proof of migration. No retry-to-green behavior,
deadline renewal or ignored stop condition is authorized.

## Explicit exclusions

Decision B does not authorize:

1. R1-A02, R1-A03 or a fourth attempt.
2. Physical execution before Decision C.
3. Changes to the diagnostic or saved validation report.
4. Scanner reprogramming.
5. Arbitrary DTR/RTS modifications.
6. Diagnostic execution as root.
7. Broad or permanent device-permission changes.
8. USB software resets or driver manipulation.
9. First-node selection or ambiguous attachment substitution.
10. Automatic reopening or restoration of retired FD-A authority.
11. Unapproved expansion of timing budgets.
12. Additional scanners or operating-system environments.
13. Production Rust/Core implementation or qualification.
14. Unapproved off-host evidence transfers.
15. Automatic physical qualification PASS or qualifying-cycle credit.

These prohibitions remain effective during otherwise authorized custody
preparation and selected-device preflight. Approval of one operation does not
waive the constraints on another.

## Decision C — Native Readiness Release: PENDING

The required sequence remains:

1. Decision A is already approved and recorded.
2. Decision B is approved by the owner's declaration identified above.
3. The human operator may perform permitted local custody preparation and
   native readiness checks within Decision B's exact scope.
4. All applicable prelaunch Class A and original-A Class B gates must be
   evaluated against original native evidence.
5. Any NO-GO prevents R1-A01 declaration and owner launch.
6. Only after actual readiness evidence is reviewed may the human owner
   separately grant Decision C.
7. Replacement-B identity/access checks remain mandatory at the later runtime
   checkpoint; initial readiness release cannot pre-certify the replacement.

The fourteen GO/NO-GO rows in the original candidate remain historically
**PENDING**. This record fills none of them and reports no newly completed
native gate. Repository/source inspection and saved synthetic reports are not
native readiness evidence. **The timed experiment is not released merely
because Decision B is approved.** R1-A01 has not been declared or started by
this task.

## Qualification accounting and chronology

| Item | Recorded disposition |
| --- | --- |
| Ratified criteria | **H2.15-R1** |
| Historical R1-C1, 4433/4525 | **Formally credited** |
| Decision A | **APPROVED** |
| Decision B | **APPROVED** |
| Decision C | **PENDING** |
| R1-A01 | Authorized conditionally, not released for timed execution |
| R1-C2 | **Not yet credited** |
| R1-C3 | **Not yet credited** |
| Overall H2.15 | **IN PROGRESS — NOT PASS** |
| Remaining qualifying cycles | **2** |

The campaign's proposed maximum of three additional attempts remains a
planning boundary, not blanket permission. This approval covers only R1-A01.
A readiness NO-GO before declaration is a readiness record, not a consumed
physical attempt. After declaration, incomplete preparation, cancellation or
timeout consumes the attempt slot. No stopped attempt may resume or relaunch
under the same identity. Every outcome needs review; no later attempt follows
automatically from unused allowance or a successful result.

The original candidate correctly recorded fifteen PENDING human-decision
fields when authored. The Decision A record correctly recorded B as pending
before the later approval. Both remain unchanged historical snapshots. This
new record establishes the subsequent authoritative B disposition without
rewriting either earlier document. Decision A remains APPROVED; Decision C
and its six readiness-release fields remain unresolved. No new cycle is earned.

The [historical audit](audit-report.md),
[qualification matrix](qualification-matrix.md) and later ratification retain
their chronology. H2.07 remains **partially substantiated**; H2.08/H2.09 remain
**proposed bounded PASS findings**. H2.13 retains its accepted **PASS WITH
EXPECTED CLEANUP WARNINGS**, and A3-01 its accepted idle-disconnect PASS.
No adjacent gate is accepted by Decision B. Python diagnostic evidence does
not qualify production Rust attachment, Racket/Core binding or observations,
bare-metal appliances, multiple scanners or deployed access-control policy.

## Documentation-only task boundary and verification

Decision B permits certain later human-controlled operations, but **this
particular Codex task is not authorized to perform them**. Only this Markdown
record is created. No diagnostic mode, synthetic suite, native readiness check,
device/TTY/USB access, prospective custody-directory creation, source/report
copying, PTY/logger runtime test, ACL operation, physical USB action or attempt
declaration is performed. No new physical or qualification result is claimed.

Verification consists of branch/HEAD/index/worktree and one-file-scope checks,
current and historical committed-file/source/report identities, exact owner
approval/timestamp comparison, scope/conditions/count/chronology consistency,
unchanged readiness rows and earlier records, local links/fragments, Markdown,
privacy and whitespace checks. The record's SHA-256 is reported separately.
No diagnostic or physical test is part of this validation.

All previously committed records, historical evidence, frozen M8.2 evidence,
diagnostic/report files and production source remain unchanged. No staging,
commit, push, merge, rebase, reset, tag, release or other Git history operation
is performed. Stop after documentation handoff; do not start native readiness
work, grant Decision C or proceed to the timed experiment.
