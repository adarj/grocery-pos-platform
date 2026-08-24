# ADR-0017: Use an append-only shift cash ledger for drawer accountability

## Status

Accepted

## Context

Store shifts need a durable opening float, expected physical cash, closing
count, and variance. The transaction journal owns what was sold, while drawer
accounting answers a different operational question. Tendered cash is not
drawer growth when change is returned, completion is the current finalized
sale boundary, and a destructively updated running balance would be difficult
to audit. Cash discrepancies must be recorded rather than hidden.

## Decision

- Migration v6 introduces append-only `shift_cash_movements` and immutable
  `shift_cash_reconciliations`.
- A new tracked shift atomically records exactly one `opening_float` movement.
- A completed context-bearing cash sale atomically records one `cash_sale`
  movement whose amount is the authoritative transaction total.
- The movement timestamp is the exact transaction completion timestamp.
- Voids create no cash movement.
- Expected cash is opening float plus completed cash-sale movements.
- Close requires an exact physical count; over/short is counted minus expected.
- Reconciliation and shift close are atomic, immutable, and repeat-safe.
- Nonzero variance does not prevent closure.
- Flutter parses input and presents POS Core values; it does not calculate
  accounting truth.
- Closed pre-v6 shifts receive no fabricated accounting facts, and v5 open
  shifts must be closed before migration to v6.

## Consequences

The register gains auditable, restart-safe physical-cash expectation and
immutable variance. Same-ID completion recovery cannot double-count a sale,
and future movement types have a natural extension point.

The current expected formula supports only opening float and completed cash
sales. Old closed shifts remain untracked. Cash drops, paid-outs, refunds,
drawer hardware, manager approval, and authentication remain absent. Local
system-clock accuracy is still an operational dependency.

## Alternatives considered

- A mutable drawer-balance column.
- Treat tendered cash as drawer growth.
- Calculate expected cash only in Flutter.
- Reconstruct the shift from receipt queries at close.
- Fabricate zero opening balances for old shifts.
- Force counted cash to equal expected cash.
- Block every nonzero variance.

## Scope

This decision does not define cash drops, paid-outs, refunds, cash-drawer
hardware, manager variance approval, inventory accounting, bank deposits,
general-ledger export, Z reports, store accounting, or legal cash-control
compliance.
