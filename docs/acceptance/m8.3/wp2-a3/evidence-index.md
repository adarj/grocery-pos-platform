# WP2-A3 evidence index

**CANDIDATE — PENDING HUMAN ACCEPTANCE**

This prose index records inspected artifacts and provenance. It is not a
runner-produced acceptance ledger. See the [audit](audit-report.md) and
[gate matrix](qualification-matrix.md) for interpretations and dispositions.

## Storage, preservation and privacy

Audit date: 2026-10-21; repository HEAD:
`31ab790c62a829fbf9b977d70d21b7c28d05e7b5`.

Byte-identical copies of the following 16 files were preserved under
`.local/qualification/m8-3/wp2-a3/` with private file permissions. The existing
root `.gitignore` ignores `.local/`; no ignore-rule change was needed.
Original files were not edited or removed. Archive names below are relative to
that ignored directory. Hashes are SHA-256 of the complete original bytes,
also checked against the copies. No raw transcript is embedded in tracked
documentation. ACL files are historical artifacts only; none was applied.

Scripts and reports originated in `~/Scripts/`:

| ID | Original suffix | Archive suffix | Bytes | SHA-256 |
| --- | --- | --- | ---: | --- |
| D0 | `a3/ds2208_a3.py` | `a3/ds2208_a3.py` | 81362 | `797ceaf894769667d445bdc45c24217289e2d986500a12d10be15736e5c3b693` |
| S0 | `a3/synthetic-tests.txt` | `a3/synthetic-tests.txt` | 7975 | `a00cce493f7cb5235c459b4ede930ebdbc212f853a77b4c6559d61a6ec908548` |
| D1 | `a3-1/ds2208_a3_1.py` | `a3-1/ds2208_a3_1.py` | 119117 | `c46739a59cccfccbcda79a3637f44963850813f3c4a8d3f33044ccd6a8ffa276` |
| S1 | `a3-1/synthetic-tests.txt` | `a3-1/synthetic-tests.txt` | 11497 | `5455cf154d8d1eba5222ee60f272280953b9fafea05fa77471b9bbaf3962e23e` |
| D2 | `a3-2/ds2208_a3_2.py` | `a3-2/ds2208_a3_2.py` | 141372 | `cfa4ae38c162eec5a2f048ca2c95c8a0c60da6dfc5f409b6d6c425ccd17d3d7d` |
| S2 | `a3-2/synthetic-tests.txt` | `a3-2/synthetic-tests.txt` | 14227 | `4e7639d4f9a7bf3311f4eda81b395b50aae8bc60397dff3aba37796bb3dbd785` |

D1/D2 match the supplied expected hashes; D0's actual digest is recorded above.
The owner reports independent matching hashes, native synthetic runs and source
inspection.
S0 contains test lines 1–52, summary at 55 and `OK` at 57; S1 lines 1–74,
summary at 77 and `OK` at 79; S2 lines 1–91, summary at 94 and `OK` at 96.
AST inspection found exactly 52 / 74 / 91 `test_*` definitions matching the
respective report names. No tests were executed in this audit. Reports lack
embedded source hashes/native-environment provenance; the owner's attestation
connects them to the intended native runs. These are synthetic evidence, not
proof of USB behavior.

Coordinated-attempt originals:

| ID | Original file | Archive suffix | Bytes | SHA-256 |
| --- | --- | --- | ---: | --- |
| L2A | `/tmp/ds2208-a32.9F8mYW/terminal-1.log` | `attempt-2/terminal-1.log` | 34874 | `f4c56e8f2f83f1b97b709239e2852f999c32416c5ef7c3f54067c61cc61bad15` |
| L2B | `/tmp/ds2208-a32.9F8mYW/terminal-2.log` | `attempt-2/terminal-2.log` | 16264 | `2e933c2fe6cd43681505b693e1a43d12bb36420f286528a143638807ada503c5` |
| D2-R2 | `/tmp/ds2208-a32.9F8mYW/ds2208_a3_2.py` | `attempt-2/ds2208_a3_2.py` | 141372 | `cfa4ae38c162eec5a2f048ca2c95c8a0c60da6dfc5f409b6d6c425ccd17d3d7d` |
| ACL2A | `/tmp/ds2208-a32.9F8mYW/A.acl` | `attempt-2/A.acl` | 77 | `a37874a0e7d5cd833114f3cafd440ba23323d228bd7e75d92a5fbeeb97caba18` |
| ACL2B | `/tmp/ds2208-a32.9F8mYW/B.acl` | `attempt-2/B.acl` | 77 | `523bb5377cabb1a0ecdbc2d59d92f2973f90c182311132a62eae619874af3fd0` |
| L3A | `/tmp/ds2208-a32.HqXdH1/terminal-1.log` | `attempt-3/terminal-1.log` | 29017 | `f6f7595314ffba8248b48bb1debffa05ffd1df13e25de7df794ddeac0a1b9895` |
| L3B | `/tmp/ds2208-a32.HqXdH1/terminal-2.log` | `attempt-3/terminal-2.log` | 13863 | `5a7423ee20bb08fb326ad93f73ed4577f939e1a06a82cc3b89a06b5ad520255c` |
| D2-R3 | `/tmp/ds2208-a32.HqXdH1/ds2208_a3_2.py` | `attempt-3/ds2208_a3_2.py` | 141372 | `cfa4ae38c162eec5a2f048ca2c95c8a0c60da6dfc5f409b6d6c425ccd17d3d7d` |
| ACL3A | `/tmp/ds2208-a32.HqXdH1/A.acl` | `attempt-3/A.acl` | 77 | `523bb5377cabb1a0ecdbc2d59d92f2973f90c182311132a62eae619874af3fd0` |
| ACL3B | `/tmp/ds2208-a32.HqXdH1/B.acl` | `attempt-3/B.acl` | 77 | `a37874a0e7d5cd833114f3cafd440ba23323d228bd7e75d92a5fbeeb97caba18` |

Archive attempt labels are editorial names, not generated qualification results.
Each terminal file includes prompts/commands or preflight output. Event selection
uses decoded event fields plus process ID and phase, not a timestamp copied
from another trial. Both run-local D2 copies match D2; this corroborates source
availability without cryptographically proving process execution of those bytes.

## Evidence Custody, Preservation, and Recovery

The primary evidence remains in the Git-ignored repository directory
`.local/qualification/m8-3/wp2-a3/`. During final documentation refinement,
**all 16 primary files and all 16 available original source/report/log/ACL
files** were reverified against the byte counts and SHA-256 digests above.
They were regular files; primary copies were owner-owned with mode `0600`.
Originals and existing primary evidence were read only and were not modified,
replaced or reconstructed. ACL artifacts were not applied to devices.

An additional private local archive was successfully created and verified at
`$HOME/GroceryPOS-Qualification-Archive/m8-3/wp2-a3/`. It contains **16 verified
copies**, retaining exactly the table's relative archive suffixes. All eight
created directories have owner-only mode `0700`; files have owner-only mode
`0600` and belong to the invoking ordinary user. Copying used directory-relative
opens with no symlink traversal, exclusive creation, conflict checks and
post-copy byte/hash verification. No preexisting conflicting file was
overwritten. The primary ignored copy and original evidence remain intact.

Both evidence directories reside on the same Fedora VM/storage system. This
is additional local duplication, **not an independent off-host backup**.
VM deletion, virtual-disk loss/corruption, rollback to an older VM snapshot,
same-user compromise or accidental deletion can still remove both copies.
Original `/tmp` files are also temporary. No off-host archival copy, cloud sync,
external-storage transfer or independent retention policy is established here.
An off-host archival decision requires separate human authorization.

Ordinary Git clones do **not** contain these raw files. The eventual committed
evidence index records filenames, sizes, digests and event references, not an
embedded evidence bundle. A future reviewer must obtain an authorized copy of
the evidence separately and use the index from the exact reviewed documentation
commit. Preserve the recovered relative directory structure and original bytes;
do not normalize line endings, redact in place or regenerate missing logs.

Verification and recovery procedure:

1. Use a trusted owner-controlled recovery directory. Reject symlinked path
   components, symlinked/nonregular files, unexpected entries and unsafe access
   permissions. Do not execute recovered diagnostic scripts.
2. For each of the **16 artifact rows** above, compute SHA-256 over the complete
   recovered file and compare it with that row's digest. Compare its byte count
   with the recorded size. Account for every relative `Archive suffix` exactly
   once; do not substitute another attempt's similarly named log.
3. For an owner-inspected directory, the following read-only example checks
   L3A. Repeat for every suffix in both tables. These are recovery instructions;
   the audit's actual verification used Python `hashlib` and descriptor-based
   metadata checks.

   ```sh
   evidence_root="$HOME/GroceryPOS-Qualification-Archive/m8-3/wp2-a3"
   sha256sum -- "$evidence_root/attempt-3/terminal-1.log"
   stat --format='%s bytes; mode=%a; type=%F' -- "$evidence_root/attempt-3/terminal-1.log"
   ```

4. Require **16/16** matching hashes/sizes before relying on a recovered bundle.
   If a file is missing or differs, retain it unchanged, report the affected
   artifact ID and stop verification. Do not replace it with reconstructed
   output or silently accept a prefix of the evidence inventory.
5. Use the preserved line numbers, event names, process IDs and phase boundaries
   below to review a verified copy. A matching digest proves correspondence to
   the indexed bytes; it does not independently authenticate physical actions,
   process execution, human acceptance or the same-VM/same-boot premise.

Custody work resolves local duplication only. It does not recover U0/U1/U2,
establish authoritative H2.15 criteria (U3), supply a separate acceptance record
(U4), or change any finding's severity. The
[audit findings](audit-report.md#findings-and-residual-obligations) and
[scenario crosswalk](qualification-matrix.md#scenario-to-requirement-crosswalk)
retain those distinctions.

## Precise event references

Line numbers are 1-based original text lines; the preserved copies retain the
same bytes and numbering. Ranges describe review locations, not excerpts of raw
payloads. Paths, serial strings and barcode values are not reproduced here.

| File / PID | Lines | Relevant events / facts |
| --- | --- | --- |
| L2A / 4011 | 2–4, 9–10 | Environment, 360-second owner phase, DTR/RTS and original attachment |
| L2A / 4011 | 16–20 | Irreversible retirement, readiness loss, disappearance, retired forensic read |
| L2A / 4011 | 32–34 | Replacement comparison, new objects and retired-FD probe |
| L2A / 4011 | 88–89 | Earlier trial's probe, excluded from successful-run timing |
| L2A / 4011 | 100–104 | Incomplete checkpoint, skipped restoration, release `EIO`, close, exit 2 |
| L2B / 4107 | 77–88 | Independent fresh phase/open, original owner deadline, DTR/RTS high |
| L2B / 4107 | 93–95 | Synchronization boundary discarded and alignment established |
| L2B / 4107 | 103–109 | Pre-arm input failure, retirement, restoration/release/close, exit 2 |
| L3A / 4433 | 2–4, 9–10 | Environment, owner deadline, original attachment and DTR/RTS |
| L3A / 4433 | 15–19 | Identity-check retirement first, missing objects, HUP/ERR forensic result |
| L3A / 4433 | 30–32 | Old held metadata versus new object metadata and replacement candidate |
| L3A / 4433 | 37 | Fresh preparation permitted; handoff metadata/deadline |
| L3A / 4433 | 71–72 | Probe interval, 50 zero-byte results, combined flags, retirement retained |
| L3A / 4433 | 81–85 | Pending-review completion, cleanup warning, close and exit 3 |
| L3B / 4525 | 68–70 | Environment, independent fresh phase, same absolute deadline |
| L3B / 4525 | 75–78 | Fresh preflight/open, own held metadata and own framing state |
| L3B / 4525 | 82–85 | Discarded synchronization record, CRLF alignment, DTR/RTS high |
| L3B / 4525 | 92–94 | Acquisition interval and one exact-match completion |
| L3B / 4525 | 95–99 | Restoration, exclusivity release, close and exit 0 |

L2B includes separate preflight PIDs 4035 and 4081; L3B includes preflight PIDs
4456 and 4497. Their successful exits establish preflight completion only.
Neither they nor PID 4011 contribute to the 4433/4525 successful-acquisition
interval calculation.

## Diagnostic source anchors and synthetic protections

D2 is inspected source, not repository production code. Its relevant symbols:

| D2 lines / symbol | Contract reviewed |
| --- | --- |
| 64–184, `attr`, `ancestry`, `resolve_once` | Allowlisted bounded sysfs reads; no serial read; one CDC USB/TTY mapping; character index and USB/interface checks |
| 220–231, `raw_settings` | Noncanonical eight-bit profile, VMIN=1/VTIME=0; preserve modem policy |
| 430–490, `Frames` | Bounded diagnostic framing, unknown alignment and failure/queue handling |
| 493–565, `Held.open`, `verify` | One open attempt; restrictive flags, held `fstat`, termios, exclusivity, DTR/RTS read-only check; post-open verification |
| 567–618, `retire`, `read_once` | Irreversible retirement clears old parser/queue; retired reads forensic only; positive retired bytes inconclusive |
| 620–671, `Held.close` | Guarded restoration, no replacement open, bounded best-effort cleanup, exactly-once close path |
| 688–725, `drive` | Loss-mask precedence, at most four 256-byte reads, pre-delivery loss/identity recheck |
| 893–940, constants and `ExperimentClock` | 360-second shared coordination deadline, 8-second work reserve, 180-second unrelated phases |
| 1078–1169, coordinated probe/owner | 10-second / 50-attempt forensic probe, explicit human gates, owner cannot attest fresh success independently |
| 1172–1272, fresh synchronization/acquisition | Independent open/parser, discarded CRLF boundary, quiet pre-arm failure, exact match, private fixture disposal |
| 1275–1288, `verify_overlap` | Positive bounded integer intervals; full containment required; physical PASS not inferred |
| 1332–1401, `main` | No automatic physical PASS from exit status; cleanup on ordinary error/interruption |

The saved 91-test report includes direct protections for:

- HUP before delivery and partial/queued discard:
  `test_hangup_discards_completed_undelivered_records_before_delivery`,
  `test_disconnect_after_partial_record_discards_all`.
- Reused metadata and no migration:
  `test_same_path_rdev_sysfs_path_reused_with_new_objects`,
  `test_retired_normal_reads_forbidden_and_no_reopen`,
  `test_fresh_attachment_has_no_old_parser_or_queue_state`.
- Cleanup and privacy:
  `test_restoration_eio_does_not_prevent_release_or_close`,
  `test_cleanup_deadline_still_closes_original_descriptor`,
  `test_no_barcode_in_debug_or_authored_failure_output`.
- Timing and handoff:
  `test_360_second_scope_and_cleanup_reserve`,
  `test_fresh_inherits_long_owner_deadline_without_new_allowance`,
  `test_timing_verification_requires_contained_positive_interval`,
  `test_disjoint_and_partial_timing_overlap_are_inconclusive`.

This identifies what existing synthetic source/report evidence protects. It is
not a claim that those synthetic cases occurred on physical USB, or that the
diagnostic was rerun during this audit. Python signal deadlines cannot forcibly
cancel every kernel wait or guarantee cleanup after process kill.

## Unavailable evidence and attestation boundaries

| ID | Missing original | Treatment |
| --- | --- | --- |
| U0 | A3-01 disconnect/cleanup transcript | Preserve explicit human PASS / expected-warning decisions; do not manufacture filename, hash or line references |
| U1 | First A3.1 180-second coordinated-attempt transcript | Owner-reported incomplete attempt only; replacement observation unverified |
| U2 | Successful `verify-overlap` terminal output | Owner reports VERIFIED; recompute from actual L3A/L3B timestamps independently; no fabricated verifier log |
| U3 | Authoritative accepted local WP2 charter / criteria record | Proposed conversation text is available as context; owner indicates accepted record may not exist; H2.15 not evaluable against authoritative criteria |
| U4 | Separate local acceptance record for A3-01 / H2.13 | Owner's explicit acceptance in this task is the provenance; no ledger or signed record is invented |

Scoped searches covered relevant repository documents/ignored evidence names,
`~/Scripts`, `~/Documents`, `~/Downloads`, and accessible owned candidate text
files under `/tmp` through three subdirectory levels (up to 8 MB per file).
This is a description of search scope, not proof that no other copy exists.
Protected unrelated temporary directories were not accessed with elevated
privileges. Recover missing originals if they exist; otherwise retain these
limits when the human reviews proposed dispositions.

## Existing repository authorities

- [Root guidance](../../../../AGENTS.md): scope, privacy and authority.
- [ADR-0033](../../../adr/0033-use-a-semantic-local-edge-protocol-for-pos-hardware.md),
  [agent architecture](../../../architecture/edge-agent.md),
  [configuration](../../../architecture/edge-configuration-v1.md),
  [observation ownership](../../../architecture/edge-observations.md),
  [protocol](../../../architecture/edge-protocol-v1.md) and
  [threat model](../../../security/edge-agent-threat-model.md): current software contracts.
- [Frozen M8.2 README](../../m8.2/README.md) and
  [audit](../../m8.2/audit-report.md): historical evidence conventions; prose
  cannot turn missing execution into a passing result. Those files were read
  only, not modified or regenerated. WP2-A3 has no equivalent executed runner
  or machine-readable ledger, and none is created here.
