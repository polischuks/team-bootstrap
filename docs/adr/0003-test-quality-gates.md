# 0003 — Test-quality gates raise the floor mechanically; test *intent* stays with review

- **Status:** Accepted
- **Date:** 2026-08-13
- **Constitution clause(s):** P1, P6, P7, P9, P10, P11

## Context

v2.15.0/v2.16.0 made "a test was written first and *seen to fail*" a git fact — a per-batch red step
([`bin/check-tdd.sh`](../../bin/check-tdd.sh) — see the amendment below). That is a
**floor**: it proves a red happened, but not that the red was caused by a *test*, nor how much of the
batch's change the tests cover, nor whether the tests *assert* anything. Three narrow forges remained: a
red satisfied by an `--allow-empty` commit; "one trivial test for a 200-line change"; and vacuous tests
that run the code but assert nothing (coverage without kill).

## Decision

Add three marker-gated `verify-batch` gates, ordered by value-per-cost, each git-grounded, declared by an
AGENTS.md command, and **skip+warn when the project declares no tooling** (never a false block — parity
with `quality-gate` without `Typecheck:`):

1. **F1 red-touches-tests** — `tdd-red.sh` refuses a red whose committed change since baseline touched no
   test-path file (rejects `--allow-empty` and non-test-only reds; exit 4); `check-tdd.sh` requires each
   code batch's red window `<prev-code-tip‖baseline>..red_sha` to change ≥1 test path. Test-path set = a
   default glob set ∪ AGENTS.md `TestGlobs:` (extends, never shrinks).
2. **F2 diff-coverage** — the batch's changed non-doc lines must be covered ≥ `CoverageThreshold:`
   (default 80), from the project's LCOV, over the **same `current_batch_base` window the `code_delta`
   stamp uses** (one shared definition — `stamp_batch_closed` was refactored to call it, so F2 and the
   stamp cannot drift).
3. **F3 mutation** — mutate the changed code, require score ≥ `MutationThreshold:` (default 60).
   **Opt-in/advisory by default** (`MutationMode: enforce` to gate) because per-batch mutation is costly.

Format-normalization is pushed to the project's declared command: F2 consumes **one** contract (LCOV
`DA` lines), F3 **one** (`mutation_score:`/`killed:total:`). Adapters for the common tools are *docs*, not
per-language parsers baked into the framework (R1). All three are marker-gated ⇒ in-session (CI has no
`.runs/` marker), carry `--self-test`, and are `shellcheck`-clean (P8/P10).

## Alternatives considered

- **F2 via a `diff-cover`-style bridge tool** — rejected: an extra dependency the project must install;
  LCOV is emitted natively by the mainstream coverage tools, so F2 parses it directly.
- **F1 degrade-to-WARN for inline-test languages** (Rust `#[cfg(test)]`, doctests) — rejected as the
  default: it would reopen the empty-red forge. Instead the operator opts out by widening `TestGlobs:` to
  their source globs — advisory-by-contract, strict by default (Step-7 architecture review, major #2).
- **F2 `|measured|=0` → silent pass** — rejected (Step-7 major #3): a wholly-untested new module is
  omitted from LCOV entirely by common tools, so silent-pass would defeat the gate. It now **WARNs loudly**
  when there are changed non-doc lines but none are measured, and the `Coverage:` contract requires
  cover-all.
- **F3 enforce-by-pipeline (e.g. only in `full`)** — rejected: gated by the AGENTS.md contract
  (`MutationMode:`), not the pipeline tier (OQ-6) — the switch belongs with the project, not the run mode.

## Consequences

- The worst test failures (no test, fake red, under-coverage, vacuous asserts) are caught mechanically,
  per batch, in-session.
- **Accepted limit (the boundary of the guarantee):** none of these judges whether a test asserts the
  **intended** behavior — a wrong-but-passing-shape test can still clear F1–F3. Test *intent* stays with
  `test-designer` (tests from acceptance criteria), `qa-test-engineer`, and review — **stated, logged, not
  proven** (parity with `check-tdd`'s "wrong-but-failing test still counts", ADR-0002's honesty limits).
  This is the "floor, not ceiling" framing, baked into scope and `enforcement.md`.
- **Marker-scope:** like all marker-gated gates these bite in-session only (`.runs/` gitignored); a CI
  `verify-batch` run finds no marker and skips F1's per-batch check and F2/F3 entirely. The code-clean
  layers (orphans/architecture/gate-integrity) remain non-bypassable in CI regardless.
- **Edge (F3 `total:0`):** a batch with no mutable changed code yields `killed:0 total:0`; the gate
  passes-with-note rather than dividing by zero (would otherwise false-block under enforce).
- No constitution bump (implements P9/P10/P6/P1/P7); asset **2.16.0 → 2.17.0** (MINOR — additive, backward-
  compatible; every existing project and non-delivery session is unaffected).

---

## Amendment — 2026-08-26 (milestone 020, AC-29)

`bin/tdd-red.sh` is **deleted**. Nothing about this decision changes: the red step is still
harness-observed, still anchored to a git sha, still refuses to record a green suite. What changed is
that the observation no longer lives in a second script.

The finding it answers is Д2 Фаза 4: `/test` already drives the red — writes the failing test and
iterates — so a second script that *also* drove the suite duplicated it. The observation entry point
moved into `bin/check-tdd.sh` as `--record-red`, i.e. into the gate that consumes the record. One job
each: `/test` reaches red, `check-tdd --record-red` observes and records it, `check-tdd` verifies the
ordering at close.

**A re-run at close time was designed and rejected.** Having the gate locate the red commit in git and
re-run the suite against it in a detached worktree looks stronger — the gate would observe rather than
trust a record. It is not: a fresh worktree carries only tracked files, so in any project whose `Test:`
command needs `node_modules`, `.venv` or a vendor tree the suite cannot start and exits non-zero, which
the gate would read as a genuine red. That is a **false red**, the precise inversion of what P9 asks,
and it would fire hardest on mainstream projects. The observation has to happen where the dependencies
are: the working tree, at the moment the red exists.

