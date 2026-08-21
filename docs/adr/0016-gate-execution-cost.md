# ADR-0016 — Gate execution cost: cache, reuse, and parallel review

- Status: accepted
- Date: 2026-08-21
- Milestone: v2.30.0 (issue #23)
- Relates: ADR-0015 (no gate blocks on its own fragility) — this is its economic twin.

## Context

A `full` delivery of one spec took **203 minutes** of wall-clock, **97** of them inside a single
review-and-closure gap. The delivery was *healthy* — red-first held, the four roles ran per batch, all
15 gates closed green with **no waiver**. The cost was not a defect in any gate; it was the harness
**re-running identical work** and **serialising work with no data dependency**.

Two structural causes:

1. `verify-batch` re-runs every gate on every attempt (no caching anywhere), and the first attempt
   usually fails on some *other* gate. A project that honestly declares `Coverage:` and
   `Mutation: … MutationMode: enforce` therefore pays a full Stryker run, plus a second instrumented
   suite run, **again on each retry with a byte-identical diff**.
2. `deliver.md` chained the four review roles ("Then the … Then the …"), so four subagents at
   3.6–11.8 min each cost 4× the slowest one's latency.

There was a perverse incentive in (1): the run did the right thing — declared real tooling instead of
downgrading `risk_rank` or taking a bogus waiver — and was punished with minutes per retry. Honest
enforcement must not be the expensive path, or the next run will choose the bypass.

## Decision

**1. Cache expensive gate verdicts, keyed on everything that can change the answer.**
`check-mutation` and `check-diff-coverage` reuse their own previous output when the key matches: gate
id + the declared command string + the committed window + uncommitted tracked changes + the *content*
of every dirty/untracked non-ignored path. An empty key — no marker (CI), not a repo, no baseline, or a
pathologically dirty tree — means **execute**. The parsed verdict is always re-derived from the cached
payload, so a cached run and a fresh run cannot drift.

**2. `CoverageFrom: test` — one instrumented run serves both gates.** An optional contract field
declaring that `Test:` already emits the `CoverageFile:` artifact; diff-coverage then reads it and runs
no coverage command.

**3. The four review roles fan out in parallel**, and re-verification after remediation is scoped to the
fix diff rather than the whole batch window.

## Consequences

- **Fail-closed is the invariant, not an aspiration.** A cache miss costs time; a stale hit costs
  correctness — the ADR-0015 class of defect. Every ambiguity resolves toward re-running, and reuse
  fails *loud* (missing artifact, absent `CoverageFile:`, or any changed source newer than the
  artifact) rather than skipping.
- **Contract changes are additive**, per the Claude Code plugin docs ("Claude Code ignores top-level
  fields it does not recognize"): omitting `CoverageFrom:` is byte-for-byte the old behaviour, and an
  *unrecognised* value falls back to running `Coverage:` — the plugin declares, it does not infer.
  No tool is bundled and no dependency added.
- **No gate was weakened.** Every change removes duplicate execution or serialisation, never a check.
- Ordering was verified before parallelising: `roles_covered` is a set-union and
  `reviewer_dispatch_count` is a count, so neither depends on dispatch order.
- Honest caveat: two review roles execute test suites, so on a CPU-bound machine expect contention
  rather than a clean 4×; the saving is in reasoning time, which dominates.
- A fail-open was found *in this work* and closed: the first cut of the cache keyed on git-tracked
  state only, and this repo's own `check-mutation --self-test` caught a stale hit for a tool reading an
  untracked fixture. Untracked content is now in the key (`AC-C7`).
