# POS Integration Testing

## Purpose

The real POS integration suite verifies that the production Flutter client and
cashier orchestration compose correctly with the real Racket HTTP process and
file-backed SQLite persistence. It complements, rather than replaces, the
faster Flutter unit/widget and Racket test suites.

Run it from the repository root:

```bash
just test-pos-integration
```

`just check` includes this suite. Plain `just test-flutter` does not: the files
live under `flutter/apps/pos_terminal/integration/`, outside normal `test/`
discovery, so real child-process work is always explicit during focused
development.

## Fixture ownership

Each test fixture:

- discovers the repository root by walking upward for `flake.nix` and the
  Racket entry point;
- allocates an available loopback TCP port;
- creates an isolated temporary directory;
- activates the versioned development Catalog Snapshot v2 into that fixture's
  SQLite database through the production catalog CLI before first startup;
- starts `pos-backend-racket/main.rkt` with an absolute temporary
  `SQLITE_DB_PATH`;
- waits for the real `GET /health` response with a bounded deadline;
- uses a `FileCashierSessionStore` under the same temporary root;
- consumes bounded stdout/stderr tails for failure diagnostics;
- stops POS Core with bounded SIGTERM/SIGKILL handling; and
- removes the temporary directory after clients and controllers close.

The fixture never touches `.local/sqlite/pos-dev.db` or the operator's normal
XDG cashier recovery file. It adds no production endpoint or fault-injection
behavior. Restart scenarios deliberately retain only their fixture's SQLite
and recovery files between child-process instances. The catalog is activated
only for the initial fresh fixture; POS Core restarts reuse the persisted rows
without automatic reseeding.

The full-sale expectations therefore cross the production path:

```text
Flutter controller
  -> HttpPosCoreClient
  -> Racket runtime
  -> SQLite catalog lookup
  -> sale-time transaction event
```

The suite verifies the configured development line tax, tax-inclusive tender
sufficiency and change, repeated per-line rounding, restart replay, and
same-command recovery without duplicate merchandise or tax facts. It also
removes a middle line through the production command path, retries an already
accepted removal with the same ID across POS Core restart to prove only one
line is removed, and verifies that a voided basket/tax projection survives
restart before explicit Next Sale creates a clean transaction.

If catalog activation fails, the fixture fails before starting the server and
reports bounded CLI output. The fixture activates Catalog Snapshot Schema v2,
including deterministic development-only tax categories. Test Apples exists
only in that version-controlled snapshot; production runtime contains no
implicit fixture lookup, and the fixture rate is not legal tax configuration.

## Environment

The suite is Linux-oriented because Linux is the current POS appliance and CI
target. The repository Nix development shell already supplies Flutter and
Racket; no separately started server, Docker service, cloud service, or network
dependency is required.

Successful output stays concise. On startup failure, the fixture reports the
test URI, temporary database path, process exit status when known, and bounded
backend output tails. Recovery-file contents are not logged.
