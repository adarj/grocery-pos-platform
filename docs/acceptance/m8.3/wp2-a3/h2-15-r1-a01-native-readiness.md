# M8.3.3 WP2-A3 — H2.15-R1 A01 Native Fedora Readiness Assessment

**CANDIDATE — NATIVE READINESS NOT VERIFIED; DECISION C PENDING**

**NATIVE READINESS NOT VERIFIED. No overall native prelaunch GO is issued.**
The command-execution boundary did not establish an ordinary native Fedora
terminal. Native qualification stopped before custody preparation, logger
testing, scanner inspection, diagnostic preflight or permission operations.
Only read-only repository/source inspection and this fallback report followed.

This is a partial assessment, not original native campaign evidence, a release,
an attempt declaration or an experiment result. R1-A01 has not started and no
attempt allowance was consumed. No private prospective evidence directory,
source/report copy, readiness transcript or artifact manifest was created.

## Execution-context boundary

The first command inspected only the execution boundary, using allowlisted
OS/kernel fields, process status/ancestry, namespace comparisons, presence-only
context markers and bounded virtualization detection. It did not inspect any
scanner or read a boot identifier, hardware serial or arbitrary environment.

| Boundary observation | Result | Evidentiary limit |
| --- | --- | --- |
| Visible userspace | Fedora Linux 44.20261021.1, Kinoite | Shared/mounted host userspace does not prove a native command channel |
| Visible architecture / running kernel | `aarch64`; `7.2.11-200.fc44.aarch64` | A sandbox can expose the host architecture and kernel; these are not accepted native campaign measurements |
| Effective user | Non-root | Ordinary-user execution alone is insufficient |
| PID 1 in the command's process namespace | `codex`, parent PID 0; command ancestry is Python → Bash → Codex | The qualification command is within an isolated runner namespace, not independently established as an ordinary host terminal |
| Process restrictions | `NoNewPrivs=1`, `Seccomp=2`, one seccomp filter | Corroborates restricted execution; these flags alone are not a complete container test |
| Namespace comparison | Command namespaces match the visible PID 1 namespaces | That PID 1 is Codex; this comparison does not reach an independently identified native system manager |
| Virtualization detection | VM check reports `vmware`; container check exits 0 with its label filtered by the inspection allowlist | VMware visibility is compatible with a sandbox inside the VM; the filtered label does not establish a specific container product |
| Filesystem/context corroboration | OSTree boot marker present; container marker files absent; selected remote/container environment markers absent | Marker absence and matching visible root objects cannot override the process-boundary evidence |

These are firsthand **Codex boundary observations**, retained in this session's
tool output and summarized here. They are not private original native artifacts;
no private transcript filename, digest or line reference is invented. They do
not prove the intended Fedora VM or scanner is defective. They show that this
qualification channel cannot independently satisfy the native-execution gate.

The owner's report that the session was launched outside Distrobox concerns
launch provenance. It does not remove the isolated command runner. No sandbox
escape, escalation, environment-check bypass, remote substitution or attempt to
convert these observations into native evidence was made.

## Static repository, authority and source inspection

These checks were performed through the shared repository/source view after
native work stopped. They are explicitly **not native Stage 1 qualification**.

- Branch: `feat/barcode-scanner-slice`; starting and ending HEAD:
  `5045709a7011e76101b3bd3805deb5d3a3e426ff`.
- Initial index/worktree: clean. The only preparation change is this Markdown
  report; all committed records remain byte-identical to HEAD.
- Qualification baseline remains `ea3ac49f467e5d246b1ba7dcbe6486119aee3903`.
  The current documentation HEAD does not replace it.

| Reference | Static verification |
| --- | --- |
| [Ratified criteria](h2-15-qualification-criteria-r1.md) | SHA-256 `288c66beaf76c34ef00bf25bf4562cff1d42bfa02a56dc7622a0311b25444aad` matched |
| [Adopted plan](h2-15-r1-execution-plan.md) | Commit `16ea6253ac2d10ea2a27aacac870edaf5b0c6402`; SHA-256 `c3d2c50e84a86c66f66bf80322a523657c37ea62ea201224f447c5b1c1ae451d` matched |
| [Decision A](h2-15-r1-a01-decision-a-adoption.md) | APPROVED; commit `3b767d4bd62bc7e43dbe40d3ded82cf08131fb40`; recorded file bytes matched |
| [Decision B](h2-15-r1-a01-decision-b-authorization.md) | APPROVED; commit `5045709a7011e76101b3bd3805deb5d3a3e426ff`; recorded file bytes matched |
| Decision C | PENDING; no release is inferred or recorded |
| Available original A3.2 | SHA-256 `cfa4ae38c162eec5a2f048ca2c95c8a0c60da6dfc5f409b6d6c425ccd17d3d7d` matched; no import or execution |
| Available saved report S2 | SHA-256 `4e7639d4f9a7bf3311f4eda81b395b50aae8bc60397dff3aba37796bb3dbd785`; size 14,227 bytes matched; the 91-test result is prior saved evidence, not a new run |

Five pinned commit/file comparisons covered criteria, ratification, plan and
Decisions A/B. The [original authorization candidate](h2-15-r1-a01-authorization-readiness.md)
and all other governing documents also matched their committed bytes. D2/S2
[provenance limits](evidence-index.md#storage-preservation-and-privacy) remain
unchanged. Static reading confirmed `preflight --device` is supported and
its selected CLI branch performs metadata/access checks without opening a
scanner; no diagnostic mode was executed to inspect it.

## Private evidence and device/access disposition

**Native custody location: not created. Private artifact manifest: unavailable.**
The prospective root remains
`.local/qualification/m8-3/wp2-a3-r1/<approved-campaign-id>/R1-A01/`.
This is a planned path, not an existing or verified directory. No campaign ID
or successful permission/capacity/copy check is fabricated. No substitute
artifacts were created in the Codex sandbox or `/tmp`.

No native Python/Bash/tool inventory, two-terminal interpreter comparison or
logger runtime result was collected. Tools used for boundary/static inspection
do not qualify the intended terminal interpreters or native tool options.
No native same-host/same-boot reference or operator attestation was collected.

Original attachment A was not inspected or selected. Its VID/PID, interface,
driver, TTY, character number, USB address, sysfs facts, competing users and
effective access remain unmeasured. No preflight output/exit artifact exists.
No ACL was read, backed up, granted or restored, and no restoration is needed
as a consequence of this task. Current native access cannot be inferred from
the earlier experiments. Replacement B remains a future runtime observation.

## Fourteen-gate assessment

Evidence cells explicitly report absence of private artifact paths/event/line
references. References to this report or committed documents are boundary or
static context, not substitutes for original native artifacts. **NO-GO** at
A-03 concerns the execution channel; **NOT VERIFIED** means no qualifying
native observation was collected; **PENDING** preserves a later authority or
runtime checkpoint. No row is marked GO.

| Gate ID | Native disposition | Actual observation | Evidence | Operator attestation | Remaining condition | Reviewer qualification |
| --- | --- | --- | --- | --- | --- | --- |
| A-01 | NOT VERIFIED | Static branch/HEAD and governing hashes match | No private native artifact; static inspection above | Native command context confirmation absent | Repeat baseline/identity checks in verified native terminals | Shared repository checks do not establish native execution |
| A-02 | NOT VERIFIED | Existing source/report hashes and size match statically; no copies made | No native copy/manifest artifact; source identities above | Prior saved-run provenance remains as indexed | Native original checks, authorized custody copies and independent verification | Saved 91-test results are not newly executed tests or USB evidence |
| A-03 | NO-GO | Visible PID 1 is Codex with restricted process ancestry; native terminal boundary not established | Boundary tool output summarized above; no private native artifact | Intended native VM/terminal confirmation still required | Establish a verifiable native command channel without bypassing sandbox controls | Current qualification channel fails; this does not prove host/scanner failure |
| A-04 | NOT VERIFIED | Native tool availability/options not inspected after the stop | None; no private tool report | Native operator check absent | Independently check every required command and option natively | No missing-tool or successful-tool result is inferred |
| A-05 | NOT VERIFIED | Plan's explicit Bash/SHELL setup read statically | None; no two-terminal native artifact | Matching path selection in both terminals absent | Validate absolute Bash paths and native shell selection in each terminal | Syntax or source inspection cannot qualify actual child execution |
| A-06 | NOT VERIFIED | No prospective directory, copies, permission or capacity measurements | None; planned path only | Native custody preparation confirmation absent | Exclusive private creation, modes, capacity and no-overwrite verification | Deliberate non-creation avoids false native evidence |
| A-07 | NOT VERIFIED | No native PTY/logger test or fixture/terminal preparation observed | None; no logger log or exit artifact | Two-terminal readiness/quiet procedure not attested | Native bounded non-scanner tests and terminal preparation | No Bash syntax check is presented as runtime qualification |
| B-01 | NOT VERIFIED | Scanner/USB profile not inspected | None; no native identity snapshot | Intended physical scanner not confirmed | One exact DS2208 CDC mapping under native inspection | No assumed TTY pathname or historical identity |
| B-02 | NOT VERIFIED | No selected-node preflight or competing-user inspection | None; no preflight log/exit or user review | Selected device/user review absent | Independent passive correlation, approved preflight and user review | No first-node selection or inferred preflight success |
| B-03 | NOT VERIFIED | Current A access/ACL not inspected or changed | None; no ACL/node-key artifacts | Direct human approval needed for any privileged operation | Assess existing access; only if necessary use approved guarded ACL preparation | No grant/restoration occurred; old ACL evidence cannot substitute |
| B-04 | PENDING | Replacement procedure exists; no new attachment B observed | Static plan/candidate only; no runtime artifact | Procedure review and later B confirmation remain | Reverify B and access only after FRESH_PREPARATION_PERMITTED | Future physical identity cannot be completed prelaunch |
| C-01 | PENDING | Decisions A/B approved; Decision C not granted | Committed decision records; no release artifact | Separate owner Decision C required | Actual prelaunch readiness review and explicit release | Pending authority differs from a failed hardware prerequisite |
| C-02 | PENDING | Supported launch/handoff interfaces read; no actual terminal exports or handoff | Static plan/source only; no runtime artifact | Native setup/rehearsal absent | Verify prelaunch preparation natively; retain future actual PIDs/deadline later | No invented process or shared deadline values |
| C-03 | NOT VERIFIED | Human preparation and scanner quiet state not observed | None; no native/operator artifact | Physical quiet state/checkpoint understanding required | Native operator preparation; runtime quiet/scanning remains later | No synchronization or acquisition scan was performed |

## Native operator handoff — instructions only

These conditional instructions are for the human's actual Fedora terminals,
outside this Codex runner. They were not executed here. Do not escape or
disable the sandbox to run them through the present channel. Decision B's
preparation permission remains valid, but the native boundary must be verified
before collecting campaign evidence. No instruction below releases timed work.

1. In **both intended native terminals**, inspect the execution context using
   allowlisted fields. Retain command outcomes and exit statuses, confirm the
   native system-manager context rather than a runner PID 1, and have the
   operator attest to the intended Fedora/Kinoite VMware/M1 guest. A matching
   OS string, VM detection or PID 1 name alone is insufficient. If the channel
   remains uncertain, stop without device access.

   ```bash
   cat /proc/1/comm
   systemd-detect-virt --container
   systemd-detect-virt --vm
   uname -m
   uname -r
   id -u
   ```

   Use selected Fedora release fields and a private same-boot reference as the
   adopted plan requires; do not dump the environment or publish a boot ID.
   Keep every later qualification command in those verified native contexts.

2. Recheck the branch, actual HEAD/status, pinned criteria/plan and exact source
   and report identities. The following uses the original locations already
   identified in the plan; a missing/different file is a stop, not permission
   to substitute or regenerate it.

   ```bash
   git branch --show-current
   git rev-parse HEAD
   git status --short --untracked-files=all
   sha256sum -- docs/acceptance/m8.3/wp2-a3/h2-15-qualification-criteria-r1.md docs/acceptance/m8.3/wp2-a3/h2-15-r1-execution-plan.md
   sha256sum -- "$HOME/Scripts/a3-2/ds2208_a3_2.py" "$HOME/Scripts/a3-2/synthetic-tests.txt"
   wc -c -- "$HOME/Scripts/a3-2/synthetic-tests.txt"
   ```

   Record any later documentation commit separately from the fixed qualification
   baseline; do not reset the repository or silently accept unexpected changes.
   This report is a known documentation addition, not an unexplained source edit.

3. Check each required tool independently and inspect native supported options:
   Bash, Python 3, `script`, `getfacl`, `setfacl`, `fuser`, `stat`, `sha256sum`,
   `git`, `uname`, `cat`, `id`, `wc`, and the approved private-directory/copy/
   capacity utilities. Missing or unsupported tools require review, not automatic
   installation. Apply the plan's exact Bash setup independently in both terminals:

   ```bash
   test "$(type -t bash)" = file || exit 1
   h215_bash="$(command -v bash)" || exit 1
   case "$h215_bash" in
     /*) ;;
     *) exit 1 ;;
   esac
   test -n "$h215_bash" && test -f "$h215_bash" && test -x "$h215_bash" || exit 1
   ```

   Compare actual selected paths. Verify native `script` supports the plan's
   options and `SHELL` interpretation; do not rely on inherited shell metadata.

4. Under Decision B, choose the prospective campaign ID and exclusively create
   the unique private R1-A01 directory through the
   [adopted custody procedure](h2-15-r1-execution-plan.md#persistent-logging-and-exact-launch-templates).
   Verify trusted ancestry, no conflicts/symlinks, 0700 directories, 0600 files,
   umask 077, and at least the 64-MiB campaign margin. Preserve original readiness
   transcripts, hash/count each artifact and verify copied D2/S2 against their
   originals. Keep owner/fresh experiment log targets absent. Mark all preparation
   artifacts as preparation; preserve historical archives unchanged.

5. Perform the separately permitted bounded **non-scanner** logger checks in
   both actual terminals using distinct private temporary outputs. Verify actual
   Bash selection, interactive PTY, disabled echo, output-only capture, child
   exit status, permissions and termination. Preserve the actual command/output/
   exit evidence. Do not substitute the physical owner/fresh commands for a
   harmless test or mark A-07 GO from installed help or `bash -n` alone.

6. Passively identify original A using the approved allowlisted USB/interface/
   TTY/character/sysfs correlation and competing-user review. Do not read serial
   descriptors or pick a TTY by name. After exact selection, set the plan's
   verified `h215_python`, `h215_diag`, `h215_original_node` and private
   `h215_attempt_dir`. The inspected preflight invocation is:

   ```bash
   if "$h215_python" -B "$h215_diag" preflight --device "$h215_original_node" \
     > "$h215_attempt_dir/preflight-A.log" 2>&1
   then h215_preflight_rc=0
   else h215_preflight_rc=$?
   fi
   printf '%s\n' "$h215_preflight_rc" > "$h215_attempt_dir/preflight-A.exit"
   ```

   Require new log targets, preserve original output, and compare it with passive
   discovery. This is the only scanner-specific diagnostic mode permitted by
   the readiness task. Its successful exit is not durable attachment proof,
   a grant of access or Decision C.

7. Assess existing effective access first. If it suffices, do not change ACLs.
   If a temporary grant is necessary, present actual A identity and the proposed
   operation to the human, save A's numeric ACL/node key privately, and obtain
   direct approval before each privileged operation. Follow the exact
   [identity-guarded ACL procedure](h2-15-r1-execution-plan.md#device-scoped-acl-procedure--future-human-operations-only).
   Codex must not invoke sudo autonomously. Verify identity/access immediately
   afterward. If not continuing toward separately approved Decision C in that
   same session, assess safe restoration; record any restoration and require
   renewed access checks before a later launch. Never restore on ambiguous or
   replaced identity, and never apply A's backup to B.

8. Preserve private paths, original byte counts/hashes, exact command/event/line
   references and operator attestations for independent review. Do not reconstruct
   evidence from this report. Leave runtime replacement/handoff/scan facts pending,
   submit actual prelaunch evidence and stop for explicit human Decision C.
   A readiness failure before declaration consumes no physical attempt. Do not
   declare R1-A01, launch owner/fresh modes, scan, unplug/replug or run a probe.

## Findings, remaining conditions and qualification boundary

| Severity | Finding / obligation |
| --- | --- |
| BLOCKER — native readiness | This Codex command channel is not independently verified as native; its isolated PID 1/restrictions prevent accepting readiness measurements from it. Resolve through independently verified native operator execution, without bypassing controls. |
| MAJOR | No new source or document identity mismatch was observed. Hardware/tool/logger/access readiness is unavailable, not passed. |
| MINOR — historical | Original transcript gaps and H2.07's scan-before-disconnect evidence gap remain unchanged. |
| INFORMATIONAL | Decision B permits bounded human preparation; this report supplies no Decision C, campaign artifacts or physical result. |

H2.15 remains **IN PROGRESS — NOT PASS**, with historical R1-C1 credited and
two qualifying cycles remaining. R1-C2/R1-C3 gain no credit. R1-A02/R1-A03
remain unauthorized. H2.08/H2.09 retain proposed bounded PASS findings; H2.13
retains accepted **PASS WITH EXPECTED CLEANUP WARNINGS**. No production Rust,
Core/Racket, bare-metal, multiple-scanner or deployed security qualification
is established. Prior raw evidence remains outside Git under its existing
[custody policy](evidence-index.md#evidence-custody-preservation-and-recovery).

## Documentation validation and stop boundary

Checks actually completed are boundary inspection, static repository/source
identity and pinned-commit comparisons, authority/status/14-gate consistency,
source-derived preflight vocabulary, local links/fragments, privacy, Markdown,
whitespace and final one-file inventory. Conditional shell blocks receive
syntax checking only; no qualification command template is executed. The new
report's SHA-256 is reported externally.

Native tool/PTY, custody/permissions/copies, device/preflight/ACL, boot provenance
and operator checks are **not performed**. No scanner diagnostic, synthetic
suite, timing verifier, USB operation, acquisition, automatic retry or physical
attempt occurred. No escalation or sandbox bypass was requested. No Decision C
or additional cycle credit is granted. Committed records, diagnostic/report
sources, historical/frozen evidence and Git history remain unchanged; nothing
is staged. Stop after this blocked report and native-operator handoff.
