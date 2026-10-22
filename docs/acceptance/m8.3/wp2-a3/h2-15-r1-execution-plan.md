# M8.3.3 WP2-A3 — H2.15-R1 Physical Qualification Campaign Execution Plan

**CANDIDATE — PLANNING ONLY; PHYSICAL EXECUTION NOT AUTHORIZED**

Plan revision: **candidate 1**, prepared 2026-10-22 UTC. All commands and
physical actions below are instructions for a future separately authorized
native-Fedora run. None is authorized or reported executed by this document.
This is not an execution ledger, an approval form or a qualification PASS.

## Authority, baseline and scope

Qualification baseline: branch `feat/barcode-scanner-slice`, commit
`ea3ac49f467e5d246b1ba7dcbe6486119aee3903`. The
[ratification](h2-15-r1-ratification.md) establishes ratified R1 criteria and
historical **R1-C1**, processes **4433/4525**. H2.15 remains **IN PROGRESS — NOT
PASS**, with **two qualifying cycles remaining** and **no additional physical
testing authorized**.

The [ratified criteria](h2-15-qualification-criteria-r1.md) SHA-256 must be:

```text
288c66beaf76c34ef00bf25bf4562cff1d42bfa02a56dc7622a0311b25444aad
```

The inspected A3.2 source, initially `~/Scripts/a3-2/ds2208_a3_2.py`, must have:

```text
cfa4ae38c162eec5a2f048ca2c95c8a0c60da6dfc5f409b6d6c425ccd17d3d7d
```

Its saved report, `~/Scripts/a3-2/synthetic-tests.txt`, is 14,227 bytes,
SHA-256 `4e7639d4f9a7bf3311f4eda81b395b50aae8bc60397dff3aba37796bb3dbd785`.
It records 91 passing synthetic tests. Source/test-name inventory and report
identity were inspected without executing the diagnostic or its tests.
See D2/S2 and provenance limits in the [evidence index](evidence-index.md).

Scope is one selected DS2208 `05e0:1701`, Linux `cdc_acm`, Fedora Kinoite 44
ARM64, VMware Fusion on Apple M1. Record actual kernel/environment each time;
`7.2.11-200.fc44.aarch64` is historical evidence, not an assumed current value.
This campaign concerns a Python physical diagnostic. It does not exercise
Rust WP1 framing, a production adapter, Core binding/events, Racket delivery,
business commands or SQLite. Bare-metal, multiple-scanner and deployed
DAC/SELinux qualification remain excluded.

The committed [audit](audit-report.md), [index](evidence-index.md) and
[matrix](qualification-matrix.md) retain their historical statements. The later
ratification resolves prospective criteria authority; it does not close
H2.07's separate gap or formally accept H2.08/H2.09.

## Physical Execution Authorization — NOT YET GRANTED

This plan does not authorize unplug/replug, diagnostic execution, ACL/device
permission changes, diagnostic/source modification, additional attempts or
H2.15 PASS. Ratification and R1-C1 credit provide none of those permissions.

Before any execution, a separate human approval must identify the exact plan
revision and digest, qualification baseline, environment, diagnostic digest,
attempt allowance, permitted manual USB/ACL operations, output-only logging
procedure and stop conditions. No approval is prefilled here. Changes to the
diagnostic or ratified requirements require separate review, not improvisation
during a timed attempt.

## Campaign and identity accounting

| Identity | Meaning |
| --- | --- |
| R1-C1 | Already credited historical qualifying cycle; preserve its narrow verifier-transcript exception |
| R1-C2 | Next qualifying-cycle target; no prospective result yet |
| R1-C3 | Final qualifying-cycle target; no prospective result yet |
| R1-A01, R1-A02, R1-A03 | At most three proposed new attempt IDs, contingent on separate authorization; every begun attempt consumes an allowance slot |
| FD-A owner / FD-B owner | Actual Python `process_id` values from owner/fresh events, not logger PIDs or shell `$!` |
| Attachment A / B | Per-attempt verified held/current metadata; not the attempt ID, cycle ID, PID, TTY name or a Core binding ID |
| Result / human decision | Evidence-derived R1 outcome and separate named/date-stamped reviewer disposition; neither is inferred from an acknowledgement |

R1-A01 targets C2. The next authorized attempt targets the first still-uncredited
cycle: C2 after an incomplete attempt, C3 after reviewed C2 credit. Do not
prelabel A02 as successful C3. Record all attempted outcomes; never combine
different attempts' partial phases into one qualifying cycle.

A readiness NO-GO before declaring an attempt is a readiness record, not a
physical result. Declare the attempt before launching its owner; a failed
preparation, cancellation or timeout after that declaration consumes the slot.
Do not relaunch an owner under the same ID. Obtain human review of each outcome
before starting another attempt. Material anomalies invoke the stricter stop
rules below. Unused allowance is not present authorization, and a fourth
attempt requires a new human decision.

## Inspected interface and compatibility

Source references below are line anchors in the exact D2 source above, not
proof of new execution. Do not import the module or run `--help` to inspect it;
the CLI was read from `arguments()` at 1295–1329.

| Operation | Actual supported interface / behavior |
| --- | --- |
| Preflight | `python3 -B SCRIPT preflight --device NODE`; two agreeing bounded sysfs snapshots; no scanner open; access result advisory, missing access does not itself make this phase fail |
| Owner | `hold-reconnect --device NODE --disconnect-seconds 30 --reconnect-seconds 45 --compare-seconds 60` |
| Independent fresh | `fresh-attachment-check --device NODE --expect-instance BUS:ADDRESS --expect-node-inode INODE --expect-usb-object FS:INODE --owner-deadline-ns DEADLINE --expected-count 1 --seconds 10` |
| Verifier | `verify-overlap --probe-start-ns P0 --probe-end-ns P1 --fresh-start-ns F0 --fresh-end-ns F1`; pure timing path, no scanner open; returns 0 for full containment, 2 otherwise |
| Other existing phases | `self-test`, `hold-disconnect`, `cleanup-check` exist but are not campaign operations in this plan |
| Unsupported assumptions | No `--discover`, `--attempt-id`, `--cycle-id`, `--log`, arming IPC, automatic USB action or automatic ACL management exists |

`resolve_once`/`checked_snapshot` (112–184, 334–344) require exactly one
`05e0:1701` physical USB device, two interfaces, CDC data `0a/00/00`,
communications `02/02/01`, `cdc_acm`, and one correlated TTY. Ancestry uses
actual kernel objects; character number must agree across node, TTY `dev` and
`/sys/dev/char`. Serial reads are prohibited. There is no first-node fallback.

`Held.open` (493–550) permits one open attempt, uses
`O_RDWR|O_NONBLOCK|O_NOCTTY|O_CLOEXEC|O_NOFOLLOW`, verifies `fstat` and fresh
facts, saves/applies raw termios with VMIN=1/VTIME=0, claims exclusivity, and
requires both DTR and RTS high. It checks those signals without changing them.
`TIOCEXCL` does not exclude earlier or privileged opens. Failure is not permission
to use root, `stty`, modem toggles, another node or modified source.

The source supports the R1 choreography without a diagnostic modification.
Compatibility does not establish current hardware readiness. Native tools,
access, process ownership, logger behavior and physical identity remain GO gates.

## Pre-execution GO / NO-GO gate

Every item must be documented and accepted before declaring an attempt.
Do not acquire a scanner descriptor merely to test readiness before authorization.

| Gate | GO evidence | NO-GO condition / action |
| --- | --- | --- |
| Human authority | Separate execution approval naming this exact plan/digest and permitted operations | Missing/narrower approval: no execution or ACL/USB action |
| Repository baseline | Record branch, actual HEAD, status and pinned qualification commit `ea3ac49f467e5d246b1ba7dcbe6486119aee3903`; criteria bytes hash as above | Missing baseline, changed criteria or unexpected work: stop for review |
| Later documentation commits | Record approved plan commit/digest separately; review any difference from the qualification baseline | Do not substitute an arbitrary latest HEAD, reset the repository or silently bless source changes |
| Diagnostic / report | Original source and attempt-local copy match D2; report matches S2 and records 91 prior tests; owner/reviewer acknowledges saved-run provenance | Hash mismatch, missing report or unauthorized local edit: stop; do not substitute or rerun automatically |
| Native environment | Ordinary native Fedora 44/aarch64 terminal; Kinoite/VMware/M1 operator attestation; record actual kernel and private same-boot evidence | Root, container/sandbox, reboot or unreviewed environment change: NO-GO; do not clear detection variables to bypass checks |
| USB/TTY profile | Intended physical unit confirmed; fresh passive mapping plus diagnostic preflight meets exact profile and one endpoint | Absent/ambiguous/wrong profile or inconsistent ancestry: NO-GO; no first-match node selection |
| Device access | Current-node identity, existing ACL and proposed device-scoped change reviewed; native ACL tools present | Unknown identity, missing tools/permissions or unapproved sudo operation: review; no group/world access change |
| Other device users | Native `fuser -v` inspection and operator/service ownership review account for other opens | Unexpected/unexplained users or insufficient visibility: NO-GO; do not use kill flags or stop services implicitly |
| Bash / logging shell | Native Bash resolves to the same validated absolute executable pathname in both terminals; both wrappers explicitly select it through `SHELL`; native util-linux `script` supports the required options and documented interpreter selection | Missing Bash, alias/function or ambiguous resolution, differing paths, unsupported options/behavior or unverified native logger: NO-GO before physical execution |
| Two-terminal readiness | Both terminals prepared, fixture known privately, command/log paths ready, one operator rehearses acknowledgement order | Terminal setup or fixture lookup deferred into the timed handoff: postpone owner launch |
| Scanner quiet | Handheld controlled scanning; scanner aimed at a blank area, all barcode cards out of view except explicit scans | Uncontrolled presentation/stand retriggers: NO-GO; do not change programming to compensate |
| Evidence custody | Private unique campaign/attempt directories, output-only capture, absent target log files, writable storage; plan at least 64 MiB free for the three-attempt allowance | Reused paths, symlinks, public permissions, inadequate capacity or unverified capture: NO-GO; never overwrite/truncate earlier evidence |

Read-only baseline commands for a future approved preflight include:

```sh
git branch --show-current
git rev-parse HEAD
git status --short --untracked-files=all
git show ea3ac49f467e5d246b1ba7dcbe6486119aee3903:docs/acceptance/m8.3/wp2-a3/h2-15-qualification-criteria-r1.md | sha256sum
uname -m
uname -r
command -v python3 script getfacl setfacl fuser sha256sum stat
```

Check each required tool individually; a multi-name `command -v` result alone
must not hide a missing tool. Record only allowlisted OS fields, not arbitrary
environment/udev dumps. Preserve a private boot reference (for example the
read-only boot ID) plus operator attestation that both processes run in that
same VM and boot; do not publish that identifier in tracked summaries.

Use passive sysfs/TTY metadata to choose a candidate node, then explicit
`preflight --device NODE`; no node name is assumed. Listing TTY candidates is
not authorization to open them. Inspect only the intended USB device's
allowlisted identity/interface/driver relationships. Preflight must be freshly
repeated after re-enumeration; it does not prove continuing attachment ownership.

## Device-scoped ACL procedure — future human operations only

The prior native procedure is retained in L2B/L3B: `getfacl --absolute-names
--numeric`, `stat -c '%d:%i:%t:%T'`, a current-user `setfacl -m` entry, and
identity-checked `setfacl --restore` (L2B:22–54,110–128; L3B:22–54).
Those originals are indexed in the [evidence references](evidence-index.md#precise-event-references).
This is temporary selected-node access, not permanent `dialout` membership,
world permissions, production policy or permission for Codex to invoke sudo.

Apply the following sequence separately for A, then B after replacement and
`FRESH_PREPARATION_PERMITTED`. The human must already have separate approval
for the selected-node ACL operation. Use the current role's variables; never
reuse A's backup/key for B.

1. Verify current USB/interface/TTY facts through explicit preflight; ensure
   the node is a direct character device, not a symlink. Compare with the
   currently selected original or owner-reported replacement facts.
2. Save full numeric ACL and node key into new private files; recheck identity
   immediately before the grant. For a verified current role:

   ```sh
   getfacl --absolute-names --numeric -- "$h215_node" > "$h215_acl_before"
   stat -c '%d:%i:%t:%T' -- "$h215_node" > "$h215_node_key_file"
   ```

   Verify those saved facts against the selected role's preflight/owner facts.
   Only after that comparison, require the immediate node-key guard to succeed:

   ```sh
   test -c "$h215_node" && test ! -L "$h215_node" &&
     test "$(stat -c '%d:%i:%t:%T' -- "$h215_node")" = "$(cat "$h215_node_key_file")" &&
     sudo setfacl -m "u:$(id -u):rw" -- "$h215_node"
   getfacl --absolute-names --numeric -- "$h215_node" > "$h215_acl_granted"
   ```

   A failed guard/grant is NO-GO; do not continue by running the grant alone.
   The guard supplements, and does not replace, the full physical comparison.

3. Recheck the key, full USB/sysfs correlation and advisory effective R/W
   access. Compare against the saved pre-grant identity; any change stops
   preparation. Do not grant rights to a changed object by retrying the command.
4. After the process closes, restore only if that exact original role's node
   key **and** full physical-object evidence still match, with no known
   intervening replacement. Only then may the human use the same direct-node
   and saved-key guards above followed by
   `sudo setfacl --restore="$h215_acl_before"` and record the resulting ACL.
5. If A disappeared, its ACL was attached to that removed node. Mark A's
   restoration not applicable; never apply A's backup to a recreated pathname.
   Handle B with its independent backup. If identity is missing/ambiguous or
   replacement is known, do not restore by pathname: preserve the facts and
   request human review of remaining access cleanup.

All destinations above must be new, role-specific private files. A node key
alone is insufficient; these manual pre/post checks are not an atomic defense
against arbitrary replacement. Keep USB stable during permission work, stop on
uncertainty, and do not claim deployed security qualification. Native ACL-tool
availability must be rechecked: these tools were present in earlier native
evidence but are unavailable in the present Codex environment. No installation,
ACL grant or restoration was performed while preparing this plan.

## Persistent logging and exact launch templates

Prepare a private prospective campaign tree such as
`.local/qualification/m8-3/wp2-a3-r1/<approved-campaign-id>/`, separate from the
existing 16-artifact historical archive. Each attempt gets an exclusive unique
directory with its ID; directories `0700`, files `0600`, `umask 077`. Use
exclusive directory creation or `mktemp -d` within a trusted private parent.
Never follow an unexpected symlink, reuse an attempt directory or overwrite a
prior target. Verify free capacity before starting; the storage reserve above
is a planning margin, not a new diagnostic timeout/output allowance.

Before owner launch, retain attempt-local identical copies of D2 and S2, plus
approved criteria/plan identities and readiness facts. Hash copies again.
Do not modify or replace old archives. Prepare the following task-specific
variables in **both** terminals from the approved same attempt directory:

- `h215_attempt_dir`: absolute private attempt directory.
- `h215_python`: verified native Python interpreter path, exported in both
  terminals; use the same interpreter shown by the owner's generated handoff.
- `h215_bash`: validated native Bash executable path, independently resolved
  in both terminals as below; both paths must match before either launch.
- `h215_diag`: its verified `ds2208_a3_2.py`, exported for the child command.
- `h215_original_node`: independently verified current A node, exported in T1.
- T2 replacement variables are filled later from the decoded owner handoff:
  `h215_fresh_node`, `h215_instance`, `h215_node_inode`, `h215_usb_object`,
  `h215_owner_deadline_ns`. Export them in T2; do not substitute C1 values.

Use native interactive Bash and output-only util-linux `script` capture.
Before launching either process, run this preparation independently in both
terminals; any failed check is NO-GO:

```bash
test "$(type -t bash)" = file || exit 1
h215_bash="$(command -v bash)" || exit 1
case "$h215_bash" in
  /*) ;;
  *) exit 1 ;;
esac
test -n "$h215_bash" && test -f "$h215_bash" && test -x "$h215_bash" || exit 1
```

The file-type check rejects shell aliases/functions, and the remaining checks
require an absolute executable-file pathname. Compare the selected pathnames
between terminals; any mismatch is NO-GO. Both wrappers below supply that same
verified path as `SHELL`; an interactive Bash terminal alone does not establish
the inherited `SHELL` value.

The inspected util-linux 2.41.4 `script(1)` manual documents `--command` under
OPTIONS and `SHELL` under ENVIRONMENT: `SHELL` selects the shell forked by
`script`. Recheck this interpreter-selection behavior in the native Fedora
installation before GO.
The installed help supports `--quiet --flush --return --echo never
--log-out --command`; recheck support natively before GO. A canonical PTY must
reach the diagnostic. Do not pipe/redirect its interactive stdin. Do not use
input/combined logging, shell tracing, `--append` or `--force`. Output-only
capture plus disabled echo protects the hidden fixture. Unverified logger
behavior is NO-GO; this task did not exercise the wrapper or physical console.

The commands below are **future conditional templates**, not commands run by
this task. Preflight is separately captured and does not open a scanner:

```sh
"$h215_python" -B "$h215_diag" preflight --device "$h215_original_node" > "$h215_attempt_dir/preflight-A.log" 2>&1
```

Owner, T1; capture the actual return code even when it is the expected warning
code 3. Do not place these operations under an automatic retry wrapper:

```sh
export h215_python h215_diag h215_original_node
if SHELL="$h215_bash" script --quiet --flush --return --echo never \
  --log-out "$h215_attempt_dir/owner.log" \
  --command 'exec "$h215_python" -B "$h215_diag" hold-reconnect --device "$h215_original_node" --disconnect-seconds 30 --reconnect-seconds 45 --compare-seconds 60'
then h215_owner_rc=0
else h215_owner_rc=$?
fi
printf '%s\n' "$h215_owner_rc" > "$h215_attempt_dir/owner.exit"
```

When T1 emits `FRESH_PREPARATION_PERMITTED`, its `terminal_2_command` is the
actual `shlex.join` handoff (D2:1067–1075). Read the decoded JSON string; do
not paste JSON escapes, evaluate arbitrary output or copy a prior run's values.
The equivalent inspected invocation, T2, is:

```sh
export h215_python h215_diag h215_fresh_node h215_instance h215_node_inode h215_usb_object h215_owner_deadline_ns
if SHELL="$h215_bash" script --quiet --flush --return --echo never \
  --log-out "$h215_attempt_dir/fresh.log" \
  --command 'exec "$h215_python" -B "$h215_diag" fresh-attachment-check --device "$h215_fresh_node" --expect-instance "$h215_instance" --expect-node-inode "$h215_node_inode" --expect-usb-object "$h215_usb_object" --owner-deadline-ns "$h215_owner_deadline_ns" --expected-count 1 --seconds 10'
then h215_fresh_rc=0
else h215_fresh_rc=$?
fi
printf '%s\n' "$h215_fresh_rc" > "$h215_attempt_dir/fresh.exit"
```

All argv values must agree with the current owner event. The source supports
1–2 fixtures, but this R1 plan uses **one**. The expected value is typed manually
only at the hidden console prompt: no barcode in flags, environment, clipboard
transcripts, manifest or logs. Its diagnostic-console bound is 1–4094 UTF-8
bytes; that narrower fixture-entry bound is not a change to generic barcode
semantics. Remove the physical card from view immediately after every scan.

## Phase-by-phase operator choreography

The source consumes exact lowercase acknowledgement lines. Type one command
and Enter at the indicated prompt; never batch or prequeue acknowledgements.
`abort` and `fresh-failed` are supported at any `wait_ack` prompt; Ctrl+C is
the immediate cancellation mechanism during acquisition/probing. Do not
background/suspend a process or restart one to escape a deadline.

### Phase 0 — Readiness and evidence capture

- **Entry:** future execution authorization exists; attempt allowance available.
- **Action:** complete every GO gate, prepare both terminals/logging, privately
  choose one known fixture, perform passive mapping/preflight and A's reviewed
  ACL sequence. Capture readiness, source/report hashes, actual environment,
  boot provenance and access facts. Declare unique attempt ID/target cycle.
- **Expected:** one verified current A endpoint, effective access and ready
  terminals; no scanner FD opened by preflight.
- **Timeout:** preparatory work precedes the owner's clock. Each diagnostic
  preflight retains its 180-second watchdog and bounded sysfs checks. No
  repeated preparation/open loop is implied.
- **Abort:** any NO-GO; retain readiness evidence without launching the owner.
  **Next:** only a documented GO permits Phase 1.

### Phase 1 — Original attachment ownership

- **Entry:** attempt declared, A access valid, barcode cards out of view.
- **Action:** launch T1 owner template. At `ORIGINAL_PREPARATION`, type
  `prepare`. The exact original opens only after this acknowledgement.
- **Expected/evidence:** `HUMAN_GATED_PHASE`, `PHASE`, `ATTACHMENT_OPENED`,
  `held_fd`, original snapshot, raw settings, exclusivity, `modem_state` with
  DTR/RTS true and unknown frame alignment. Record Python PID A and the shared
  `experiment_deadline_ns`, not wrapper PID/time of terminal setup.
- **Timeout:** owner's one 360-second deadline has already begun; ordinary
  operation guards are at most 2 seconds. No new preparation allowance.
- **Abort:** wrong identity, failed open/exclusivity/readiness or unexpected
  behavior; cleanup and classify. **Next:** only `ORIGINAL_PREPARED` permits
  Phase 2.

### Phase 2 — Controlled removal

- **Entry:** verified FD-A held, `ORIGINAL_PREPARED` prompt, no scanning.
- **Action:** type `disconnect` in T1; **wait for
  `READY_FOR_MANUAL_DISCONNECT`**, then manually disconnect only the intended
  VMware scanner attachment. Do not reconnect yet.
- **Expected/evidence:** `ORIGINAL_PERMANENTLY_RETIRED`, first loss cause,
  `FIRST_LOSS_OBSERVED`, `POST_LOSS_EVIDENCE`, bounded `RETIRED_FD_PROBE`.
  HUP/ERR may lead, or changing sysfs may retire first. Zero reads alone are
  uncertainty, not proof of removal. Retained `fstat` does not restore authority.
- **Timeout:** at most 30 seconds, capped by remaining work time; source also
  bounds loss-loop iterations. Missing corroborated withdrawal is inconclusive.
- **Abort:** failure to retire, unauthorized delivery, positive retired bytes,
  premature replacement or unresolved contradiction. **Next:** at
  `ORIGINAL_PERMANENT_RETIREMENT_CONFIRMED`, inspect loss evidence and type
  `retired`; remain disconnected until Phase 3's explicit permission.

### Phase 3 — Controlled reconnection

- **Entry:** FD-A permanently retired and still held; no known new attachment.
- **Action:** at `MANUAL_RECONNECT_PERMISSION`, type `reconnect`; **wait for
  `READY_FOR_MANUAL_RECONNECT`**, then manually return the intended scanner
  to the same native guest. No software reset, detach or programming operation.
- **Expected/evidence:** replacement independently resolves; retain
  `ORIGINAL_VS_CURRENT`, `REPLACEMENT_CANDIDATE_OBSERVED`, actual B node,
  bus/address, sysfs objects and old held facts. The source performs another
  bounded forensic sample; FD-A never reopens. Different node names are valid.
- **Timeout:** at most 45 seconds capped by global work time. Early reconnect
  before permission is rejected by the source, not approved by a later ack.
- **Abort:** ambiguous/changed replacement, positive retired bytes or missing
  identity. **Next:** inspect `REPLACEMENT_OBSERVED`; type `prepare-fresh` only
  for the intended replacement. Wait for `FRESH_PREPARATION_PERMITTED` before
  any T2 fresh opening.

### Phase 4 — Independent fresh preparation and synchronization

- **Entry:** owner remains at `WAIT_FOR_TERMINAL_2_READY`, FD-A retired;
  `fresh_preparation_permitted=true`, current B facts and handoff available.
- **Action:** reverify B with explicit `preflight --device` into a new B log,
  perform B's independent identity-scoped ACL sequence, transcribe/review the
  handoff variables, and launch the T2 fresh template. Type the expected
  fixture only at its hidden prompt; this happens before B opens. At
  `INDEPENDENT_FRESH_PREPARATION`, type `open-fresh`.
- **Expected/evidence:** same absolute owner deadline in T2; independent PID B,
  `ATTACHMENT_OPENED`, `FRESH_INDEPENDENT_ATTACHMENT_READY`, DTR/RTS high and
  own unknown-alignment parser. At `FRESH_SYNCHRONIZATION_READY`, type
  `synchronize`; wait for `SCAN_ONE_SYNCHRONIZATION_RECORD`, then scan exactly
  one synchronization card and immediately remove it from view.
- **Evidence:** `DIAGNOSTIC_ALIGNED`, `FRESH_SYNCHRONIZED` with
  `no_fixture_delivered=true`, then `FRESH_READY_FOR_COORDINATED_SCAN`.
- **Timeout:** all preparation/hidden entry uses remaining shared time;
  hidden entry at most 60 seconds, synchronization at most 172 seconds capped
  by work end. Waiting for T2 does not start the 60-second comparison window.
- **Abort:** fresh failure, identity/readiness mismatch, synchronization loss,
  input during the quiet interval, or insufficient time. Type `fresh-failed`
  in T1 at its prompt if T2 fails; cancel the other process and retain both logs.
  **Next:** leave T2 waiting for `scan`. Only after that actual checkpoint is
  visible may T1 receive `fresh-ready`.

### Phase 5 — Coordinated acquisition and retired probe

- **Entry:** T2 synchronized and quiet at `FRESH_READY_FOR_COORDINATED_SCAN`;
  T1 receives `fresh-ready` at `WAIT_FOR_TERMINAL_2_READY`.
- **Action:** at T1's `RETIRED_PROBE_READY`, type `probe`. Wait for T1's
  **`RETIRED_PROBE_ARMED`**. Immediately switch to T2 and type `scan` at its
  waiting prompt. Wait for **`FRESH_SCANNING_WINDOW_ARMED`**, then scan the
  expected physical card once and remove it. Do not present it earlier or
  leave it in an Intellistand field of view.
- **Expected/evidence:** T1 records a bounded `RETIRED_PROBE_WINDOW_CLOSED`
  with interval endpoints, outcomes/flags and `original_still_retired=true`.
  T2 records `FRESH_RECORD_EXACT_MATCH` position 1 and
  `FRESH_EXACT_MATCH_COMPLETE` records 1 with both fresh endpoints. No old
  source data is framed/delivered. T1 is busy probing and cannot process a
  checkpoint acknowledgement until its probe finishes.
- **Timeout:** comparison starts immediately after T1's `fresh-ready` and is
  at most 60 seconds. Probe is 10 seconds/50 reads; source requires more than
  14 seconds of comparison/global work time before arming it. Fresh acquisition
  gets its configured 10 seconds **from T2's scan acknowledgement**, but must
  complete within the already running T1 probe. The operator must scan promptly;
  late success outside full containment is inconclusive, not credit.
- **Abort:** positive retired bytes, unexpected input, mismatched/extra record,
  lost identity/readiness, missing result or expiry. Do not rearm/retry within
  the attempt. **Next:** allow T2 cleanup; only actual fresh exact-match and
  successful cleanup support T1's `fresh-ok` at
  `WAIT_FOR_FRESH_EXACT_MATCH_RESULT`. Otherwise use `fresh-failed` or cancel.
  An acknowledgement is an operator attestation, not independent verification.

### Phase 6 — Cleanup and attempt termination

- **Entry:** fresh result or stop condition; keep hardware stable during cleanup.
- **Action:** let each process's `finally` path complete. After the good fresh
  result, type `fresh-ok` in T1, inspect both outputs, then `finish` at
  `EXPERIMENT_COMPLETION`. No return to acquisition is allowed. On cancellation,
  Ctrl+C each active foreground process once and wait for recorded cleanup.
- **Expected/evidence:** all per-operation `CLEANUP` events and
  `DIAGNOSTIC_EXIT`, plus logger/child exit status files. Original FD-A may skip
  restoration after replacement and report exclusive-release `EIO`, close
  successfully and exit 3. Fresh FD-B must restore/release/close and normally
  exit 0. Other errors require investigation. Exit 0/3 alone is never PASS.
- **Timeout:** existing 8-second work reserve; individual cleanup operations
  have 2-second watchdogs. `close()` disables the main alarm and uses its own
  operation guards; this is not permission to extend acquisition or a proof
  against uninterruptible kernel waits/SIGKILL.
- **Abort/escalation:** absent closure, unsafe restoration, unexplained cleanup
  or a stuck process stops the campaign; retain evidence and seek human review,
  not forced restart/reopen. After closure, perform only identity-valid ACL
  cleanup as described above; record removed-node/not-applicable cases.
  **Next:** Phase 7 only after both process outcomes are accounted for.

### Phase 7 — Timing verification, integrity and archival

- **Entry:** closed processes, attributable original logs, no scanner access needed.
- **Action:** select exactly one owner/fresh pair from this attempt and phase.
  Extract P0/P1 from `RETIRED_PROBE_WINDOW_CLOSED`, F0/F1 from
  `FRESH_EXACT_MATCH_COMPLETE`, checking shared deadline, PIDs and boot provenance.
  Set/export the four task-specific endpoint variables from those fields.
  Preserve the **actual new verifier output**, not a reconstructed chat excerpt:

  ```sh
  if "$h215_python" -B "$h215_diag" verify-overlap \
    --probe-start-ns "$h215_probe_start_ns" --probe-end-ns "$h215_probe_end_ns" \
    --fresh-start-ns "$h215_fresh_start_ns" --fresh-end-ns "$h215_fresh_end_ns" \
    > "$h215_attempt_dir/timing-verifier.log" 2>&1
  then h215_verifier_rc=0
  else h215_verifier_rc=$?
  fi
  printf '%s\n' "$h215_verifier_rc" > "$h215_attempt_dir/timing-verifier.exit"
  ```

- **Independent check:** a reviewer recomputes integer containment and overlap
  from the original endpoints, independently of the diagnostic function. A
  permissible pure arithmetic transcript (no source import/device access) is:

  ```sh
  python3 - "$h215_probe_start_ns" "$h215_probe_end_ns" "$h215_fresh_start_ns" "$h215_fresh_end_ns" \
    > "$h215_attempt_dir/independent-timing.log" <<'PY'
  import sys
  p0, p1, f0, f1 = map(int, sys.argv[1:])
  positive = all(1 <= n <= 2**63 - 1 for n in (p0, p1, f0, f1))
  contained = positive and p0 < p1 and f0 < f1 and p0 <= f0 and f1 <= p1
  print("entire_fresh_interval_within_probe=", contained)
  print("overlap_ns=", max(0, min(p1, f1) - max(p0, f0)))
  print("start_margin_ns=", f0 - p0)
  print("end_margin_ns=", p1 - f1)
  print("physical_qualification_pass_not_inferred=True")
  PY
  ```

- **Expected/evidence:** verifier `VERIFIED`, containment true, both positive
  intervals, attributable endpoints, independent calculation and reviewer
  attestation. If missing/partial/disjoint, do not count the attempt. C1's
  missing-verifier exception does not apply to any new cycle.
- **Timeout:** post-run review does not renew or extend either physical interval.
  Verifier takes its separate pure arithmetic path, with no native physical
  phase or new owner allowance. No new device read is justified by archival.
- **Archival:** preserve original bytes, private artifact manifest, byte counts
  (`wc -c`) and SHA-256 (`sha256sum`) for every file; compare any additional
  authorized local copy byte-for-byte/hash. Do not normalize ANSI/CRLF or strip
  earlier output in place; sanitized derivatives remain separately identified.
  Use the established [custody policy](evidence-index.md#evidence-custody-preservation-and-recovery).
  Copies on the same VM are not an off-host backup; no automatic transfer.
- **Next:** human outcome review before another allowed attempt. No command,
  exit status or timing calculation assigns a qualifying cycle automatically.

## Timing reconciliation and return codes

The following are source limits, not independent allowances to add together:

| Control | Actual implementation and planning consequence |
| --- | --- |
| Owner global | `main`/`ExperimentClock`: start + 360 seconds once; environment/setup time is included |
| Fresh global | `min(fresh_start + 360, inherited_owner_deadline)`; in this sequence it must equal T1's original absolute deadline |
| Work end | Global end minus 8 seconds; all waits/acquisition require positive remaining work time |
| Disconnect / reconnect | At most 30 / 45 seconds, capped at entry by remaining work time; operation/global guards still apply |
| Comparison | At most 60 seconds from T1's `fresh-ready`; includes probe-ready/result/completion waits; not the earlier T2 preparation wait |
| Probe | 10-second acquisition budget, at most 50 reads, roughly 200-ms ticks; preserve actual measured endpoints, do not round them to nominal limits |
| Synchronization | At most 172 seconds and 1,024 iterations, capped by work end; 4,098-byte synchronization discard bound |
| Fresh window | Handoff explicitly selects 10 seconds; CLI default is 20 and allows 1–30, but this plan does not use those larger values |
| Read/framing work | Up to four 256-byte reads per drive; queue 16; payload 4,096. `bounded_counts` retires when counters exceed 65,536 bytes or 2,048 read attempts at its checkpoints; a bounded drive can precede that check, so these are not exact receive cutoffs |
| Manual waits | At most 2,048 polls with up-to-200-ms input polling and 5-second checkpoint reports, always limited by the earlier work/local deadline |
| Unrelated phases | Existing 180-second startup/phase watchdog; do not apply it as an independent extension to coordinated processes |
| Cleanup | Main alarm disabled during guarded cleanup; per-operation watchdogs remain. No guarantee for uninterruptible kernel work |

All budgets remain subordinate to the shared deadline and actual source checks.
Timestamped closure may include scheduling/reporting overhead; reviewers retain
actual endpoints and investigate evidence of work after its allowed deadline.
Full containment is necessary but does not establish every syscall's duration.
The source also makes one separate bounded forensic read after initial loss
and one after replacement. Those `RETIRED_FD_PROBE` observations are distinct
from the coordinated 10-second/50-read window; do not mix their counts or
timestamps into its interval evidence.

| Return/outcome | Interpretation |
| --- | --- |
| Diagnostic 0 | Requested phase completed without recorded cleanup warning; still not qualification PASS |
| Diagnostic 3 | Phase completed with cleanup warning; only the ratified explained removed-A warning can support credit |
| Diagnostic 2 | Recorded incomplete/inconclusive stop, or verifier inconclusive; inspect categorical reason and evidence |
| Parser error, traceback, logger/signal/other status | Not an implicit R1 result; stop and review phase evidence and cleanup |

The diagnostic does not distinguish physical FAIL from every incomplete case
automatically: a reviewer must classify a confirmed invariant violation as FAIL
even if the script emitted `qualification_pass=false` with an incomplete flag.

## Per-attempt evidence bundle and blank manifest template

Keep these artifacts private, original and attributable:

- Approved execution authority/plan identity, qualification baseline, actual
  HEAD/status, criteria digest, D2 source copy/hash and S2 prior-report copy/hash.
- Readiness/environment/kernel/boot provenance, passive/preflight A/B facts,
  other-user review, independent role-specific node keys and ACL before/grant/
  cleanup evidence. Never run broad descriptor/udev dumps.
- Persistently captured `owner.log`, `fresh.log` and their exit files, including
  all identity, retirement, synchronization, probe, match and cleanup events.
- `timing-verifier.log`/exit, `independent-timing.log`, and the four original
  endpoints with exact file/line/PID references.
- Private operator and independent-reviewer attestations and final outcome;
  full artifact inventory with byte counts and SHA-256, including incomplete
  evidence and any separately identified sanitized derivatives.

Logger/preflight/helper PIDs do not become the owner or fresh PID. Match
`process_id`, `PHASE`, shared deadline and event order within the correct
attempt. Preserve complete originals even if a transcript includes multiple
preflight processes. Do not import earlier 4011/4107 or historical 4433/4525
timestamps into a new result. Never recreate missing originals from chat.

The following is a **blank private prose manifest template**, not a new tracked
ledger, completed record or permission to create evidence during this task:

```text
Attempt: R1-A__                  Target cycle: R1-C__ (not yet credited)
Execution authority reference: <pending>
Approved plan revision/digest: <pending>
Qualification baseline: ea3ac49f467e5d246b1ba7dcbe6486119aee3903
Actual HEAD / branch / status: <pending>
Criteria / diagnostic / saved-report digests: <verified values and references>
Environment / kernel / private boot-reference artifact: <pending>
FD-A PID / FD-B PID / shared deadline: <pending>
Attachment A snapshot / B snapshot references: <paths, lines; no payload>
Probe P0/P1 / fresh F0/F1: <pending; original event references>
Verifier / independent calculation references: <pending>
Cleanup / exit / ACL disposition references: <pending>
R1 outcome: <QUALIFYING CYCLE / INCOMPLETE-INCONCLUSIVE / FAIL; unreviewed>
Operator attestation / limits / date: <pending>
Reviewer identity / decision / limits / date: <pending>
Artifact rows: <relative path> | <bytes> | <SHA-256> | <purpose/event lines>
Anomalies / stop decisions / next-attempt authorization: <pending>
```

List actual artifact paths; do not embed scanned/expected values, raw buffers,
serial descriptors or private host identifiers in tracked reports. Do not
include a manifest's own digest inside itself; record it externally if needed.
Raw evidence is absent from ordinary Git clones; recovery requires an
authorized bundle and comparison against its reviewed index/manifest.

## Independent requirement-to-evidence matrix

PASS below means the row's required evidence is satisfied, not automatic
acceptance of an attempt or the campaign. R1 outcome definitions govern; fewer
than three qualifying cycles is IN PROGRESS, not by itself a physical defect.

| R1 criterion | Required observation / evidence source | PASS criterion | FAIL criterion | INCOMPLETE / INCONCLUSIVE treatment | Reviewer responsibility |
| --- | --- | --- | --- | --- | --- |
| H2.15-R1-001 | C1 ratification plus two separate prospective complete bundles; all attempt chronology | Three individually qualifying cycles, no reused phase/credit | Demonstrated fabricated/reused credit or erased failure represented as qualification | Fewer than three valid cycles, exhausted allowance or missing chronology: no campaign PASS | Reconcile attempts, accepted credit and authorized allowance independently |
| H2.15-R1-002 | Owner `ATTACHMENT_OPENED`, original/held metadata and no-reopen source model | One verified independently opened A retained through replacement | Confirmed reopen, substitution or transparent retargeting | Missing opening/ownership proof or refused preparation: no cycle credit | Match owner PID, source identity and A lifetime; no name-only proof |
| H2.15-R1-003 | Retirement cause, loss/identity events, probe and source/test protections | Irreversible retirement, loss priority, no authorized old delivery | Confirmed normal delivery/authority revival after retirement | Unclear withdrawal or positive forensic bytes without proven unauthorized delivery: stop/review | Distinguish a retained inert FD from authority and from kernel migration |
| H2.15-R1-004 | B preflight, owner/current comparison, B held facts, sysfs/character correlation | Independent exact expected B corroboration, one endpoint | Wrong attachment accepted as intended or known contradictory evidence bypassed | Ambiguity, loss or evidence disagreement rejected safely: no credit | Verify actual paths/numbers/objects; never demand reuse or treat it as attestation |
| H2.15-R1-005 | Independent fresh open, DTR/RTS, synchronization/quiet sequence, model tests | Own terminal/parser, real discarded CRLF boundary, no inherited state | Confirmed stale-state import or unaligned input accepted as the expected record | Missing sync/readiness or unexpected pre-arm input safely rejected: incomplete | Check source and physical events separately; reject guessed alignment |
| H2.15-R1-006 | Both original logs, exact-match count, P0/P1/F0/F1, new verifier output, arithmetic | One fresh exact match fully contained; A retired; bounded probe | Confirmed unauthorized old delivery, budget bypass or false containment asserted despite evidence | Missing/late/partial overlap, mismatch, unverified same boot or absent verifier transcript: no credit | Recompute from correct PIDs/events; operator ack and verifier status alone insufficient |
| H2.15-R1-007 | Exact D2/S2 source-model evidence: partial discard, queued discard, independent parser, no revival/reopen tests | Applicable existing software protections verified and labeled synthetic | Demonstrated source behavior violates the required protection | Missing/mismatched model evidence: pause; do not claim physical injection | Confirm prior-report provenance; reserve Rust behavior for WP2-B/C |
| H2.15-R1-008 | Per-operation cleanup, closure/exit, independent ACL identities/dispositions | Both close, B clean restoration/release, only explained removed-A warning | Confirmed unsafe replacement restore, continued unauthorized ownership/I/O or other proven cleanup invariant violation | Unexpected errors/missing closure without proof of safe outcome: stop/investigate | Explain each warning; no blanket EIO waiver or unsafe old-ACL restoration |
| H2.15-R1-009 | Original source/log/report artifacts, hashes, new verifier and attestations | Complete attributable private evidence and integrity/custody review | Demonstrated evidence fabrication or substitution represented as genuine | Missing original logs, source mismatch, unresolvable provenance: no credit | Verify digests/counts/lineage without exposing contents; C1 exception is one-time |
| H2.15-R1-010 | Every attempt, outcome, approval and stop/restart decision | Correct accounting, bounded allowance, explicit review, no automatic retries | Confirmed ignored stop, unauthorized extra attempt or erased failure | Ambiguous chronology or unresolved anomaly prevents acceptance | Preserve distinctions among source model, physical result and human decision |

Existing supporting regression names include
`test_disconnect_after_partial_record_discards_all`,
`test_hangup_discards_completed_undelivered_records_before_delivery`,
`test_fresh_attachment_has_no_old_parser_or_queue_state`,
`test_same_path_rdev_sysfs_path_reused_with_new_objects`,
`test_retired_normal_reads_forbidden_and_no_reopen`,
`test_360_second_scope_and_cleanup_reserve`, and
`test_timing_verification_requires_contained_positive_interval`.
They are saved synthetic evidence, not fresh test executions or physical
injection of those races. Future Rust held-resource, parser/queue and Core
qualification remains separate.

## Stop rules and disposition

At an acknowledgement prompt use `abort` or `fresh-failed`; during a live probe
or acquisition cancel with Ctrl+C. Account for both processes and cleanup.
Do not reconnect again, reopen, restart, alter signals or reprogram the scanner
to obtain a pass. A stopped attempt never resumes under its old identity.

| Condition | Immediate action / R1 treatment |
| --- | --- |
| Source/environment mismatch before attempt | NO-GO. If discovered after start, stop and mark evidence inconclusive pending review; no substitution |
| Unexpected identity change, inconsistent held/sysfs facts | Stop. Expected loss during instructed removal may retire safely; unexplained contradiction requires investigation. Proven wrong-attachment authority is FAIL |
| FD-A fails to retire or delivers normal authorized input after retirement | Stop campaign; demonstrated invariant violation is FAIL |
| Positive retired forensic bytes | Stop campaign; INCONCLUSIVE while investigated, not automatic proof of migration or PASS |
| Unexpected pre-arm input | Source retires/fails closed; INCOMPLETE unless evidence establishes an actual safety violation. Do not reuse that process |
| Missing synchronization or DTR/RTS readiness | Stop fresh preparation; INCOMPLETE; no guessed boundary or modem adjustment |
| Fresh mismatch, extra record or incomplete acquisition | Stop; INCOMPLETE pending cause review. Proven semantic/authority violation is FAIL |
| Missing/invalid endpoints, partial overlap or missing new verifier output | No credit; INCOMPLETE. Do not regenerate an alleged original transcript |
| Unexpected cleanup/closure/ACL problem | Stop campaign and investigate; INCONCLUSIVE until explained, FAIL for a demonstrated unsafe operation/invariant violation |
| Lost original log / capture failure | Stop; INCOMPLETE, never reconstruct from copied excerpts |
| Deadline expiry or operator cancellation | Cleanup and INCOMPLETE, unless separate evidence proves an invariant violation |

Every material identity, stale-authority, positive-read or unsafe-cleanup anomaly
requires explicit human investigation/permission before any next attempt.
Other incomplete outcomes still require recorded human review before using the
next allowance slot. A later pass cannot erase any failure. No fourth attempt
or other scope/deadline expansion follows from unused or exhausted allowance.

## Final independent campaign review

Before the owner can consider formal H2.15 PASS, the independent reviewer must
confirm all of the following in a separate execution/evidence record:

1. Preserve R1-C1's approved 4433/4525 credit and its narrow missing-verifier
   exception exactly; do not extend that exception to new cycles.
2. Identify two additional individually qualifying physical cycles, C2 and C3,
   each with its own attributable originals, full containment and cleanup.
3. Review all attempts, including incomplete/failed outcomes and readiness
   stoppages, against the approved allowance and stop decisions.
4. Verify all ten R1 requirements, source identity, environment/boot provenance,
   artifact integrity and separation of physical versus synthetic evidence.
5. Resolve anomalies through explicit evidence/review; confirm no unauthorized
   deadline, attempt, ACL, diagnostic or scope extension occurred.
6. Obtain the human reviewer's explicit campaign acceptance. No automated
   manifest, successful exit, acknowledgement or matching barcode grants it.

H2.07 remains partially substantiated; H2.08/H2.09 remain proposed bounded PASS
findings; H2.13 retains its accepted **PASS WITH EXPECTED CLEANUP WARNINGS**.
Neither this plan nor a future H2.15 PASS automatically changes those gates.
Even a complete H-VM campaign does not qualify production Rust attachment,
Core binding/Racket events, bare-metal appliances or deployed access controls.

## Readiness findings and checks performed for this plan

| Severity | Finding / boundary |
| --- | --- |
| BLOCKER | No structural A3.2 CLI/choreography incompatibility with R1 identified. A digest mismatch or unsupported required operation would block execution planning. |
| MAJOR | No new confirmed source/authority defect identified by read-only inspection. Physical execution has no present authorization; all native GO gates remain mandatory. |
| MINOR | Historical A3-01/first-attempt/verifier transcripts and H2.07's pre-removal scan evidence remain unavailable. The C1 exception is not a recovery or a new-cycle waiver. |
| INFORMATIONAL | Native ACL utilities, live device access/users, logger PTY behavior, actual boot/kernel and physical readiness were not exercised here. Native ACL tools require recheck; missing tools are NO-GO, not permission to install or broaden access. |
| INFORMATIONAL | Source/model evidence is saved, not rerun; H-VM/identity coverage is bounded; raw copies share VM/storage loss risks; production Rust/Core/security qualification remains future work. |

Preparation checks are read-only repository/criteria/source identity, actual
live-path source inspection, prior-report hash/test inventory, earlier ACL
command evidence and installed utility help. No scanner diagnostic, its
synthetic suite, native physical preflight, device open, ACL operation, USB cycle
or acceptance campaign was executed. The plan's links, command vocabulary,
R1 mapping, status/count consistency, privacy and untracked Markdown receive
documentation validation; no prior CI or saved synthetic run is presented as
validation executed by this task.
