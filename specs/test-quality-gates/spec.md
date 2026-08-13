# Spec — test-quality-gates

> Follow-on to v2.15.0/v2.16.0 (harness-enforced, per-batch P9 red step: `bin/tdd-red.sh` +
> `bin/check-tdd.sh`). Those made "a test was written first and seen to fail" a git fact — a **floor**.
> They do not judge whether the test asserts the *right* behavior, nor how much of the batch's code is
> covered. This milestone adds three gates that raise that ceiling, each a `verify-batch` gate in the
> same marker-gated, git-grounded, project-declared-command style as `check-tdd`/`quality-gate`.
> Delivered via `/deliver` (batch-by-batch).

## Overview

Three new harness gates, ordered by value-per-cost:

1. **F1 — red-touches-tests.** Strengthen the red step so the recorded red is caused by **actual
   test-file changes**, not an empty (`--allow-empty`) commit or an unrelated pre-existing failure.
   Closes the narrow forge the current red gate leaves open. Cheap; hardens an existing gate.
2. **F2 — diff-coverage threshold.** After green, require the batch's **changed non-doc lines** to be
   covered ≥ a threshold. Catches "one trivial test for 200 lines" — enforces *breadth*. Medium cost;
   needs project coverage tooling.
3. **F3 — mutation testing.** Mutate the batch's changed code and require a mutation score ≥ threshold —
   the only automated judge of **assertion strength** ("does the test actually check anything"). High
   cost; **opt-in / advisory by default**, scoped to changed files.

All three: marker-gated ⇒ in-session (CI has no marker), graceful **skip + warn** when the project
declares no tooling (never a false block), configurable thresholds, `--self-test`, `shellcheck` clean.
None of them judges *correctness of intent* — that stays with `test-designer`/`qa-test-engineer`/review
(stated as an accepted limit, per the floor-vs-ceiling framing).

## In scope

- **F1 — `red-touches-tests`** (extends `bin/check-tdd.sh`, and `bin/tdd-red.sh`):
  - `tdd-red.sh` refuses to record a red whose commit/window contains **no test-file change** (rejects
    `--allow-empty` and reds caused by non-test changes).
  - `check-tdd.sh` verifies, per batch, that the red_sha's window (batch-window-start … red_sha) changed
    ≥1 **test-path** file. Test-path detection: a default glob set + optional `TestGlobs:` in AGENTS.md.
- **F2 — `bin/check-diff-coverage.sh`** (new `verify-batch` gate):
  - Reads `Coverage:` (command producing a machine-readable per-line coverage report) and
    `CoverageThreshold:` (percent; default from a documented constant) from AGENTS.md.
  - Computes the batch's changed non-doc lines (git diff over the batch range — reuse the ledger's
    per-batch range / `code_since_baseline` window), intersects with covered lines, and **fails** if
    `covered ÷ changed` < threshold. Absent `Coverage:` ⇒ skip + warn.
- **F3 — `bin/check-mutation.sh`** (new `verify-batch` gate, **default advisory/opt-in**):
  - Reads `Mutation:` (command running the project's mutation tool scoped to changed files, emitting a
    parseable score / surviving-mutant count) and `MutationThreshold:` from AGENTS.md.
  - **Enabled** (a `Mutation:` command present *and* `MutationMode: enforce`) ⇒ hard gate: fails if score
    < threshold. Default (`Mutation:` absent, or `MutationMode: advisory`) ⇒ runs if present and reports,
    but does not block; absent ⇒ skip.
- Wire F1 into the existing `check-tdd` gate; add F2 and F3 to `bin/verify-batch.sh`'s gate list.
- Extend the AGENTS.md contract ([references/agents-md-contract.md](../../references/agents-md-contract.md))
  with `TestGlobs`, `Coverage`, `CoverageThreshold`, `Mutation`, `MutationThreshold`, `MutationMode`.
- Docs: [references/tdd.md](../../references/tdd.md), [references/enforcement.md](../../references/enforcement.md);
  version bump per P8.

## Out of scope

- **Judging correctness of the assertion / right behavior** — no gate decides a test checks the *intended*
  thing. F3 raises the floor on assertion *strength* (mutants killed), not intent. Intent stays with
  `test-designer` (tests from acceptance criteria) and review. Stated, logged, not proven.
- **Providing the coverage/mutation tooling.** The framework declares *contracts* (`Coverage:`/`Mutation:`
  commands); the target project supplies the runners (coverage.py, lcov, Stryker, mutmut, PIT,
  cargo-mutants, …). No tooling ⇒ graceful skip, never a false block — consistent with `quality-gate`.
- **Language-specific coverage/mutation parsers baked in.** F2/F3 consume a **normalized** output the
  project's command emits (see OQ-2/OQ-4), not N bespoke format parsers.
- **CI enforcement** — like all marker-gated gates, these bite in-session; CI has no `.runs/` marker.
- Changing the delivery/closure gates (`check-delivery`, `verify-batch` stamping) — unchanged.

## User stories

- **US1** (F1) — As the founder, I want a batch's red step **rejected if it changed no test file**, so an
  empty or unrelated red can't satisfy "tests first."
- **US2** (F2) — As the founder, I want a batch whose changed code is **under-covered** to fail, so "one
  trivial test for a big change" is caught, not just "a test exists."
- **US3** (F3) — As the founder, I want an **opt-in** mutation gate that fails when tests don't kill
  mutants of the batch's code, so I can enforce assertion strength on hot modules without paying the cost
  everywhere.
- **US4** — As an engineer, I want every gate to **skip with a clear warning** when my project declares no
  coverage/mutation tooling, so the framework never false-blocks a project that hasn't opted in.

## Acceptance criteria

- **AC-1** (US1, F1) — `tdd-red.sh` refuses (non-zero, no record) to stamp a red whose window changed no
  test-path file, incl. an `--allow-empty` red. *(Fixture: empty red / non-test-only red → refused.)*
- **AC-2** (US1, F1) — `check-tdd.sh` fails a code batch whose red_sha window contains no test-path file
  change, even if a red record exists. *(Fixture: red_sha = empty commit → fail; red_sha touching a test
  file → pass.)* Test-path set = documented default ∪ `TestGlobs:`.
- **AC-3** (US2, F2) — `check-diff-coverage.sh`: with a `Coverage:` command and `CoverageThreshold: N`, a
  batch whose changed non-doc lines are covered `< N%` → exit 1; `≥ N%` → exit 0. *(Fixtures at both
  sides of the threshold using a stub coverage command.)*
- **AC-4** (US4, F2) — no `Coverage:` command in AGENTS.md → exit 0 with a WARN ("diff-coverage
  unenforceable"). Never a false block.
- **AC-5** (US3, F3) — `check-mutation.sh` with `Mutation:` present and `MutationMode: enforce` +
  `MutationThreshold: N`: score `< N` → exit 1; `≥ N` → exit 0. `MutationMode: advisory` (or absent mode)
  → runs/reports but exit 0. No `Mutation:` command → skip (exit 0). *(Fixtures via a stub mutation command.)*
- **AC-6** — all three gates are **marker-gated**: no active `intends_code` marker ⇒ exit 0 (skip),
  identical to `check-tdd`/`check-delivery`. *(Fixture: marker-less → skip.)*
- **AC-7** — each new/changed script ships `--self-test`; `check-gate-integrity.sh` confirms none is
  green-by-skip and each gate demonstrably fires (P10 declared ⇒ exercised); `shellcheck --severity=error
  bin/*.sh` clean; the existing `check-tdd`/`check-delivery`/`delivery-stop-hook`/`select-pipeline`
  self-tests still pass (no regression).
- **AC-8** — F2 and F3 are wired into `verify-batch.sh`; F1 is enforced inside `check-tdd.sh`. Running
  `verify-batch.sh` on a project with none of the tooling still passes (all three skip+warn).

## Pre-resolutions (from this conversation — founder rulings)

- **F1** — "Floor, not ceiling." These gates eliminate the worst failures (no tests, fake tests,
  under-coverage, vacuous asserts) mechanically; they do **not** certify a good test suite. Correctness of
  intent stays with review. This framing is baked into scope + Out-of-scope, not re-litigated.
- **F2** — Value-per-cost order is **F1 (cheap) → F2 (medium) → F3 (expensive)**. F3 is **opt-in/advisory
  by default** because per-batch mutation is costly; enforce it only where declared (hot modules).
- **F3** — Never false-block: any project that hasn't declared the tooling gets a **skip + warn**, exactly
  like `quality-gate` with no `Typecheck:`. Enforcement is opt-in by project contract.
- **F4** — Same substrate as the delivery guard: `verify-batch` gates, marker-gated, git-grounded,
  self-tested, portable (no bundled runtime — P7).

## Open questions (for `/deliver` Step 3 — clarify) — RESOLVED

- **OQ-1** (F1) — Default test-path globs. RECOMMENDED: `*_test.*`, `*.test.*`, `test_*.*`, `*.spec.*`,
  `*Test.*`, and any path under `test/`, `tests/`, `spec/`, `__tests__/`; extensible via `TestGlobs:`.
  · web-verify: no.
  - **[x] Resolution:** adopt the recommended set, plus `*_spec.rb` (Ruby/RSpec convention). Detection =
    basename glob **or** any path segment ∈ {`test`,`tests`,`spec`,`__tests__`}. `TestGlobs:` in AGENTS.md
    (space/comma-separated globs) **extends** (never replaces) the default set, so a project can't
    accidentally shrink coverage of the check.
- **OQ-2** (F2) — Coverage input contract. RECOMMENDED: the project's `Coverage:` command emits **LCOV**
  (broadest ecosystem support) to stdout or a named file; F2 parses LCOV + the git diff. Alternative:
  require a `diff-cover`-style tool and consume its exit/JSON. · web-verify: yes.
  - **[x] Resolution (web-verified, no drift):** **LCOV**. Confirmed the stable tracefile grammar — `SF:<path>`
    opens a file section, `DA:<line>,<exec_count>[,<checksum>]` per instrumented line (count `0` = uncovered,
    `>0` = covered), `LF`/`LH` summaries, `end_of_record` closes the section
    ([lcov man page](https://manpages.debian.org/unstable/lcov/lcov.1.en.html)). F2 parses LCOV that the
    `Coverage:` command emits (stdout or a `CoverageFile:` path), maps `SF:`→repo-relative path, collects
    `DA` lines with count `>0` as the covered set, and intersects with the batch's changed non-doc lines.
    The `diff-cover` alternative is rejected as an *extra* dependency the project would have to install — LCOV
    is emitted natively by coverage.py/lcov/nyc/tarpaulin, so it needs no bridge tool.
- **OQ-3** (F2) — Default `CoverageThreshold` when declared-but-unspecified. RECOMMENDED: 80% on changed
  lines. · web-verify: no.
  - **[x] Resolution:** `80` (percent, on changed non-doc lines), as a documented constant
    `DEFAULT_COVERAGE_THRESHOLD=80` in the script. Overridable via `CoverageThreshold: N` in AGENTS.md.
- **OQ-4** (F3) — Mutation output contract + tools. RECOMMENDED: `Mutation:` command emits a final
  `mutation_score: <float>` (or killed/total) line F3 greps; document adapters for Stryker (JS/TS), mutmut
  (Py), PIT (JVM), cargo-mutants (Rust). · web-verify: yes.
  - **[x] Resolution (web-verified, no drift):** normalized score line. Confirmed all four tools expose
    `killed`/`total` and a percentage score = killed÷total×100 (Stryker mutation-score metric, mutmut, PIT,
    cargo-mutants) ([Stryker mutant states & metrics](https://stryker-mutator.io/docs/mutation-testing-elements/mutant-states-and-metrics/)).
    F3 greps the **last** line matching `mutation_score:[[:space:]]*<float>` (0–100) **or** `killed:<k>` +
    `total:<t>` (score = k÷t×100). The project's `Mutation:` command is responsible for emitting one such
    line (adapters documented per tool, **not** parsed natively — R1: one contract, no per-tool parsers).
- **OQ-5** (F3) — Granularity. RECOMMENDED: per-batch scoped to changed files when `enforce`; a
  milestone-level full run is a separate future gate. · web-verify: no.
  - **[x] Resolution:** per-batch, scoped to the batch's changed files. Milestone-level full mutation is a
    documented future gate, out of scope here.
- **OQ-6** — Should F2/F3 be pipeline-gated (e.g., F3 enforce only in `full`)? RECOMMENDED: gate by the
  AGENTS.md contract, not the pipeline — `MutationMode: enforce` is the switch; document that `single-thread`
  users typically leave it advisory. · web-verify: no.
  - **[x] Resolution:** gate by the AGENTS.md contract (`MutationMode: enforce|advisory`), not the pipeline.
    F2/F3 read only AGENTS.md + the marker; they do not inspect the pipeline tier.

## Principles compliance matrix

| AC | Constitution clause | Verification approach |
|---|---|---|
| AC-1, AC-2 | **P9, P11** (red→green by evidence; ground in mechanism) | red tied to git-provable test-file changes, not an empty/self-declared commit |
| AC-3, AC-5 | **P9, P10** (verify by evidence; fail-closed) | coverage/mutation thresholds enforced from real tool output, block below bar |
| AC-4, AC-6, AC-8 | **P10, P6** (declared ⇒ exercised; report truth) | graceful skip **warns** (no silent cap); marker-gated skip identical to peers |
| AC-5 (advisory) | **P1, P6** (right-size; no silent drop) | expensive gate opt-in by contract; advisory runs are reported, not hidden |
| AC-7 | **P8, P10** (versioned gate; declared ⇒ exercised) | self-tests + gate-integrity + shellcheck; no regression on existing gates |

## Risks

| # | Risk | L | I | Mitigation |
|---|---|---|---|---|
| R1 | Coverage/mutation format sprawl (per-language parsers) blows up scope | H | M | Consume ONE normalized contract (LCOV / a `score:` line) the project's command emits; adapters are docs, not code (OQ-2/OQ-4) |
| R2 | Per-batch mutation is too slow → people disable everything | H | M | F3 opt-in/advisory by default, scoped to changed files; never on unless `MutationMode: enforce` (F2 pre-resolution) |
| R3 | False blocks on projects without tooling erode trust | M | H | Hard rule: absent command ⇒ skip + WARN, never fail (AC-4); mirrors `quality-gate` |
| R4 | F1 test-glob set misses a project's convention → false "no test changed" | M | M | Extensible `TestGlobs:`; default set covers the common ecosystems (OQ-1); skip+warn if unresolved rather than hard-fail on ambiguity |
| R5 | Gates give false confidence ("we have coverage+mutation ⇒ tests are good") | M | M | Out-of-scope + docs state plainly: floor not ceiling; intent stays with `test-designer`/review |

## Dependencies

- v2.15.0/v2.16.0 artifacts: [`bin/tdd-red.sh`](../../bin/tdd-red.sh), [`bin/check-tdd.sh`](../../bin/check-tdd.sh),
  [`bin/delivery-lib.sh`](../../bin/delivery-lib.sh) (`resolve_marker`, `code_since_baseline`, field
  extractors, `shas_of_line`), [`bin/verify-batch.sh`](../../bin/verify-batch.sh) gate list,
  [`bin/quality-gate.sh`](../../bin/quality-gate.sh) (the `AGENTS.md` `Label:` `extract()` convention).
- AGENTS.md contract ([references/agents-md-contract.md](../../references/agents-md-contract.md)) — new fields.
- Constitution **P9/P10/P6/P1** as governing invariants; **P8** version-bump gate; **P7** (no bundled runtime —
  tooling stays project-side).
- Delivery: this milestone is built via `/deliver` (recommended batch order F1 → F2 → F3; F3 last as the
  heaviest and advisory-by-default).
