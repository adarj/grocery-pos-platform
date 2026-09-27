# Tier D — destructive physical interruption

Status: **not run** (`M7-D-001`). Requires a disposable physical appliance. Do not run on production/store data. At least 25 controlled abrupt power/reset cycles are recommended for a passing campaign. A POS Core SIGKILL is not physical power-loss evidence.

Distribute interruption phases across locked idle, authenticated session, open sale, accepted mutation, approved void, shift close, audit-heavy write, PIN rotation/root reset, and validated backup. Record intended phase, actual observed phase (do not assert exact timing without instrumentation), power method, boot time, command IDs, expected/observed result, and evidence reference for each cycle.

After every recovery verify SQLite integrity and foreign keys, exact v1–v12 migration history, full security audit chain, credential PHC/revision coherence, no revived bearer or process-bound approval, exact-command idempotency, cash and reconciliation invariants, readiness, and support privacy.

Credential replacement may be wholly absent or wholly committed. A committed rotation must have its required lifecycle audit event, throttle/grant effects, and matching verifier/revision. An approved void may be wholly uncommitted or fully durable with receipt, actor, approver, audit evidence, and slot effect. A committed audit row must fit the contiguous hash chain. A published backup must validate. Partial states are failures, not acceptable interruption outcomes.

Store run logs and large DBs only in ignored local evidence. Mark blocked/not_run honestly when physical equipment or a controlled interruption facility is unavailable.
