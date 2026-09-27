# Milestone 7 security requirements

IDs are stable acceptance references. A checked test plan is not proof of execution; consult the generated ledger and external records.

## CP1 — Identity and credentials

- M7-CP1-001: POS identities are distinct from Unix users and retain same-ID cashier compatibility.
- M7-CP1-002: New PINs obey strong 8–12 ASCII-digit policy; Argon2id uses m=19456 KiB, t=2, p=1.
- M7-CP1-003: PINs/verifiers stay out of ordinary listings, support, logs, and Flutter persistence.
- M7-CP1-004: Bootstrap creates no default manager or hidden credential.

## CP2 — Sessions

- M7-CP2-001: Opaque 256-bit bearer sessions are process-local, digest-validated, idle/absolute bounded, and restart-invalid.
- M7-CP2-002: Protected requests reload authoritative operator and credential state.
- M7-CP2-003: Known-user throttle is durable; unknown-user failure is anti-enumerating; no permanent attacker-triggered lockout.
- M7-CP2-004: Lock/logout removes presentation authority without discarding exact transaction recovery.

## CP3 — Authorization and ownership

- M7-CP3-001: Fixed server-side grants deny unknown roles/actions by default.
- M7-CP3-002: Mutation requires operator ownership; read-any does not grant takeover.
- M7-CP3-003: Shift ownership and manager foreign-close are authoritative.
- M7-CP3-004: Actor provenance prevents cross-operator recovery and distinguishes explicit pre-v9 history.
- M7-CP3-005: Alternate cashier API paths preserve pre-count blind cash summary.

## CP4 — Scoped approval

- M7-CP4-001: Fresh whole-sale void needs independently authenticated supervisor/manager approval.
- M7-CP4-002: Requester stays actor; even a manager requester cannot self-approve.
- M7-CP4-003: Capability is exact-command-bound, 256-bit, digest-only, 90-second monotonic, single-use, and process-bound.
- M7-CP4-004: Consumption, receipt, requester, approver, and audit evidence commit atomically.
- M7-CP4-005: Modern missing approval provenance fails closed; pre-v10 voids remain explicitly legacy.

## CP5 — Audit

- M7-CP5-001: Audit evidence is separate from replay and command-local attribution.
- M7-CP5-002: Sequence/hash chain is contiguous; supported writes are append-only.
- M7-CP5-003: Required audit failure rolls back consequential success.
- M7-CP5-004: Best-effort audit failure cannot reverse rejection.
- M7-CP5-005: Corruption is detected and runtime startup fails closed.
- M7-CP5-006: Root-only inspection audits successful access.
- M7-CP5-007: Audit excludes secrets, request bodies, and unnecessary business/cash data.

## CP6 — Lifecycle and recovery

- M7-CP6-001: PIN change/reset rotates revision atomically without losing identity/history.
- M7-CP6-002: Stale-revision fresh mutation fails at the final writer boundary.
- M7-CP6-003: Already-durable exact command recovery survives credential rotation.
- M7-CP6-004: Role/active/PIN changes revoke unconsumed grants without revival.
- M7-CP6-005: Root reset is explicit, TTY-protected, canonical-DB-only, audited, and not POS manager authority.
- M7-CP6-006: Explicit restore selects exact backup security state and requires reauthentication.
- M7-CP6-007: Auth readiness is observable without redefining `/ready`.

## CP7 — Qualification

- M7-CP7-001: Full repository regression passes at schema v12.
- M7-CP7-002: Adversarial authentication, authorization, approval, lifecycle, and corruption tests fail closed.
- M7-CP7-003: Large audit history preserves checkout, startup, backup, and restore correctness.
- M7-CP7-004: Built packages preserve source security contracts.
- M7-CP7-005: x86_64 Flatpak and appliance derivations execute on a capable builder.
- M7-CP7-006: Booted Kinoite 44 x86_64 appliance passes installed security/recovery scenarios.
- M7-CP7-007: Physical kiosk preserves lock, navigation, display/input, and Unix/Flatpak separation.
- M7-CP7-008: Abrupt physical interruption preserves SQLite/audit/credential/business atomicity.
- M7-CP7-009: Whole-M7 source audit finds no unexplained bypass, secret persistence, future migration, or listener escape.
