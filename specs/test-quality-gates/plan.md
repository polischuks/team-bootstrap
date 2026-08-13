# Plan — test-quality-gates

**Source spec:** [`spec.md`](spec.md) · **Constitution:** v1.0.1 (no bump) · **Asset:** 2.16.0 → **2.17.0** (MINOR)
**Shape:** focused enforcement milestone — 4 batches, single-track, `bin/*.sh` only. No data-model / API
surface (gates read AGENTS.md + git + the run marker). Ordered by value-per-cost: **F1 → F2 → F3 → docs**.

---

## 1. Principles compliance matrix (AC → clause → mechanism, file:fn)

| AC | Clause | Where enforced (mechanism, file:fn) |
|---|---|---|
| AC-1 empty / non-test red refused | P9, P11 | `tdd-red.sh` :: reject when the red-producing change (HEAD commit ∪ working tree ∪ index ∪ untracked) touches **no** test path (`is_test_path`) |
| AC-2 red window with no test-file change → fail | P9, P11 | `check-tdd.sh` :: per batch, `git diff --name-only <prev-code-tip‖baseline> <red_sha>` must include ≥1 test path |
| AC-3 changed lines `< N%` covered → exit 1 | P9, P10 | `check-diff-coverage.sh` :: LCOV `DA` covered-set ∩ batch changed non-doc lines ÷ measured-changed < threshold → 1 |
| AC-4 no `Coverage:` → exit 0 + WARN | P10, P6 | `check-diff-coverage.sh` :: absent/N-A command ⇒ WARN "diff-coverage unenforceable", exit 0 |
| AC-5 mutation enforce<thr→1 / advisory→0 / absent→skip | P1, P6, P10 | `check-mutation.sh` :: `MutationMode:enforce` + score<thr → 1; advisory/absent-mode → report + 0; no `Mutation:` → skip 0 |
| AC-6 all three marker-gated | P10 | each script :: `resolve_marker`+`intends_code` absent ⇒ exit 0 (identical to `check-tdd`) |
| AC-7 declared ⇒ exercised, no regression | P8, P10 | `--self-test` (both pass/fail sides) on each new/changed script; `shellcheck --severity=error`; `check-gate-integrity.sh`; existing `check-delivery`/`delivery-stop-hook`/`select-pipeline` self-tests still green |
| AC-8 F2/F3 wired; verify-batch passes with no tooling | P10 | `verify-batch.sh` gate list gains F2+F3; on a tooling-less repo all three skip+warn ⇒ batch still passes |

## 2. Architecture

### 2.1 Where each gate sits

All three are `verify-batch` gates in the established, non-skippable style
([enforcement.md](../../references/enforcement.md)): **marker-gated** (in-session; CI has no `.runs/`
marker), **git-grounded**, **project-declared command** (AGENTS.md), **skip+warn** absent tooling. F1
strengthens an *existing* gate (`check-tdd`, plus its recorder `tdd-red`); F2/F3 are *new* gates added to
`verify-batch.sh`'s list. None judges *intent* — the accepted floor-not-ceiling limit (§6, ADR-0003).

```
verify-batch.sh gate list  (→ = new/changed this milestone)
  quality-gate → orphans → architecture → gate-integrity
  → check-tdd            (F1: red must touch a test file)
  → check-diff-coverage  (F2: NEW — breadth of changed lines)     ← added
  → check-mutation       (F3: NEW — assertion strength, opt-in)   ← added
  → check-delivery
```

### 2.2 Shared helpers land in `bin/delivery-lib.sh` (one source of truth — R1)

New sourced helpers, reused by F1 and F2 so detection cannot diverge across gates:

- **`is_test_path PATH [EXTRA_GLOBS]`** (F1) — rc 0 if PATH is a test file. Default set (OQ-1):
  basename matches `*_test.* *.test.* test_*.* *.spec.* *Test.* *_spec.rb`, **or** any path segment ∈
  `{test, tests, spec, __tests__}`. `EXTRA_GLOBS` (space/comma-separated) **extends** the default set
  (never replaces — a project can widen but not shrink the check).
- **`read_test_globs [DOC]`** (F1) — extract `TestGlobs:` from AGENTS.md/CLAUDE.md (the `extract()`
  backtick-or-bare convention shared with `quality-gate.sh`), echo space-separated globs.
- **`current_batch_base`** (F2) — echo the base ref for the **in-flight** batch's diff, using the
  **exact same chain `verify-batch.sh`'s `stamp_batch_closed` uses today** (bin/verify-batch.sh:59–74):
  newest commit of the last `closed` ledger entry → `origin/main‖main‖origin/master‖master` → `HEAD~1`.
  **No `baseline_sha` tier** (Step-7 major fix): the earlier draft added one, which diverged from the
  stamp for a first batch whose baseline ≠ `origin/main`, so F2 and the `code_delta` stamp would measure
  different lines — an R1 (one-source-of-truth) violation. To make the "same window" claim hold *by
  construction*, B2 also **refactors `stamp_batch_closed` to call `current_batch_base`** (dropping its
  inline `since`/`range` computation), so the stamp and F2 share one definition and cannot drift. The
  chain is identical to today's, so the stamp's behavior is unchanged (verified by verify-batch's run on
  this repo, T007).
- **`changed_nondoc_lines BASE`** (F2) — emit `path:line` for every added/changed **non-doc** line in
  `git diff --unified=0 BASE..HEAD` (parse `@@ … +start,count @@` hunk headers; `_is_doc_path` filters).

F1's `is_test_path` and F2's line-set are pure (no global writes); sourcing stays side-effect-free.

### 2.3 F1 — red-touches-tests (`tdd-red.sh` + `check-tdd.sh`)

**One contract, both halves (resolves the Step-7 blocker): the failing test must be COMMITTED by
`red_sha`, not left in the worktree.** `tdd-red.sh` stamps `red_sha = HEAD`, and the spec defines the
check-tdd window as ending at `red_sha`; if `tdd-red` also accepted a worktree-only test, HEAD would not
advance, `red_sha == prev_tip`, the window `prev_tip..red_sha` would be empty, and check-tdd would
false-block a red that `tdd-red` accepted. So both halves demand the same thing — a **committed**
test-path change anchored at/by `red_sha`. Flow: write the failing test → **commit it** (the tdd.md
step-3 checkpoint) → `tdd-red` (records `red_sha` = that commit) → implement to green. Documented in
`tdd.md` (B4/T011).

**`tdd-red.sh` (recorder, AC-1).** After observing red (unchanged), before writing the record, check the
**committed** change set since the run baseline: `git diff --name-only <baseline_sha>..HEAD`. If **no**
path is a test path (`is_test_path` with `read_test_globs`) → refuse: print an actionable message
("no committed test-file change — commit your failing test first so the red is git-anchored, then re-run
`tdd-red`"), **write no record**, exit **4** (new code; distinct from 1=green-suite, 3=no-Test-command).
This rejects an `--allow-empty` red (empty commit, no committed test) and a non-test-only red; a
worktree-only test is refused *with guidance to commit it*, not silently accepted (keeps the halves
consistent). `--allow-empty` is not a flag `tdd-red` accepts; the guard catches the *state* it produces.

**`check-tdd.sh` (gate, AC-2).** Keep the existing per-batch red ordering (baseline < red < code, one
red per batch, HEAD green). **Add**, per code batch: the red window
`<prev-code-tip‖baseline> .. <red_sha>` must change ≥1 test path (`_window_touches_test BASE RED` =
`git diff --name-only BASE RED` filtered by `is_test_path`). Track `prev_tip` = the previous code
batch's newest commit across the ledger loop (baseline for the first). For the in-flight batch, window =
`<prev_tip> .. <red_sha>`. Direct-run fallback: `baseline .. red_sha`. Because `tdd-red` guarantees the
test is committed by `red_sha`, this window contains it. A red whose window touches only non-test files
(or is empty, e.g. an `--allow-empty` red_sha) → fail-closed. `_test_cmd` absent ⇒ the existing WARN
skip is unchanged (F1 rides the same graceful-skip as the base gate).

**Inline-test layouts (Step-7 major — documented escape, not a hard false-block).** Languages that put
tests inside source files (Rust `#[cfg(test)]` in `src/*.rs`, Python doctests) have no distinct
test-path. Default F1 would refuse their honest red. Escape (spec R4 "extensible `TestGlobs:`"): the
project widens `TestGlobs:` to its source globs (e.g. `TestGlobs: src/**/*.rs`), which makes any changed
source count as a test path — F1 becomes effectively advisory for that project **by explicit contract**,
consistent with the framework's declared-by-contract philosophy. The refuse message names this escape.
This is an accepted, documented limit (plan §6 R4, ADR-0003): strict by default, opt-out by one config line.

> **Self-test update (not a regression):** `check-tdd.sh`'s own fixtures today use `--allow-empty` red
> commits; F1 makes those the *rejected* case. The fixtures are updated so each red commit carries a
> test-path change (the natural TDD "commit the failing test" flow), preserving every prior assertion
> (ordering, reuse-rejection, HEAD-green) and adding the AC-2 empty-red-window fail case. AC-7's
> "no regression" governs the *other* gates' self-tests; a gate's own fixtures evolve with the gate.

### 2.4 F2 — diff-coverage (`bin/check-diff-coverage.sh`, NEW)

Marker-gated skip (AC-6) → read `Coverage:` (command emitting LCOV to stdout or to a `CoverageFile:`
path) and `CoverageThreshold:` (default `DEFAULT_COVERAGE_THRESHOLD=80`, OQ-3). Absent/N-A `Coverage:`
⇒ WARN + exit 0 (AC-4). Else:

1. `base="$(current_batch_base)"`; `changed = changed_nondoc_lines "$base"` (set of `path:line`).
2. Run `Coverage:`; capture LCOV (stdout or `CoverageFile:`). Parse: `SF:<path>` opens a section
   (normalize to repo-relative); `DA:<line>,<count>` → the line is **measured**; `count>0` → **covered**;
   `end_of_record` closes. Map keys `path:line`.
3. `measured = changed ∩ {all DA lines}`; `covered = changed ∩ {DA count>0}`. If `|measured|=0`:
   - **and the batch has ≥1 changed non-doc line** ⇒ **WARN loudly** ("changed lines are not present in
     the coverage report — the `Coverage:` command may be omitting untested files; diff-coverage cannot
     see them") and exit 0. **Not a silent pass** (Step-7 major fix): a wholly-untested new module is
     omitted from LCOV entirely by common tools (coverage.py, tarpaulin) → `measured=0`; silently
     passing would defeat US2. The contract requirement (documented, B4/T010): the `Coverage:` command
     must report **all changed files** (cover-all / `--include`), so an untested file appears as `DA`
     misses, not as an absence. Surfaced, per P6 (no silent caps); still exit 0 to honor "never a false
     block" when the tool genuinely reports nothing.
   - **and the batch has no changed non-doc line** ⇒ pass silently (nothing to measure).
   Else `pct = 100*|covered|/|measured|`; `pct < threshold` → exit 1 (AC-3), else exit 0.

LCOV `SF:` paths may be absolute or build-relative; normalize by **separator-anchored** suffix-matching
against the changed paths (Step-7 minor fix): a changed `path:line` counts as covered iff some `SF:`
section path **equals** the changed path or **ends with `/<changed-path>`** — never a bare string suffix
(so `SF:src/submodel.py` cannot absorb a changed `model.py`). Documented as the F2 path-matching rule.

### 2.5 F3 — mutation (`bin/check-mutation.sh`, NEW — advisory by default)

Marker-gated skip (AC-6) → read `Mutation:` (command scoped to changed files, emitting a normalized
score line), `MutationMode:` (`enforce|advisory`, default **advisory**), `MutationThreshold:` (default
`DEFAULT_MUTATION_THRESHOLD=60`). No `Mutation:` command ⇒ skip + WARN, exit 0 (AC-5). Else run it and
parse the **last** line matching `mutation_score:[[:space:]]*<float>` (0–100) **or**
`killed:<k>` … `total:<t>` (score = `100*k/t`), OQ-4. Then:

- `MutationMode: enforce` **and** a score parsed: `score < threshold` → exit 1, else exit 0 (AC-5).
- `advisory` / mode absent: print the score + "(advisory — not blocking)", exit 0 (P6: reported, not
  hidden; P1: expensive gate opt-in by contract).
- `Mutation:` present but no parseable score line → WARN "could not parse mutation score", exit 0
  (never a false block on a tooling quirk; the score is the project's contract to emit).
- **`total:0` / empty score (no mutable changed code)** → pass-with-note, exit 0 (Step-7 minor fix):
  guard `total==0` (and NaN/empty) **before** computing `100*k/t`, else `enforce` mode divides by zero,
  the script itself errors non-zero, and `verify-batch` counts the gate failed — a false block on a
  batch that simply had nothing to mutate. Mirrors F2's `|measured|=0` handling.

### 2.6 Wiring into `verify-batch.sh` (AC-8)

Add two `gate` lines after `check-tdd`, before `check-delivery`:

```sh
gate "diff-coverage (changed-line breadth, F2)"  "$here/check-diff-coverage.sh" .
gate "mutation (assertion strength, F3)"         "$here/check-mutation.sh" .
```

Extend the `gates` provenance string in `stamp_batch_closed` to
`…;tdd=ok;diff-coverage=ok;mutation=ok;delivery=ok`. On a tooling-less repo (this repo — no AGENTS.md)
both new gates skip+warn and return 0, so `verify-batch` still passes and stamps (AC-8, and this
milestone's own dogfood path).

### 2.7 Marker-gating shape (shared with `check-tdd`, AC-6)

Each new script opens with the identical guard: `marker="$(resolve_marker)"`; empty or
`intends_code != true` ⇒ print "no active delivery run — skipping" + exit 0. `.runs/` is gitignored ⇒
these bite **in-session only**; CI's `verify-batch` run finds no marker and skips them — the same honest
reach as `check-tdd`/`check-delivery` (enforcement.md "marker-gated ⇒ in-session").

## 3. Data model / contracts

No schema or migration. Two contract surfaces change, both additive:

**AGENTS.md fields** ([agents-md-contract.md](../../references/agents-md-contract.md), new `## Testing`
rows): `TestGlobs:` (F1, extends default test-path set), `Coverage:` + `CoverageThreshold:` +
`CoverageFile:` (F2), `Mutation:` + `MutationThreshold:` + `MutationMode:` (F3). All optional; absence ⇒
graceful skip. Read via the shared `extract()` backtick convention.

**`.runs/<run>/tdd.jsonl`** unchanged — F1 adds no field; it tightens what *qualifies* as a recordable
red, not the record shape.

## 4. Phase / batch decomposition — value-per-cost order, risk-rank non-increasing

Vertical slices; each code batch ships a working gate + its `--self-test` + live wiring
(`verify-batch`/CI). `risk_rank` sequence **2,2,2,1** (non-increasing ⇒ this milestone's own ledger
satisfies `check-delivery`'s AC-9 ordering; the doc batch is last and earns no delivery credit).

| # | scope | risk_rank | kind | files | AC | gate (evidence) |
|---|---|---|---|---|---|---|
| **B1** | F1 red-touches-tests | feature (2) | code | `bin/delivery-lib.sh` (add `is_test_path`,`read_test_globs`), `bin/tdd-red.sh` (+guard,+`--self-test`), `bin/check-tdd.sh` (+window check, updated self-test) | AC-1,2,6,7 | shellcheck; `tdd-red --self-test`; `check-tdd --self-test` (empty-red→fail, test-red→pass, ordering/reuse/HEAD-green preserved, marker-less→skip); `verify-batch .` still passes |
| **B2** | F2 diff-coverage | feature (2) | code | `bin/check-diff-coverage.sh` (new+`--self-test`), `bin/delivery-lib.sh` (add `current_batch_base`,`changed_nondoc_lines`), `bin/verify-batch.sh` (wire) | AC-3,4,6,7,8 | shellcheck; self-test both sides of threshold + absent-Coverage WARN + marker-less skip + no-measured-lines pass; `verify-batch .` skips+warns (AC-8) |
| **B3** | F3 mutation (opt-in) | feature (2) | code | `bin/check-mutation.sh` (new+`--self-test`), `bin/verify-batch.sh` (wire) | AC-5,6,7,8 | shellcheck; self-test enforce<thr→1 / enforce≥thr→0 / advisory→0 / absent→skip / marker-less→skip / unparseable→WARN 0; `verify-batch .` skips (AC-8) |
| **B4** | docs + version + ADR | doc (1) | doc | `references/tdd.md`, `references/enforcement.md`, `references/agents-md-contract.md`, `VERSION`→2.17.0, `CHANGELOG.md`, `docs/adr/0003-test-quality-gates.md` | AC-7 (docs) | gate-integrity; internal-link CI; review |

**Cross-batch wiring:** `is_test_path`/`read_test_globs` (B1 → `delivery-lib.sh`) are consumed by
`tdd-red`+`check-tdd` in B1 itself. `current_batch_base`/`changed_nondoc_lines` (B2 → `delivery-lib.sh`)
are consumed by F2 in B2 itself. B2 and B3 both edit `verify-batch.sh` (different `gate` lines, sequential
batches — no conflict). The doc batch's corrected claims in `enforcement.md`/`tdd.md` are only *true* once
B1–B3 land, so docs go last (B4).

## 5. ADR candidate (lands in B4)

**ADR-0003 — Test-quality gates raise the floor mechanically; test *intent* stays with review.**
Context: v2.15/2.16 made "a test was written and seen to fail" a git fact (a floor) but judge neither
whether the test asserts the *right* behavior nor how much of the change it covers. Decision: add three
marker-gated `verify-batch` gates — F1 (a red must change a *test file*), F2 (changed non-doc lines
covered ≥ threshold, from project LCOV), F3 (mutation score ≥ threshold, opt-in/advisory) — each
skip+warn when the project declares no tooling, none baking in per-language parsers (one normalized
contract: LCOV for F2, a `mutation_score:`/`killed:total:` line for F3). Consequences: the worst failures
(no test, fake red, under-coverage, vacuous asserts) are caught mechanically; **correctness of intent is
explicitly out of scope** and stays with `test-designer`/`qa-test-engineer`/review (stated, logged, not
proven — parity with `check-tdd`'s "wrong-but-failing test still counts"). F3's cost is bounded by
opt-in-by-contract (P1). Known limit: format-normalization is pushed to the project's declared command,
so a project emitting a nonstandard LCOV/score gets a WARN-skip, not a parse-error block (R1).

## 6. Risks (delta from spec §Risks — all carried; mitigations bound to mechanism)

R1 format sprawl → **one normalized contract** (LCOV `DA` for F2; a `mutation_score:`/`killed:total:`
line for F3); adapters are docs (B4), not code; unparseable ⇒ WARN-skip not block. R2 mutation too slow →
F3 **advisory by default**, `enforce` only by explicit `MutationMode:` + scoped to changed files (§2.5).
R3 false block on tooling-less projects → **absent command ⇒ skip+WARN**, exercised by every self-test's
absent-command case and by `verify-batch .` on this repo (AC-4/AC-8). R4 test-glob miss → default set
covers common ecosystems + extensible `TestGlobs:` (extends, never shrinks); §2.2. **Inline-test layouts
(Rust `#[cfg(test)]`, doctests) — documented escape:** widen `TestGlobs:` to the source globs so F1 is
advisory-by-contract for that project (§2.3), strict by default. **R1 window drift (Step-7) → F2 and the
`code_delta` stamp share one `current_batch_base` definition (§2.2), refactored so they cannot diverge.**
R5 false confidence →
Out-of-scope + ADR-0003 state plainly floor-not-ceiling; intent stays with review. **New — marker-scope
honesty:** like all marker-gated gates these bite in-session only (`.runs/` gitignored); CI's
`verify-batch` skips them — stated in §2.7 so the guarantee is not overread.
