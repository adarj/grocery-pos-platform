# Tier B — booted Kinoite 44 x86_64 appliance

Status: **not run**. No booted target evidence is present in this repository record. Use a disposable appliance with no production/store data. Record hardware identifier, image/deployment digest, Core/Flatpak/bundle artifacts, UTC date, operator, command/log references, and pass/fail for each case. Keep large logs in ignored local evidence.

`just qualify-m7-kinoite` performs read-only observations and exits 77 unless run as root on booted Fedora Kinoite 44 x86_64 OSTree. It checks installed RPMs, SELinux, service, literal-loopback readiness, schema v12/chain via read-only database validation, DB mode, Unix identities, kiosk DB denial, auth-tool denial, installed Flatpak permission contract, PLM/sleep masks, and safe root status. It does **not** run `grocery-pos-audit verify`, because successful audit access appends an event. Run that separately and record the new `audit.accessed` sequence.

## Mandatory state-changing record

For each line record `passed`, `failed`, `blocked`, or `not_run` with an actual evidence reference. A checklist without execution is not a pass.

1. M7-B-001: fresh provisioning, no hidden/default POS manager, kiosk locked; bootstrap at least one active enrolled configured cashier and one independent approval-capable supervisor/manager. Check `register_auth_ready` and `approval_auth_ready`. The two booleans do **not** prove an independent approver exists for every requester.
2. M7-B-002: cashier login, shift, sale, supervisor/manager whole-sale void approval; cashier remains actor/session, approver is separate, audit/receipt/provenance verify. Exercise self PIN change, root reset, active-operator disable, and open-sale reauthentication/recovery. Kiosk must not gain root recovery authority.
3. M7-B-003: POS Core restart and machine reboot invalidate prior bearer and unconsumed approval; durable exact command recovery works; no Internet/DNS/cloud needed for checkout. Exercise support collection and check every member for credential/audit/sale details; validated backup and older-backup restore select exact historical security state. Inspect displaced state separately; no rows merge. Audit verify/list as root and non-root denial are explicit state-changing/read actions.
4. M7-B-004: ten controlled normal reboot cycles with varied locked/authenticated/open-shift/open-sale/completed-sale/large-audit-tail states. After each: Core ready, one new `runtime.started`, valid audit chain, old capabilities invalid, kiosk locked, no duplicate transaction/cash effect.
5. M7-B-005: if a reproducible prior v11-capable deployment exists, upgrade v11 DB to v12, prove old unconsumed grant removal, then rpm-ostree rollback. The older binary must refuse future v12 schema. Roll forward and resume unchanged v12 DB. If prior artifact is unavailable, record `blocked`; do not fabricate a downgrade. OS rollback is not DB downgrade.

Security-rich backups contain PHC verifiers and audit history. Protect them as sensitive data. Explicitly selected older backups can restore older valid PINs and roles. After schema upgrade create a new validated v12 backup; the restore path does not silently migrate an older backup. There is no automatic credential reset or old-backup deletion.

Record actual results here after execution. Do not convert this `not_run` placeholder into a pass without timestamped target evidence.
