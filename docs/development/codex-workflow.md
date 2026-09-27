# Codex development workflow

This is conditional workflow context behind [AGENTS.md](../../AGENTS.md), not
an instruction to load every linked document for every task. The root file
carries the always-relevant constitution; read the sections here that help the
current work. This document changes guidance, not runtime or tool configuration.

## Cheapest trustworthy path

Choose the cheapest trustworthy context/tool path that can resolve the task.
Minimize unnecessary context, file reads, calls, duplicated analysis, test
executions, and polling while preserving correctness, security, source
verification, and human understanding. Fewest tokens or fastest output alone
is not the objective. Never invent token measurements or trade away verification
to improve counts.

For a small local change, `rg` → targeted source read → focused test is often
enough. A specialist tool is useful only if it resolves a real uncertainty or
narrows work that would otherwise be expensive.

## Context funnel

1. Identify the goal, scope, dangerous invariant, and expected area. If the
   relevant source is already obvious, inspect it and nearby tests/contracts.
2. Otherwise use narrow repository search or structural discovery to identify
   likely files/symbols. Prefer `rg`/`rg --files`; do not browse the whole tree.
3. Inspect authoritative source and relevant tests. Load architecture/ADR routes
   only when that boundary or decision is involved.
4. Use semantic/runtime tooling or external documentation only when it adds
   evidence the local inspection cannot provide. Do not invoke a provider merely
   because it exists.
5. Stop expanding context when the evidence resolves the task. Report conflicting
   or missing evidence instead of hiding it behind more tool output.

## Authority and evidence

Start with actual source and durable project contracts, then language/runtime
tooling, structural indexes, and external documentation as needed. These answer
different questions, not a universal ranking that lets one erase another:

- Source establishes Grocery POS implementation behavior.
- Tests establish expected/protected behavior; reading a test is not running it.
- ADRs establish accepted architectural rationale. Consult the
  [ADR index](../adr/README.md) before changing an architectural boundary.
- Acceptance ledgers establish what was actually qualified, on which tier and
  environment—not every behavior mentioned in a test plan.
- Language/runtime tools give semantic and execution evidence.
- Structural indexes locate dependencies and impact; verify their results in
  source, especially when stale or incomplete.
- External documentation establishes upstream behavior, not Grocery POS truth.

When source and documentation disagree, investigate and report the discrepancy.
Do not silently choose whichever makes the change easiest. Update affected
documentation with authorized behavior changes; record unrelated drift for its
own checkpoint. Structured tool output is still evidence to assess, not authority.

## Repository questions versus upstream questions

Resolve locally: where login throttling is stored, who authorizes shift close,
how command idempotency works, and who owns transaction totals. Begin with the
root context routes, targeted source, tests, and contracts.

Use current official upstream documentation when version sensitivity matters:
what the pinned Flutter SDK supports, whether a package API changed, or what
systemd/Nix/Flutter requires. Establish the relevant pinned version first.
Installed help and local runtime evidence can clarify the exact environment.
Do not send Grocery POS source to a documentation service merely to ask an
upstream question, regardless of whether the repository is public or private.

Before changing the Flutter ↔ Racket boundary, read the
[local API](../architecture/local-api.md). Prefer explicit commands and structured
errors; do not expose raw exceptions, duplicate backend semantics in Flutter,
or create a broad speculative API ahead of tested domain requirements.

## Provisional specialist routing

The four intended MCPs are **not configured yet**. The following is an intended
responsibility split, not a claim of installed or verified capabilities. Exact
installed/free-tier capabilities, trust boundaries, and ownership are qualified
in CP7.5.4/5. This document provides no installation or registration instructions.

| Substrate/provider | Intended responsibility |
| --- | --- |
| Native Codex + shell + `just` | Default repository exploration, edits, and project validation |
| Dart/Flutter MCP | Dart/Flutter semantics and analyzer/symbol/runtime/test assistance |
| DCM | Targeted Dart maintainability, metrics, and quality lens |
| codebase-memory | Structural repository navigation and impact narrowing |
| Context7 | Current external software documentation |

No fifth MCP is proposed. Optional tooling must not become a prerequisite for a
simple local question that existing tools can answer.

Do not ask several tools the same question without a reason:

- “Where does this behavior live?” → repository search, or future structural
  indexing if it helps narrow the location.
- “What does this Dart symbol mean?” → source and, if useful, future Dart MCP.
- “Is this Flutter code unusually complex?” → future DCM if qualified and useful.
- “What does current upstream documentation say?” → official documentation or
  future Context7 if qualified; Context7 is not required to answer today.

Cross-tool checks are justified by different dimensions or conflicting evidence,
not by automatically querying every provider after each answer.

## Small checkpoints and learning-first collaboration

Prefer pair-programming and teaching to wholesale subsystem generation. For
consequential or unfamiliar work, briefly explain:

- the affected invariant and important language/architecture concept;
- the main design choice and meaningful tradeoff/security implication;
- expected files and the smallest independently testable checkpoint;
- planned focused validation.

Then implement only the agreed scope. Explain why a new Racket, Dart/Flutter,
Rust, SQL, Nix, security, networking, or distributed-systems concept fits the
problem. Keep the developer able to explain important code and decisions.

For familiar local work, a short explanation is enough. Avoid ritual architecture
recaps, repetitive descriptions of established patterns, and unrelated tutorials.
The learning goal is understanding consequential decisions, not maximizing prose.
Keep each slice small enough for meaningful human review.

## TDD and proportional validation

For domain behavior, use TDD where practical:

1. Identify the expected invariant; write or update the smallest relevant test.
2. Observe the appropriate failure when useful, then implement the smallest
   correct behavior.
3. Run the focused test; refactor only once behavior is protected.
4. Widen validation according to blast radius and remaining uncertainty.

Use existing `just` recipes as the normal interface; `just --list` is the current
inventory, not a static command list in guidance. If a recipe exists, prefer it
to an equivalent undocumented command. Narrow test selection within a recipe's
underlying runner is appropriate when no recipe exposes that focus; explain the
selection rather than creating a parallel command surface.

The validation ladder is:

```text
edit
  → smallest focused relevant test/check
  → relevant subsystem tests
  → cross-process/integration tests when the boundary warrants them
  → just check when broadly ready
  → acceptance/qualification only when the task warrants that evidence
```

Tests expand with blast radius and confidence. Focused checks are development
evidence; `just check` is the broad readiness gate, unless scope-specific
documentation supplies a justified different or stronger gate. Documentation-only
checkpoints can use whitespace, link/path, privacy, and semantic checks when
their scope explicitly permits it. Do not run broad suites repeatedly between
tiny edits without a reason. Report unavailable validation and its consequence.

Understand a legitimate failing test: never weaken, delete, skip, or rewrite it
solely to pass. Do not add timeouts/retries to hide deterministic failures. If
the timeout itself is defective, preserve the narrower correctness bound: the
post-M7 crash-campaign fix enlarged only the outer campaign budget while keeping
each POS Core startup's 30-second readiness contract. See the
[integration guide](integration-testing.md) for the real-process boundary.

## Acceptance is evidence, not just a larger test suite

`just accept-m6` and `just accept-m7` are qualification/evidence campaigns, not
ordinary “more thorough” development commands. They publish execution evidence
and should run only when a task changes or qualifies those concerns. Preserve
historical records; do not regenerate them merely for unrelated edits.

Distinguish focused development tests, broad repository validation, deterministic
acceptance, booted-appliance qualification, physical hardware qualification, and
destructive/power evidence. A specification is not proof of execution. Never
turn `blocked`/`not_run` into `passed`, or infer booted/physical qualification
from emulated artifacts, widget tests, or process SIGKILL.

Use the [M6](../acceptance/m6/README.md) and
[M7](../acceptance/m7/README.md) records for their evidence doctrine and actual
qualification state. Destructive work requires explicit scope, suitable
disposable hardware, and its documented procedure—not a general test request.

## Long-running commands and progress

Start a known deterministic long-running command once. Observe it at a coarse
interval appropriate to expected duration and the active tool/session limits.
Do not restart a quiet job without evidence of failure or repeatedly announce
unchanged state. Preserve diagnostics and bounded failure contracts.

Meaningful observation/reporting triggers include completion, new diagnostic or
evidence, materially exceeded expected duration, required interaction, or failure.
Keep required user progress communication concise and substantive; do not narrate
every search/read/call or repeatedly restate the architecture.

CP1 Scenario E already used one poll, zero unchanged “still running” messages,
and zero unnecessary restarts. This is policy to preserve/generalize, not a
proven current polling defect. The
[historical baseline](m7-5-baseline.md) and
[evaluation corpus](m7-5-evaluation-corpus.md) remain unchanged for later comparison.
No shell polling wrappers, artificial sleep loops, or Codex polling settings are
introduced by this checkpoint.

## Tool-output and security discipline

Use narrow searches and supported output filters/ranges rather than large
catalogs or entire files when only one symbol/section is needed. Summarize large
outputs instead of echoing them back. CP1's unexpected oversized plugin catalog
illustrates the risk; it is not a reason to avoid necessary discovery.

Credentials never belong in prompts, committed configs, logs, agent output, or
baseline evidence. Do not expose PINs, password/credential verifiers, private
keys, bearer/approval capabilities or digests, prohibited payment data, raw
request bodies, or unsanitized secret-bearing device/exception output. Synthetic
privacy-sentinel tests may use deliberately fake values in isolated fixtures;
never derive such fixtures from production secrets or copy their payloads into
ordinary diagnostics or external queries.

Inspect environment names rather than values where possible; names-only raw
inventory belongs in ignored local evidence, not a committed environment dump.
External services receive only necessary non-secret context; use local tools
for Grocery POS questions. Hosted tools can have trust/network behavior outside
shell domain restrictions. Review MCP installation/configuration separately
before trusting it. Do not solve environment inheritance or change permissions
as an incidental workflow edit.

Do not add project-local Codex permission/network/profile settings casually:
CP1 established their potential to override selected user profiles and blur
work/learn separation. This checkpoint adds no configuration.

## Dependencies, documentation, and handoff

Before a meaningful dependency addition/replacement, explain its capability,
why existing project dependencies are insufficient, and its security/maintenance
cost. Keep the dependency surface small; do not update unrelated dependencies
in a focused change. Tool availability does not justify adding a production
dependency or runtime/cloud prerequisite.

Update affected behavior, architecture, and operational documentation with the
change. Record consequential architectural decisions in an ADR; do not silently
replace accepted rationale. Hand off the outcome, important evidence/limitations,
changed files, and human review points concisely.

The usual project cadence can be planning → Codex checkpoint implementation →
human/ChatGPT review → developer-signed commit → branch/PR review → squash merge.
This is not mandatory ceremony for every trivial correction and is never
authorization to operate Git. No commit, push, force-push, rebase, reset, merge,
history rewrite, or release creation without explicit instruction; preserve
unrelated work and do not stage merely for tooling. A Conventional Commit
suggestion, such as `docs(dev): route codex repository context`, is only a
suggestion.

## Future prompts and evaluation

Prefer checkpoint prompts organized around Goal, Scope, Key invariants, Expected
areas, Acceptance, and Non-goals. Retrieve additional context conditionally
through the root router instead of reproducing the entire project history.
Shorter prompts are not automatically better: keep safety-critical or easily
missed checkpoint-specific invariants explicit.

CP7.5.3 owns README/developer-interface and environment hygiene; CP7.5.4/5 own
specialist qualification. Do not fix those surfaces while changing context
architecture. CP7.5.8 repeats the fixed corpus to assess unnecessary work without
sacrificing correctness; lower tool counts or a shorter root file alone are not
evidence of better engineering.
