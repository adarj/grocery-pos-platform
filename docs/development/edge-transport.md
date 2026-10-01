# Generic Edge transport and Racket client (M8.2.6)

The reusable `edge-server` serves the seven frozen v1 routes using an already
opened filesystem `std::os::unix::net::UnixListener`. It does not bind/unlink the
production pathname or acquire `LISTEN_FDS`. Privileged bootstrap supplies the
expected Racket UID; `LinuxPeerCredentials` checks `SO_PEERCRED` before Hyper sees
the socket. Same-user process tests and injected expected-UID negatives are
repository evidence, not separate service-UID/DAC/SELinux qualification.

`serve` accepts a Send factory that constructs the non-Send Core, FIFO queues,
executor, adapters, and binding installation inside the control thread. The
factory returns `ControlRuntime` or a narrow `ControlPlane` wrapper. Application
panic hooks must be installed before starting it; the existing executor panic
privacy contract still applies. HTTP tasks receive typed replies, never Core
capabilities. The thread processes bounded requests, drives execution on its own
cadence, and asks Core to emit heartbeats. A fatal Core error abandons the entire
server epoch and closes connections; it never becomes a recoverable HTTP 500.

`ServerLimits` centralizes initial bounds: 16 connections, 64 queued control
requests, 16 KiB HTTP buffer, 32 headers, 256 KiB command/non-stream JSON, 64 KiB
per event, five-second header/body/control/write deadlines, ten-millisecond
executor cadence, and ten-second heartbeat cadence. Counts/cadences are subject
to M8.2.7 qualification. HTTP/1 keep-alive is disabled. Write half-close is allowed
because Racket's mature client closes its write half after response headers;
this still permits only one request. A pending socket write has its own deadline,
which does not run while waiting for a new Core event.

Mailbox-full rejection occurs before Core work and maps to 503. A timeout after
mailbox submission closes the connection: the caller cannot infer whether a
POST was accepted. Strict structural/schema failures map to 400; unsupported
compiled kind and Core semantic/freshness/capability rejections map to 422.
Known routes with a wrong method produce 405/Allow. Core precondition/conflict,
not-found, and bounded-capacity results map to 409, 404, and 503 respectively.
Errors contain authored codes, without request bodies or a retry flag. Command
POST responses echo request correlation alongside public `CommandState`.
Compiled payload decoders distinguish structural schema failures from typed
semantic constraint failures, preserving 400 versus 422. JSON media parameters
are limited to an optional UTF-8 charset; request compression is refused.

The event stream starts with Core's atomic snapshot. A Send transport lease
maps to the Core subscription token only inside the control thread. There is one
record in the transport handoff; Core retains continuity authority. A
non-draining Core check reports overflow even while the socket is blocked.
Overflow closes the stream, discards Core's backlog, and keeps state committed.
Disconnect cleanup uses a dedicated bounded monotonic lease slot, independent
of ordinary mailbox capacity. Wakes only indicate possible work; every event
comes from polling Core. Producers register their waiter before polling; state
publication wakes all waiters so a retiring lease cannot steal its replacement's
wakeup. Reconnection has no replay.

## Racket composition and identity

The opt-in `pos/edge/client.rkt` and `session.rkt` modules run under the caller's
custodian. Existing POS startup/readiness/checkout do not require Edge. Stop a
managed session explicitly or shut down its parent custodian. A session opens
one stream; callers explicitly start a fresh session to reconnect. EOF, timeout,
malformed records, sequence/revision gaps, a second snapshot, or an agent
mismatch mark it stale and release resources. Fresh snapshots atomically replace
the stream-derived device cache. Independent GETs return values without changing
that cache. New epochs surface an `on-epoch-ended` callback, without command
replay or business recovery decisions.

`make-edge-command-attempt` generates one cryptographically random command ID
and captures immutable epoch, binding, original freshness, kind, timeout, and
payload bytes. `edge-submit-command` generates a fresh random request ID every
time. Explicit retransmission of the same attempt keeps every semantic field.
A lost POST returns `edge-transport-failure` with uncertainty; protocol rejection
and malformed response are distinct typed results. Neither 202 nor dedupe 200
asserts physical success. Command 404 never proves non-effect.

Session uptime samples keep exact edge uptime and an exact local monotonic
receipt time. Successful query results also retain local monotonic receipt time.
The estimate helper uses elapsed local monotonic time, without assuming shared
clock origins or creating a submission deadline. Attempt identity never changes
when a session reconnects.

## Reproducible client dependencies

The development shell provides pinned `http-easy-lib` 0.11.1
(`d099f4025f93b5938b7a66db821aa4888e2a2afc`), `resource-pool-lib` 0.6
(`323ca977ab55f526582f322f148cf684b79896c3`), and `actor-lib` 0.3
(`0d46e1f039bbc22372171a077884f28ccd283c93`) with fixed Nix content hashes.
`net-cookies-lib` and `unix-socket-lib` come from pinned Racket 9.1. No global
package installation is used. Production packaging of these opt-in modules
remains future daemon/application composition work.

Source inspection and regression tests require two private upstream corrections:

- Upstream 0.11.1 uses `max-attempts` as a retry counter, allowing one extra
  transmission. The pinned private copy subtracts the initial attempt. Every
  Edge request explicitly sets `#:max-attempts 1` and `#:max-redirects 0`.
- Pinned Racket's HTTP decoder reads advertised chunk lengths into one allocation
  and reads response header lines without bounds. The private copy used only by
  http-easy retains its mature parser with bounded framing and fixed-size chunk
  copying, via `nix/racket-http-client-bounds.patch`. Exception-bearing library
  diagnostics are replaced with authored static text. Other backend HTTP users
  retain their original module. The NDJSON reader then bounds each record before
  parsing, checks strict UTF-8, and requires exactly one JSON document.
  The private decoder also rejects premature EOF for declared body lengths and
  disables implicit decompression before response-header validation.
  Critical length/transfer headers must be unambiguous and valid; chunked EOF
  requires the zero chunk and a complete bounded trailer section. Header lookup
  normalizes optional whitespace so encoding checks cannot be bypassed. These
  checks reject malformed responses without another network attempt.

Socket path bytes are fully percent-encoded in the HTTP client's UDS authority;
HTTP host normalization must not lowercase a case-sensitive filesystem path.
POST results validate request/command correlation. Same-agent reconnect snapshots
cannot move cursors or device revisions backward; new epochs replace the cache.
Generated command/request ID strings are immutable, including through public
accessors. Client timeout configuration requires a finite positive value. The
NDJSON reader accepts LF and CRLF (CR is JSON trailing whitespace), counts all
record bytes before LF toward the limit, and rejects a partial final record.

Rust transport dependencies are Tokio (I/O, timers, synchronization), Hyper
(HTTP/1), hyper-util (Tokio I/O/timer bridge), http-body-util (bounded body
collection), bytes (HTTP frame storage), and rustix (safe Linux peer credentials).
Versions are locked in `rust/edge/Cargo.lock`; Core has no runtime dependency.

## Repository fixture and checks

`edge-qualification-fixture` is gated by the `qualification` feature and uses
synthetic commands only. It creates a temporary test-owned UDS and runs the real
codec → Core → FIFO → executor → edge-sim path. Its modes inject lost responses,
slow-reader event pressure, or fresh binding replacement. Metrics contain bounded
counters/request IDs, never payloads. This is not a production daemon or a
simulation activation/security mechanism.

The ordinary Racket test suite builds the fixture lazily with locked Cargo
inputs. `just check-rust` and `just check` include the Rust and cross-language
checks. The M8.2 acceptance namespace adds a separate clean-tree qualification campaign; ordinary tests remain canonical regression checks. Real-process evidence
covers lost-response/same-attempt dedupe with exactly one adapter start,
fragmented/coalesced NDJSON, fault ordering, disconnect cleanup, overflow/fresh
snapshot, and restart without command replay.

M8.2.7 uses two commits: reviewed qualification machinery first, then a clean committed-tree campaign and documentation-only evidence freeze. See [M8.2 acceptance](../acceptance/m8.2/README.md).
Real hardware, discovery/selectors, complete production configuration, inherited
FD bootstrap/deployment units, Linux identity/SELinux qualification, and peripheral
business integration remain outside this checkpoint. SQLite remains schema v12.
