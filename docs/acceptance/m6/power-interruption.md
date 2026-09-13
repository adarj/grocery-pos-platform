# Milestone 6 Power-Interruption Qualification

> **WARNING: disposable test appliance only. Never run this procedure on a
> production register or with store data.**

Physical abrupt-power testing qualifies the selected hardware, filesystem,
Fedora/SQLite stack, and Grocery POS recovery behavior together. `SIGKILL` and
VM process termination are useful Tier A evidence but are not substitutes.

## Prerequisites

1. Record the model-level hardware/storage/filesystem configuration in
   [reference-hardware.md](reference-hardware.md).
2. Use synthetic test data only and create a separately validated backup.
3. Confirm recovery media, technician VT/admin access, and the explicit restore
   runbook are available.
4. Confirm Fedora Kinoite 44, Grocery POS artifacts, SELinux mode, and artifact
   hashes. Record no serial numbers or credentials.
5. Start with a current v1-v6 database that passes full integrity, foreign-key,
   migration-history, and Grocery POS schema validation.

## Twenty-five-cycle minimum matrix

Distribute at least 25 physical hard-reset/power-removal cycles across:

- idle with an open shift;
- immediately after transaction start;
- after one or more scans;
- around an accepted scan response;
- after cash tender;
- around transaction completion;
- during backup candidate creation/validation;
- immediately after backup publication;
- during support-bundle creation;
- ordinary idle WAL/checkpoint activity where a repeatable trigger exists.

Do not assume which side of a durable commit the cut reached. After recovery an
interrupted mutation may be absent, or present exactly once. A partial or
duplicate financial effect is never acceptable.

## Post-boot procedure for every cycle

1. Do not move, delete, rename, or truncate DB/WAL/SHM/journal state.
2. Allow normal SQLite/POS Core recovery and wait for `/ready`.
3. Run the installed full integrity check (which includes foreign-key checking)
   and require exact current migration history and Grocery POS schema validity.
4. Recover the transaction and exact command receipt; classify the interrupted
   mutation as absent or exactly-once committed.
5. Verify transaction version, append-only journal/receipt coupling, completed
   cash movement cardinality, expected cash, and immutable reconciliation.
6. Verify the kiosk lifecycle and record the cycle, scenario, timestamp,
   outcome, and sanitized evidence reference.
7. At selected intervals create and validate a new backup.

## Immediate stop conditions

Stop the campaign and preserve all evidence if any of these occurs:

- integrity or foreign-key check failure;
- unsupported/invalid schema or migration history;
- duplicate financial fact;
- accepted durable command receipt without its required atomic business effect;
- missing committed financial effect contrary to the observed durable outcome;
- cash-ledger/reconciliation mismatch;
- unexplained readiness failure or database corruption.

Do not continue cycling after corruption. Do not delete hot WAL/journal state.
Do not auto-restore or select another backup.

## Campaign completion

After at least 25 passing cycles, create a fresh validated backup. Perform one
explicit backup-to-restore round trip on a disposable target and verify the
expected financial facts. Record any UPS model, whether OS signaling exists,
and what battery/shutdown/cold-start behavior was actually tested. No result is
`passed` until the physical campaign was executed.
