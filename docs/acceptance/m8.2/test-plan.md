# M8.2 Tier-A test plan

This is a plan, not an executed acceptance record. All groups are mandatory and repository-only. Commands below run from the pinned development shell; the reporter owns IDs/titles/requirements. Focused suites are intentionally repeated by canonical gates, not counted as independent discoveries.

| Group | Exact Phase-2 command (runner also imposes finite outer timeout) | Evidence kind/purpose |
| --- | --- | --- |
| M8.2-A-001 | `just check-rust` | Locked workspace formatting, denied-warning Clippy, all-feature unit/integration/doctests |
| M8.2-A-002 | `bash scripts/acceptance/m8-2-campaign.sh racket` | Focused typed parsing/client/session and real-process Edge regressions |
| M8.2-A-003 | `just check` | Canonical complete repository gate, including unaffected Flutter/business boundaries |
| M8.2-A-004 | `bash scripts/acceptance/check-m8-2-static.sh` | Whole-M8.2 source tripwire/classification aid; no runtime proof |
| M8.2-A-005 | `bash scripts/acceptance/m8-2-campaign.sh identity` | Core admission/dedupe/conflict, dual retention, eviction/reuse, payload and event preflight/fatal tests |
| M8.2-A-006 | `bash scripts/acceptance/m8-2-campaign.sh effects` | Real FIFO/adapter path, full timeout/panic/binding-loss evidence matrix, bounded serialization and independence |
| M8.2-A-007 | `bash scripts/acceptance/m8-2-campaign.sh binding` | Witness safety/rebind/stale facts, revisions/global sequence/atomic snapshot, subscriber token/overflow/size failures |
| M8.2-A-008 | `bash scripts/acceptance/m8-2-campaign.sh transport` | Strict codec + real UDS hostile framing/security/mailbox/Notify/fatal tests and patched Racket/NDJSON adversaries |
| M8.2-A-009 | `bash scripts/acceptance/m8-2-campaign.sh uncertainty` | Server-observed single lost POST, no implicit GET/retry, explicit same-attempt request-ID change/dedupe/one physical start; zero redirects |
| M8.2-A-010 | `bash scripts/acceptance/m8-2-campaign.sh capacity` | Actual default capacities plus 1,000 semantic operations/1,000 explicit dedupes through full live path |
| M8.2-A-011 | `racket scripts/acceptance/m8-2-process.rkt death 25` | Controlled edge process death/new-agent snapshots, five rotating software observation points |
| M8.2-A-012 | `bash scripts/acceptance/m8-2-campaign.sh dependencies` | Nix realizes exact pinned patched collections; validates installed private boundary and executes malicious-response regressions; lock/patch hashes |
| M8.2-A-013 | `bash scripts/acceptance/m8-2-campaign.sh isolation` | Source/simulator/fixture isolation and filtered Nix derivation stability under ignored local state |
| M8.2-A-014 | `bash scripts/acceptance/m8-2-campaign.sh integrity` | Closed reporter, isolated mock-runner provenance/failure/publication/signal tests, documentation consistency and static-boundary mutation tests |

## Temporal identity

Fake monotonic clocks protect every dual-retention combination: freshness/recovery both open, only freshness open, only recovery open, both expired. Since default recovery (120 s) exceeds freshness horizon (60 s), the reverse-order case uses a documented test-local policy. Equality of freshness remains retained; recovery age equality permits eviction once freshness strictly passed. Default protected cache is filled, evidence checked, then time advanced to reuse capacity. Original evicted replay is stale; 404 is not non-effect. Recycling a forgotten ID with new semantics/deadline is a prohibited client act, not a permanent server conflict promise; new Racket attempt IDs are independently fresh.

## Effect and binding substrate

Tests observe None/Possible/Confirmed at timeout, panic and binding loss, including confirmed dominance and contradictory/direct confirmation. Known failure/rejection pairs remain distinct from interruption uncertainty. Operations stop polling after containment; records precede effects; terminal payload Weak references release and compact identity remains useful. Same-resource queued work preserves surviving FIFO/no overlap; two resources remain active independently.

Real lifecycle APIs exercise disconnect/fault/connecting/install/rebind, unchanged configured resources, old queued/active isolation, exact stale facts, move-only installation witnesses and cleanup. Device and command state events share checked global sequence, separately from revisions. Overflow commits authoritative state and closes continuity; stale capabilities cannot access replacements. A retiring Notify waiter regression qualifies the actual publication/wait path. Cleanup is tested while ordinary mailbox is full.

## Defaults and load

Current source defaults qualified by assertions/behavior, not copied into product configuration:

| Resource | Source default | Protection |
| --- | --- | --- |
| Waiting FIFO | 32/resource plus active operation | 32 waiting + active; 33rd waiting refused before record/effect; FIFO completions |
| Retained commands | 4096 | protected fill/refusal, no eviction, fake-time terminal expiration and reuse |
| Binding epochs | 4096/agent | first activation included, 4096 successful epochs, 4097th fail closed |
| Subscriber events | 256 records | exact capacity then state/heartbeat overflow; discard backlog/current reconnect cursor |
| Control mailbox | 64 queued requests | native blocked control gate, 64 fits/next Busy, cancelled replies, cleanup and sustained query/drive progress |
| Accepted connections | 16 | 16 partial bodies held, next refused before route/Core work, bounded shutdown |
| Horizon / timeout | 60,000 ms each | exact boundaries and +1 rejection with fake time |
| Terminal recovery | 120,000 ms | exact age protected/evictable tests without sleeping |
| Event / command / response | 65,536 / 262,144 / 262,144 bytes | bounded encoders/readers, boundary/one-over and hostile chunk/declared-length cases |
| HTTP parser / headers | 16,384 bytes / 32 | exact parser-buffer/header-count boundary and one-over rejection |
| Header/body/control/pending write | 5 s each | shortened test-local deadlines; pending-write timing excludes healthy idle streams |
| Executor / heartbeat | 10 ms / 10 s | source defaults; tunable scheduling tests, no protocol/SLO claim |

The 1,000-operation load is deliberately finite: each fresh attempt is explicitly deduped and its accepted/executing/terminal events checked before proceeding. Request/physical-start cardinality, exact cursor delta, unchanged device revisions and actual command-cache high-water/final retention are checked. Capacity reuse is established separately with fake time. Timing/throughput are **host observations, not service-level/performance guarantees**. Rust fixture peak/final RSS are read from allowlisted Linux VmHWM/VmRSS values when available; other hosts report unavailable. These observations do not establish a portable memory guarantee. The optional 50,000 run extends volume without changing mandatory evidence or bypassing cache policy.

## Hostile framing and client continuity

HTTP tests use Hyper's parser: oversized headers/count, incomplete headers/body deadline, Content-Length and chunked overflow, invalid/truncated chunk framing, conflicting lengths, unsupported media/encoding, all status categories, wrong methods/Allow and opaque percent/slash-hostile IDs. Hyper accepts TE+CL using TE precedence, then closes after one request; the test forbids reinterpreting suffix bytes or serving a second command. This parser behavior is recorded explicitly rather than claiming blanket ambiguous-input rejection.

Strict-codec tests reject duplicate decoded keys across nesting, unknown fields, wrong types, depth/work/string/container limits, kind/payload mismatch and multiple documents. Structural 400, typed semantic 422 and HTTP/framing rejection are distinguished. Patched Racket tests bound both success/error responses, CL/chunks/trailers, truncation, invalid/ambiguous metadata, whitespace-normalized encodings and no automatic replay/redirect.

NDJSON covers exact 64 KiB/LF, one over/no newline/partial EOF, whitespace, LF/CRLF (CR counts toward record bound), strict fragmented/malformed UTF-8 and one-document rules, byte-fragmented/coalesced HTTP chunks. Sessions check snapshot-first/full validation, exact cursor/revision increments, unknown slots, uptime/epoch consistency, stale on violations, same-agent reconnect nonregression and new-agent reset. Direct GET isolation and callback-stop/custodian cleanup remain regression protected.

## Controlled edge process death

Twenty-five cycles rotate idle, after admitted response, observed Pending/executing, observed terminal, and connected stream. An admitted response proves record creation, not exact effect timing at kill. Every cycle establishes a live Racket session, kills only its owned fixture, observes stream stale, restarts with a distinct injected agent ID, applies a fresh snapshot and surfaces the old epoch. Server counts show no automatic command replay; deliberate old-agent POST returns 409 with zero replacement starts. Injection proves protocol epoch handling, not secure production ID generation/systemd boot or crash-safe hardware. Temporary processes/sockets/directories have startup/shutdown/outer deadlines and finalizers.

## Dependencies and boundaries

The declared `http-easy-lib` 0.11.1, `resource-pool-lib` 0.6 and `actor-lib` 0.3 fixed sources and Racket 9.1/flake lock realize the mandatory private decoder/attempt-count/privacy changes. Nix patch/substitution failure is fatal. No global package install is allowed. The patch is first-party trusted transport code for qualification purposes; alteration requires rerunning A-008/A-009/A-012 and relevant gates.

Static screens constrain workspace/dependency direction, unsafe policy, seven routes, no TCP/raw/payment/SQLite channels, Flutter authority, optional fixture and opt-in Racket composition. They scan complete Rust files: an inline test module must not hide later production items. Isolated source mutations prove rejection of TCP/SQLite/admin additions and direct Flutter command calls. Test-only hits require explicit classification. These are lexical tripwires, not complete formal security proofs.

Ignored logs/databases/socket state is local; source filtering must remain narrow. The source-filter helper snapshots tracked and nonignored new files without staging, so ignored live daemon sockets never reach Nix's earlier path ingestion. An isolated read-only Git worktree view proves changed tracked bytes and new `.rkt`/`.rs`/`.md` source are included; logs, DB/build output, fake secret-like markers and a live UDS are excluded; the actual index remains byte-for-byte unchanged. The harness then injects synthetic regular ignored markers to test the actual unchanged Nix filter, compares Core/terminal derivations, and separately verifies exclusion of an owned live UDS. Source symlinks/submodules require explicit classification rather than following arbitrary local targets. Full production configuration/discovery, hardware observations, deployed identity/SELinux and whole-M8 Tier A remain explicit residuals.
