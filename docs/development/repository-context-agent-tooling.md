# Repository context agent tooling

CP7.5.5 qualifies two optional specialists on Linux arm64, Codex 0.157.1,
at committed baseline `fa3a4cab488ed6b24c77da526fcc5708fe1f0c1f`.
Source, tests, ADRs, and acceptance evidence remain authoritative. A graph
narrows locations; external documentation establishes upstream behavior only.
Neither provider is a project gate. See the [workflow](codex-workflow.md) and
the already-qualified [Dart/DCM lane](dart-flutter-agent-tooling.md).

## codebase-memory: ownership and installation

The official release API identified **v0.11.0** as latest stable, not a
prerelease. The [exact release](https://github.com/DeusData/codebase-memory-mcp/releases/tag/v0.11.0)
provided `codebase-memory-mcp-linux-arm64.tar.gz`; its SHA-256 matched the
published `checksums.txt`:

```text
c0e46c87cf37e35f1ac0bd9cc7e1d8b0ca4ef40034e1008805d709fa52a4e38a
```

The native executable reports **0.11.0**. Binary and license notices were
manually placed in `~/.local/lib/codebase-memory-mcp/0.11.0/`, with a user-bin
symlink. No Nix, application, CI, shell-startup, or appliance dependency changed.
This is user-owned developer tooling, not a floating automatic installation.

The inspected installer delegates to account-wide activation and agent
configuration code. Its skip-config mode omits agent edits, but we did not run
either installer mode: manual placement avoids maintenance/configuration side
effects altogether. No updater script, Codex skills/plugin, managed hooks,
global AGENTS pointer, or background service installation was adopted. Checks
found no tool-named skills/hooks or global guidance pointer.

For upgrades, deliberately select an exact official release, verify its
checksum, inspect side effects, and repeat architecture/cache/index/coverage,
read-tool, freshness, and fresh-Codex checks. Do not run an installer or updater
as an incidental repair.

## Local state, background policy, and MCP exposure

The default cache is `~/.cache/codebase-memory-mcp`. Restricted execution failed
there; the qualified supported `CBM_CACHE_DIR` redirects derived state to
`<repo>/.local/codex/codebase-memory/`. No filesystem permission profile widened.

Two additional boundaries were observed: restricted shell execution blocks
Unix-domain sockets, and approved execution rejected this container's default
`/tmp` rendezvous parent. The release's supported `CBM_RUNTIME_DIR` selects
`<repo>/.local/cbm-run/`, created with mode 0700. Its endpoint still performs
the upstream ownership/ancestry checks. This checkout's socket path is 101 bytes;
longer checkout paths may exceed Unix socket limits and require another supported
short private location, not disabled safety checks. Explicit CLI maintenance
needed approval in this environment; fresh Codex's MCP launcher worked.

Qualified work-only configuration, with `<repo>` replaced locally:

```toml
[mcp_servers.codebase_memory]
command = "codebase-memory-mcp"
args = ["--tool-profile=analysis"]
cwd = "<repo>"
enabled_tools = [
  "search_graph", "query_graph", "trace_path", "get_graph_schema",
  "get_architecture", "index_status", "check_index_coverage", "detect_changes",
]

[mcp_servers.codebase_memory.env]
CBM_CACHE_DIR = "<repo>/.local/codex/codebase-memory"
CBM_RUNTIME_DIR = "<repo>/.local/cbm-run"
```

The analysis inventory exposed 13 tools; the configured eight all advertise
`readOnlyHint=true`. Index creation/refresh stays explicit CLI maintenance.
Source-snippet/text-search and graph-comparison tools were not needed in the
allowlist. `get_file_outline` worked through CLI and its inspected handler reads
the store, but its advertised hints are non-read-only/destructive; it remains
excluded from the MCP allowlist pending upstream clarification. Index deletion,
ADR mutation, trace ingestion, configuration/install/update/UI controls are not
enabled for routine agent retrieval. An upstream ADR-creation hint is not
permission to replace this repository's ADR architecture.

Settings live in the selected cache's `_config.db`/UI config, not repository
policy; they apply to all projects using that cache, not individually per project.
Installed defaults were auto-index false, auto-watch true, watcher true,
and effective UI true. Supported config commands explicitly set all four off:

```sh
export CBM_CACHE_DIR="$PWD/.local/codex/codebase-memory"
export CBM_RUNTIME_DIR="$PWD/.local/cbm-run"
codebase-memory-mcp config set auto_index false
codebase-memory-mcp config set auto_watch false
codebase-memory-mcp config set watcher_enabled false
codebase-memory-mcp config set ui_enabled false
codebase-memory-mcp config list
```

Use the same state paths for CLI and MCP. After daemon-read-once settings change,
close its clients and use the supported `daemon stop`; no permanent daemon was
started here. Session-managed coordination stops with its clients. No HTTP UI
listener on 9749 was observed. No home-grown watcher or polling wrapper exists.

## Index and language qualification

An explicit full index used:

```sh
codebase-memory-mcp cli --json index_repository \
  --repo-path "$PWD" --name grocery-pos-platform --mode full
```

At the clean baseline it produced **368 file records, 4,181 nodes, 12,469 edges**,
a **14,352,384-byte** graph DB, and **3,065,055 bytes** of existing indexed files
(including documentation/configuration, not an LOC measurement). Initial elapsed
time and indexing peak memory were not captured reliably; no vendor benchmark
or later fixture timing substitutes for those measurements.

The language panel reported Dart 57, Bash 26, C++ 5, YAML 3, C 3, but omitted
Racket despite **164 `.rkt` file records** and successful Racket function queries.
Its language panel is incomplete, not evidence that Racket was unindexed.
Three files had partial parses, including actor-attribution storage; three
Racket test files had essentially unusable parses: catalog migration, database
migrations, and runtime tests. Coverage reports are best-effort, never completeness
proof. Read flagged files directly.

Existing [ignore rules](https://github.com/DeusData/codebase-memory-mcp/blob/v0.11.0/docs/cbmignore.md)
were sufficient: `.git`, `.direnv`, `.local`, Flutter `.dart_tool` and build
subtrees were excluded. The initial response reported eight excluded directories
and four deliberately unindexed files, with truncated directory samples. Graph
path inspection found no excluded subtree entries. The tracked `.env.example`
was intentionally indexed; `.env.local` is absent and Git ignores that name.
No secret file was opened and no exclusion of nonexistent contents is claimed.
No `.cbmignore` or repository graph artifact was necessary.

Racket definition locations for `operator-service-reset-pin`,
`fresh-actor-still-authorized?`, and `commit-transaction-command-outcome!` matched
source. Reset's outgoing relations correctly found credential rotation and its
grant-revocation helper; the fresh-actor check's caller was correctly identified
as `resolve-unused-command!`. The operator-service outline matched its declarations.
Test callers can appear as file/module-level nodes rather than named test cases;
indirect callbacks, SQL, and temporal writer guarantees require source inspection.
No incorrect definition hit was found in this sample; the parse gaps and incomplete
relations prohibit a blanket Racket-confidence claim.

Dart class discovery and an exact-qualified-name retry-method trace found the
controller and its three direct helper calls. An abbreviated class/method name
failed until its graph-qualified name was used. The method range covered only
its declaration line, not its body. This is useful repository topology, not Dart
semantic precision or proof of complete source ranges; use Dart MCP for that
distinct question and verify source regardless.

The reset/fresh-writer/durable-retry investigation used **six graph CLI queries**,
**seven grouped source/search shell invocations**, and **nine unique Racket
source/test files**. General installation/coverage diagnostics and the separate
Dart trial are outside those counts. Known CP1 symbols were reused; this is not
a cold-start or CP7.5.8 benchmark. No incorrect location led to a discarded source
file, but the graph cannot prove the critical ordering. Source confirmed revision
rotation, principal binding, final fresh-actor validation, and duplicate recovery
before fresh authorization. Protecting writer-race and reset-concurrency tests
were inspected, not executed. Counts are recorded in ignored local evidence.

## Freshness and trust

With watchers disabled, an ignored standalone Python fixture was indexed, then
its function renamed. `index_status` still said `ready`; search returned the old
function. `check_index_coverage` reported `metadata_changed`. Explicit re-indexing
returned the new function. No product file changed for this experiment.

Before relying on topology, inspect index status/root/coverage and local changes.
Use selected-path coverage and source verification; timestamp/`ready` alone is
not freshness, and the tested status result did not carry an indexed commit.
For relevant drift, repeat the explicit index command with the same root/name.
Queries can silently serve stale relations. Record the indexed worktree separately;
do not equate Git HEAD alone with uncommitted source. Documentation edits after
the baseline index are not retroactively part of that graph.

The [release README](https://github.com/DeusData/codebase-memory-mcp/blob/v0.11.0/README.md)
describes local indexing/querying with no API key, telemetry, or automatic update
check. Installation downloads used approved network access; no runtime source
upload or update operation was requested. This was not packet interception.
Normal Codex model traffic remains external: local graph storage does not make
the whole agent workflow on-device. The graph itself contains derived source
information and must remain ignored/local.

## Context7: hosted public documentation only

The current [Free plan](https://context7.com/plans) advertises **$0, 1,000 calls
per month**, public sources and OAuth, without private-repository parsing. No
paid plan/billing action was taken. Account dashboard usage was not inspected;
remaining allowance and account-wide usage are unknown. CP5 made **three MCP
documentation calls**: resolution plus retrieval in the trial, then one retrieval
reusing the same ID in the final smoke. This is observed tool consumption, not
an independently reconciled billing total.

The [official OAuth endpoint](https://context7.com/docs/howto/oauth) returned 401
with protected-resource discovery; authorization metadata supported PKCE S256.
The developer privately completed `codex --profile work mcp login context7`.
No static secret/header or Node/CLI/plugin/skill was installed:

```toml
[mcp_servers.context7]
url = "https://mcp.context7.com/mcp/oauth"
auth = "oauth"
enabled_tools = ["resolve-library-id", "query-docs"]
```

Codex reported OAuth authentication. Its automatic store used a file with mode
0600; no active Secret Service owner was observed in this session. Only file
existence/mode was inspected, never its contents. This is owner-restricted file
storage, not an OS-keyring claim or encrypted-at-rest assurance. No store setting
or unrelated profile value changed. The [Codex reference](https://learn.chatgpt.com/docs/config-file/config-reference)
documents supported store classes and tool allowlists.

The observed catalog contained those two read-oriented documentation tools, no
repository-management/write tool. Resolve once, reuse the library ID, and ask
only generic public upstream questions. Do not add Grocery POS as a source,
connect GitHub for its parsing, or send project source/internal identifiers,
credentials, uncommitted design, or implementation excerpts—even for a public
repository. No Grocery POS indexing/upload was requested.

The [privacy policy](https://context7.com/docs/security/data-privacy) identifies
formulated query, library ID/name, authentication and client/transport metadata
as transmitted data. Queries are stored for retrieval-quality work and may be
reranked by third-party LLM providers. It does not automatically receive the
whole conversation or source; that is not a safety guarantee if the agent puts
sensitive material into the query. Keep queries deliberately minimal. Hosted
MCP traffic is distinct from shell domain restrictions; the permanent shell
allowlist was unchanged.
Restricted `codex mcp list` reported Context7 authentication as `unknown`;
approved status inspection reported OAuth and the fresh retrievals succeeded.
Do not infer lost credentials from that restricted diagnostic alone.

### Version-sensitive usefulness and limits

The repository and installed package source both establish `http` **1.6.0**.
Two Context7 calls resolved `/websites/pub_dev_http` and retrieved generic
`Client.send`/streamed-response/client-close documentation. Catalog metadata
reported High source reputation, 507 snippets and score 79.14, but advertised no
exact 1.6.0 version ID. Returned URLs used `/latest/`: useful discovery, **not
version-exact evidence**. No redundant library resolution was made.

Official versioned API pages could not be retrieved by the browsing tool, so the
installed 1.6.0 package's `client.dart`, `base_request.dart`, and `io_client.dart`
provided the fallback. They establish streamed response handling, client cleanup
and undefined concurrent-close behavior, and automatic client cleanup for the
request convenience path. These are upstream facts, not a Grocery POS design
change. Never silently treat current/latest documentation as a pinned contract.
For remaining quota, use the private dashboard when needed rather than repeated
usage probes; necessary version-sensitive lookups still warrant intentional calls.

## Fresh-session integration and scope

The fresh work-profile smoke succeeded in **79.83 seconds** with exactly six
calls: one graph lookup, Dart root+analyzer, DCM root+Free metrics preview, and
one Context7 query. No shell exploration, tests, edits, or unrelated providers
were used. Graph root matched the repository, Dart returned no errors, and DCM
applied 22 metrics. Base/learn still list no MCP servers; work has exactly four.
The read-only coverage checker was subsequently added to the allowlist after
its CLI freshness qualification; profile parsing verified the final eight-tool
surface. No startup timeout or `required` setting was changed.

No server failure was observed in the successful smoke. Root-registration calls
took about 3.4 seconds for Dart and 3.5 seconds for DCM; these are not isolated
server-start measurements. First tool invocation was at 25.13 seconds; overall
time includes model/tool work, not just catalog initialization. Material startup
cost relative to CP4 was not established by these different tasks. Optional
failures must not become blockers for obvious local-source work.

User base/learn hashes remained unchanged, existing Dart/DCM blocks were preserved,
and work changes were limited to the two MCP blocks. No permission, approval,
model/reasoning, environment-policy, network-domain, production dependency,
product source, or historical evidence changed. Sanitized raw qualification
records live only under ignored `.local/m7.5/cp5/`.
