# M7 security acceptance audit

## Scope and disposition

This report covers the uncommitted CP7 acceptance worktree on committed CP6 baseline `1168436c1acff461ca90ca05a01b0b4eb54d188a`. The generated [result ledger](acceptance-results.json) is authoritative for commands actually run. A repository test or package derivation is not evidence that Fedora Kinoite booted, SELinux enforced, a physical display/touch path worked, or a physical power interruption was survived.

Overall disposition is **conditional** pending mandatory external Tier B/C/D execution. The complete final acceptance rerun passed all 15 Tier A groups, with its ledger generated at `2026-09-27T00:06:06Z`, including the real x86_64 artifact derivations through host emulation. The five booted-appliance, four physical-kiosk, and one destructive-interruption cases remain `not_run`. A failure in any executed mandatory case would change disposition to `failing`.

## Executed results

Host: Fedora 44, aarch64, kernel `7.2.7-200.fc44.aarch64`. Committed baseline and uncommitted worktree identity are recorded separately in the ledger; HEAD alone does not uniquely identify this CP7 source.

| Evidence group | Actual result |
| --- | --- |
| Racket | 605 tests passed |
| Flutter | 265 tests passed |
| Flutter/Core/SQLite integration | 34 tests passed |
| `just check` | Analysis clean; repeated 605/265/34 tests passed |
| Core and appliance package checks | Passed; extracted Core lifecycle/privacy smoke passed |
| Native Core/appliance RPM builds and flake checks | Passed; cached checks retain their previously built derivation results |
| M7 static audit and source isolation | Passed |
| Large ledger | 10,000 synthetic typed events plus real operations; 10,041 final events; passed |
| Process-death campaign | 25 SIGKILL/restart cycles passed in 3 minutes 55 seconds; not power-loss evidence |
| ENOSPC | Private 512 KiB M6 and 2 MiB M7 tmpfs campaigns passed |
| x86_64 Flatpak and appliance bundle | Both real derivations and contract checks passed under emulation |

The complete final acceptance runner exited 0 **after** evidence-publication hardening. Every Tier A group was requested by that execution, including the actual x86_64 Flatpak and appliance-bundle checks; successful cached derivation resolution is artifact/build-contract evidence, not booted appliance evidence. The runner itself regenerated the ledger from this run, with no manual preservation or replacement of group results. Afterward, four isolated runner-control tests (three publication failures and one success), ten report-generator scenarios, and four additional unsupported/unknown/duplicate-evidence checks passed without changing the ledger. Mock runner results are explicitly **not** qualification evidence.

An earlier closure attempt correctly exited 1 and published `failing` after a crash-campaign readiness timeout. A separate diagnostic attempt also timed out during fixture catalog activation. These failures coincided with severe VM memory pressure (approximately 356 MiB available and recent memory stalls); that observation alone does not prove causation. After the developer restarted the VM, the complete final runner passed, including all 25 crash cycles, without code changes or a longer readiness limit. The failed attempt's ledger, summary, and diagnostics are preserved under ignored `.local/acceptance/m7/closure-failed-run/`; they were not substituted into the final results.

### Host-specific stress observations

The final stress recorded main DB 2,039,808 bytes, WAL 4,457,872 bytes, and backup 2,293,760 bytes. Typed bulk append took 297 ms, chain verification 66 ms, runtime construction/startup 94 ms, representative service checkout 7 ms, backup 172 ms, and isolated restore/verification 256 ms. These are observations from this host, not universal guarantees or booted-appliance measurements. Four real unknown-ID login failures and 20 actual authenticated foreign-read denials accompanied the synthetic volume. Approval/retry, active-sale PIN rotation, support privacy, and byte-exact restored audit rows all passed.

## Source-boundary review

The CP7 static audit requires exact v1–v12 migration lineage and rejects v13; centralizes production raw SQLite connections; retains WAL/FULL, foreign keys, and busy retry; checks literal loopback listener, Core service Unix identity and filesystem hardening, root auth/audit wrappers, and narrow Flatpak permissions. Production Flutter contains no direct `pos.db`/SQLite reference. Protected HTTP routes are mediated by Racket authentication; the `/auth/change-pin` target comes from its authenticated principal. Role grants live in the Racket fixed policy; Flutter decodes server presentation permissions. The audit ledger does not appear in transaction replay, and no ordinary audit HTTP route exists. No new cloud or remote-listener dependency was introduced by CP7.

The source scan is a tripwire plus manual classification, not an exhaustive proof against all future spellings. Existing focused tests supply behavioral authorization, provenance, capability, audit, lifecycle, and privacy evidence. The report does not infer that root Unix identity is a POS manager: root recovery and POS role authority remain separate.

## Deterministic coverage

The complete Racket/Flutter/integration/package gates and exact run statuses are in `acceptance-results.json` and ignored `.local/acceptance/m7/*.log`. One new regression upgrades every valid historical schema prefix v1–v11 to exact v12; populated representative migration and unknown-future refusal remain covered by existing tests. The M7 10,000-event local stress uses typed appends plus a smaller real login/foreign-read denial wave, then verifies runtime startup, shift/checkout, exact command retry, approval and void retry, active-sale PIN rotation/recovery, support privacy, backup, byte-exact isolated audit restore, and full chain. The 25-cycle SIGKILL group specifically proves accepted-command recovery; it does not claim the scope of the physical Tier D campaign. Security-specific ENOSPC uses a private tmpfs and checks failed required PIN-reset/audit rollback and failed-login denial, in addition to inherited M6 SQLite/backup/support failure tests.

Synthetic volume metrics, timing, DB/WAL bytes, and exact group counts must be read from the current ignored stress log. They are host observations, not universal service-level guarantees. The 30-second installed readiness contract still requires booted appliance observation under realistic storage load.

## Inherited reliability boundaries

CP7 adds no migration or product behavior. Transaction Command Schema v1, integer money/tax, event and receipt schemas, replay, expected-version and durable idempotency, cash ledger/reconciliation, blind count, WAL/FULL and busy retry, backup publication, restore doctrine, support privacy, process-local sessions, loopback API, Unix separation, Flatpak filesystem isolation, and operator-bound local recovery remain governed by the CP1–CP6 implementation and their existing tests. Acceptance tooling writes only ignored test artifacts and the concise M7 ledger; it does not modify the frozen M6 evidence.

## Residual qualification risk

- **External evidence:** Tier B booted x86_64, Tier C selected physical kiosk, and Tier D physical interruption are not supplied by repository execution. Their status remains `not_run` until actually performed.
- **Target execution:** Actual x86_64 Flatpak/bundle derivations and contracts passed through emulation. This does not prove a booted Kinoite x86_64 appliance, deployed systemd/SELinux, or physical kiosk execution. The earlier host `/etc/resolv.conf` sandbox limitation did not recur in this run.
- **Audit growth:** Append-only denial history remains a storage-availability risk. CP7 measures a bounded local volume, but physical storage pressure and backup/restore time must be qualified on the target; no retention/deletion is added.
- **Evidence granularity:** The 25-cycle process-death group emphasizes command recovery. Focused tests cover session/approval/credential restart semantics; physical interruption across those boundaries remains Tier D. The M7 ENOSPC harness covers credential/audit, approved-void rollback with preserved grant, and inherited backup/support paths. It does not claim a disk-full cut at every exact machine instruction.

## Findings

- **A:** No security/data-boundary defect identified by the executed qualification.
- **B, fixed:** The acceptance runner could return success after summary/report publication failed. Expected test-command failures are now collected explicitly, while recording/publication failure stops the runner. Isolated injected failures at all three publication stages prove this behavior.
- **B, fixed:** The new target observation helper could accept broadened installed Flatpak permissions alongside expected substrings. Exact-line checks and rejection of filesystem, X11, all-device, and bus grants are protected by six deterministic fixtures. Shipped Flatpak permissions were not changed.
- **C, fixed:** Initial stress/ENOSPC coverage was too narrow for the planned claims. The stress now includes actual ownership denials, approval, PIN lifecycle/recovery, support privacy, and exact restored audit rows. ENOSPC now includes approved-void rollback with preserved grant.
- **C, fixed in closure:** The report previously described a full acceptance run preceding the publication-hardening correction. The final full rerun now supplies the ledger, and this report records its exact generation time and fresh stress observations. No executable tooling or product source changed during closure.
- **B, resolved by final rerun:** The earlier memory-pressure-associated qualification timeout remains recorded as failed evidence; the final complete run passed after VM restart with unchanged tests and readiness bounds. No persistent code defect was established.
- **Qualification pending:** Mandatory booted/hardware/destructive evidence is absent, not passed. No unresolved A/B code finding remains, but production qualification is incomplete.

Any executed external failure must be classified A (security/data/release boundary) or B (operational/security blocker) and corrected/requalified. Do not waive an A/B finding to make the ledger green.
