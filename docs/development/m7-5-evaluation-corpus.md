# M7.5 evaluation corpus

This fixed corpus compares pre/post workflow efficiency **without sacrificing
correctness**. CP1 results live in [the baseline](m7-5-baseline.md); post-change
results belong to 7.5.8, not this file. A specification is not execution evidence.

## Exact scenario prompts

### A — Small Racket/local repository question

> Locate where the production SQLite connection policy establishes WAL mode and `synchronous=FULL`, identify the focused tests that protect that policy, and summarize the authority boundary involved. Do not modify any file.

### B — Flutter semantic question

> Trace how a 401 encountered while an exact transaction command is pending leads the Flutter terminal back to the locked state while preserving the same persisted command for retry after reauthentication. Identify the principal Dart symbols/files and the focused tests protecting the behavior. Do not modify any file.

### C — Cross-cutting security question

> Trace how a root PIN reset prevents a request authenticated under the old credential revision from committing a fresh transaction mutation while still allowing a later valid session for the same operator to recover an already-durable exact command. Identify the authoritative checks and tests across the relevant layers. Do not modify any file.

### D — Version-sensitive external documentation

> For the exact Dart/Flutter SDK currently supplied by this project's development environment, determine from current official upstream documentation how its official MCP server is invoked/configured for Codex and identify any relevant roots/version/experimental-status caveats. Do not configure it.

### E — Bounded long-running process test

> Run the existing focused process-crash campaign through the project interface: `just crash-m6 3`. Do not restart it merely because it is quiet. Use the Codex session's normal current behavior for observing it. Record command started, final status, wall-clock duration, number of background polls, number of user-visible "still running" style updates, whether any poll provided new information, and whether the command was unnecessarily restarted. This is not physical power-loss evidence.

## Metric definitions

| Metric | Counting rule |
| --- | --- |
| Unique repository files read | Actual files whose content the agent substantially inspects; partial substantive reads count once per scenario. Exclude filenames-only searches, directory listings, generated metadata and indirect file reads by a launched test |
| Search/shell calls | Each meaningful shell/search tool invocation for that scenario, including failed path guesses. Multiple commands in one shell invocation count as one; retain the command manifest so batching is visible |
| MCP calls | Actual calls, grouped by provider; record each of Dart/Flutter, codebase-memory, Context7 and DCM explicitly, plus other providers if used. CLI registration queries are shell calls, not MCP tool executions |
| External documentation calls | Each external search/retrieval tool invocation used for documentation. A batched retrieval counts as one; record pages/redirects and failed retrievals. Record unrelated external discovery separately |
| Tests started | Every actual test command started. Identifying/reading a test is not running it. A–D normally require zero tests unless genuinely needed |
| Long-job poll | Every explicit follow-up call made only to observe an already-running job. Exclude initial launch; record which polls add information |
| User-visible still-running updates | Progress messages specifically announcing that the job continues, excluding launch and completion messages |
| Elapsed time | From beginning scenario work to source-verified answer/completion; record clock/method, precision and exclusions. Host observations, not universal performance guarantees |
| Context/token usage | Exact trustworthy exposed usage only; otherwise literal `unavailable`. Never estimate tokens from bytes, lines, elapsed time or partial tool-output counts |
| Correctness | Verified chain of relevant source/official docs, protecting tests identified, and honest caveats. Failed/blocked/unavailable is not passed |

## Execution protocol

1. Verify committed baseline, branch/worktree and project environment; record
   architecture, SDK/CLI versions, selected profile if knowable and capability
   limitations. Do not silently change them to improve the sample.
2. Run A–E once in the given order with current guidance naturally. Do not read
   irrelevant files, invoke every provider, issue duplicate searches, poll for
   metrics, or launch nested/recursive Codex sessions. General inventory is
   separate from per-scenario counters; disclose prior/warm context.
3. Record scenario boundaries, commands, substantive files read, provider calls,
   retrieval routes, test commands and elapsed time. Counters/bookkeeping are
   administrative, not repository-search calls. Do not conceal unsuccessful
   discovery attempts or substitute anticipated test results.
4. For A–C, verify the actual authoritative code and relevant tests. Explain
   boundaries, not just filenames. In C distinguish fresh mutation authorization
   from historical durable outcome recovery. No source changes are permitted.
5. For D, establish the installed SDK first, then use current official upstream
   documentation. Record redirects, documentation/SDK drift, network escalation
   or blocking, duplicated searches and unresolved roots/version semantics.
   Do not configure a server or widen permissions to make lookup succeed.
6. For E, start exactly `just crash-m6 3`, retain the normal current observation
   behavior, record the actual exit and duration, and never restart a quiet job
   without evidence of failure. Count observation calls and updates explicitly.
   Keep process SIGKILL distinct from physical power-loss evidence.
7. Keep sanitized raw evidence under ignored `.local/m7.5/`; commit concise
   summaries only. Never dump credential files or environment values. Names-only
   inventory, if needed, is ignored local evidence, not committed content.
8. In 7.5.8 repeat the same prompts/counting rules; identify source/tool/profile
   changes and comparison limits. Correctness and privacy outrank lower counts.

## CP1 sample limitations

- Run in the existing ongoing Codex conversation after a repository/tool
  inventory, not five isolated cold-context sessions. Previous milestone context
  and cache warmth can influence discovery/runtime. No fresh nested sessions
  were manufactured to claim isolation.
- A–D used host `Date.now()` boundary measurements including reasoning and tool
  latency, rounded in the summary; E used GNU `/usr/bin/time` (56.78 s) around
  the canonical command. Timing bookkeeping is excluded from shell counts.
- File counts are manually classified against the actual read manifest, not
  every search hit or every filesystem access performed by a child process.
- All four intended MCPs had zero actual calls. The SDK includes Dart MCP help,
  but none was registered. Hosted web/app tools are separate from manual
  registration; no missing-provider health was inferred from successful web use.
- D used five web documentation calls and one separate external plugin-catalog
  discovery. The latter unexpectedly emitted a large catalog; it is not a
  documentation/MCP call or an intentionally inflated benchmark step.
- Shell invocations used the session's approved escalation route. No profile,
  permission/domain list, network policy or polling setting was modified. Active
  profile/managed-layer provenance could not be fully established; preserve that
  limitation in later comparisons rather than assuming the file named `work`
  determines all effective behavior.
- No exact total context/token metric was exposed: `unavailable` throughout.
  No claim is made about quota saved by the observed tool counts.

CP1 changed only its two documentation artifacts after observations. It did not
implement the optimization whose effects this corpus will later evaluate.
