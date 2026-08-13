# Tasks — test-quality-gates

**Status:** ready · **Source plan:** [`plan.md`](plan.md) · **Source spec:** [`spec.md`](spec.md)
**Constitution pin:** v1.0.1 (no bump) · **Asset target:** 2.17.0 · **Total tasks:** 16 · **Batches:** 4
**Order:** value-per-cost F1 → F2 → F3 → docs; `risk_rank` 2,2,2,1 (non-increasing).
**Rev:** amended after Step-7 architecture review (`architecture_sound:false → resolved`): F1 one-contract
committed-test (T002/T003), inline-test escape via `TestGlobs:` (T002), F2 `measured=0`→WARN not silent +
cover-all contract + separator-anchored `SF:` match (T006), F2 window shares `current_batch_base` with the
stamp — stamp refactored (T005/T007), F3 `total:0`→pass-not-crash (T008).

## Conventions

`Txxx [P?] [USx?] Description` · `[P]` parallel-safe within batch · category ∈ {foundation, infra, docs} ·
each task cites the AC it satisfies, a **precedent** SHA/file, and its depends-on chain. `⚠ reviewer` =
mandatory reviewer flag. Every code batch is **red-first**: write the `--self-test` case that fails
against current code, see it fail, then implement to green (P9; and this repo has no `Test:` command so
`tdd-red.sh` is unenforceable here — the red is shown in the builder's evidence, not the harness record).

## Dependency spine (critical path)

```
B1: T001 lib(is_test_path,read_test_globs) ─► T002 tdd-red guard ─► T003 check-tdd window ─► T004 self-tests ─► [B1 gate]
B2: T005 lib(current_batch_base,changed_nondoc_lines) ─► T006 check-diff-coverage ─► T007 wire+self-test ─► [B2 gate]
B3: T008 check-mutation ─► T009 wire+self-test ─► [B3 gate]
B4: T010..T015 docs+contract+version+ADR ─► [B4 gate]
```

B1 lib helpers are independent of B2 lib helpers (different functions, same file — B1 lands first, B2
appends). B2 and B3 both append a `gate` line to `verify-batch.sh` (sequential, no conflict).

## Hard front gate (per batch, not global)

Each code batch's first task writes the failing `--self-test` case(s) for its AC and runs them to see
them fail against current `bin/` (P9 red). No implementation task starts green.

---

## Batch B1 — F1 red-touches-tests  (risk_rank: feature · kind:code · US1)

- [x] **T001** [US1] Add to `bin/delivery-lib.sh`: `is_test_path PATH [EXTRA_GLOBS]` (default set — basename
  `*_test.* *.test.* test_*.* *.spec.* *Test.* *_spec.rb`, or path segment ∈ `{test,tests,spec,__tests__}`;
  `EXTRA_GLOBS` extends, never replaces) and `read_test_globs [DOC]` (extract `TestGlobs:` via the shared
  backtick/bare `extract` convention). Pure, side-effect-free.
  — (foundation · P11) · AC-1,2 · **precedent: bin/quality-gate.sh `extract()`; bin/delivery-lib.sh `_is_doc_path`** · depends: —
- [x] **T002** [US1] `bin/tdd-red.sh`: after observing red, check the **committed** change set
  `git diff --name-only <baseline_sha>..HEAD`; if no path is a test path (`is_test_path` + `read_test_globs`) →
  refuse, write **no** record, exit **4** with an actionable message ("commit your failing test first so the
  red is git-anchored, then re-run; inline-test projects: widen `TestGlobs:` to your source globs"). Rejects
  `--allow-empty`, non-test-only, and worktree-only (uncommitted) reds — one contract with check-tdd's
  `…red_sha` window (Step-7 blocker fix).
  — (foundation · P9,P11) · AC-1 · **precedent: bin/tdd-red.sh record block** · depends: T001 · ⚠ (forge surface)
- [x] **T003** [US1] `bin/check-tdd.sh`: per code batch, require the red window `<prev-code-tip‖baseline>..<red_sha>`
  to change ≥1 test path (`_window_touches_test BASE RED` = `git diff --name-only BASE RED` filtered by
  `is_test_path`). Track `prev_tip` across the ledger loop; in-flight window = `prev_tip..red_sha`; direct-run
  fallback `baseline..red_sha`. Preserve existing ordering/reuse/HEAD-green logic and the `_test_cmd`-absent WARN skip.
  — (foundation · P9,P11) · AC-2 · **precedent: bin/check-tdd.sh `_find_red`/`_evaluate`** · depends: T001
- [x] **T004** [US1] Self-tests + `--self-test` for `tdd-red.sh` (empty/allow-empty red → exit 4; non-test-only
  committed red → exit 4; worktree-only test → exit 4; **committed** test-touching red → record, exit 0; no
  `Test:` cmd → exit 3). Update `check-tdd.sh --self-test`: red commits now carry a **committed** test-path change
  (preserving ordering/reuse/HEAD-green cases) **plus** an empty-red-window → fail case (AC-2) and the marker-less →
  skip case (AC-6). `shellcheck --severity=error bin/*.sh` clean; `verify-batch .` still passes.
  — (foundation · P8,P10) · AC-1,2,6,7 · **precedent: bin/check-tdd.sh self-test harness** · depends: T002T003
  **B1 GATE:** shellcheck clean · `tdd-red --self-test` green · `check-tdd --self-test` green (empty-red→fail, test-red→pass, marker-less→skip) · `verify-batch .` passes.

## Batch B2 — F2 diff-coverage  (risk_rank: feature · kind:code · US2/US4)

- [x] **T005** [US2] Add to `bin/delivery-lib.sh`: `current_batch_base` mirroring the **exact** chain
  `stamp_batch_closed` uses today (last `closed` entry's newest commit → `origin/main‖main‖origin/master‖master`
  → `HEAD~1`; **no `baseline_sha` tier**) and `changed_nondoc_lines BASE` (emit `path:line` for each added/changed
  non-doc line in `git diff --unified=0 BASE..HEAD`, parsing `@@ +start,count @@`, `_is_doc_path`-filtered).
  **Refactor `bin/verify-batch.sh` `stamp_batch_closed` to call `current_batch_base`** (drop its inline `since`/
  `range`) so F2's window and the `code_delta` stamp share one definition and cannot drift (Step-7 R1 fix).
  — (foundation · P10) · AC-3 · **precedent: bin/verify-batch.sh `stamp_batch_closed` range logic; delivery-lib `_is_doc_path`** · depends: —
- [x] **T006** [US2,US4] Create `bin/check-diff-coverage.sh` (marker-gated skip, AC-6): read `Coverage:` /
  `CoverageThreshold:` (default `DEFAULT_COVERAGE_THRESHOLD=80`) / `CoverageFile:`. Absent `Coverage:` → WARN +
  exit 0 (AC-4). Else run `Coverage:`, parse LCOV (`SF:`→path, `DA:line,count` measured/covered, `end_of_record`),
  intersect with `changed_nondoc_lines "$(current_batch_base)"`; `|measured|=0` **with** changed non-doc lines →
  **WARN loudly** + exit 0 (not silent — Step-7 major; contract: `Coverage:` must cover-all changed files);
  `|measured|=0` with no changed lines → silent pass; else `pct<threshold` → exit 1, `≥` → exit 0.
  **Separator-anchored** `SF:` match (path equals, or ends with `/<changed-path>` — never bare suffix; Step-7 minor).
  — (infra · P9,P10,P6) · AC-3,4,6 · **precedent: bin/check-tdd.sh marker guard + `_test_cmd`** · depends: T005 · ⚠ (parser correctness)
- [x] **T007** [US2,US4] `--self-test` for `check-diff-coverage.sh` via a stub `Coverage:` command (`cat` a fixture
  LCOV): below-threshold → exit 1, at/above → exit 0 (AC-3); no `Coverage:` → WARN exit 0 (AC-4); marker-less → skip
  (AC-6); measured=0-with-changes → WARN exit 0; no changed lines → pass; separator-anchored path-match case. Wire
  the F2 `gate` line into `bin/verify-batch.sh` (after `check-tdd`) and extend `stamp_batch_closed`'s `gates`
  string. **Confirm the stamp still records the same `code_delta` after the T005 `current_batch_base` refactor**
  (run `verify-batch .` self-check) and that on this (tooling-less) repo F2 skips+warns and the batch still passes
  (AC-8). `shellcheck` clean.
  — (infra · P8,P10) · AC-3,4,6,7,8 · **precedent: bin/verify-batch.sh gate list; check-tdd self-test** · depends: T006
  **B2 GATE:** shellcheck clean · self-test both threshold sides + absent-Coverage WARN + marker-less skip + no-measured pass · `verify-batch .` passes (F2 skip+warn, AC-8).

## Batch B3 — F3 mutation (opt-in)  (risk_rank: feature · kind:code · US3/US4)

- [ ] **T008** [US3,US4] Create `bin/check-mutation.sh` (marker-gated skip, AC-6): read `Mutation:` /
  `MutationMode:` (`enforce|advisory`, default advisory) / `MutationThreshold:` (default
  `DEFAULT_MUTATION_THRESHOLD=60`). No `Mutation:` → skip+WARN exit 0 (AC-5). Else run it, parse the **last**
  `mutation_score:<float>` or `killed:<k>`+`total:<t>` line. **Guard `total==0` / empty / NaN → pass-with-note
  BEFORE computing `100·k/t`** (Step-7 minor — else `enforce` divides by zero and false-blocks a batch with no
  mutable code). `enforce` + score<thr → exit 1; `enforce` + score≥thr → 0; advisory/absent-mode → "(advisory)"
  exit 0; unparseable score → WARN exit 0.
  — (infra · P1,P6,P10) · AC-5,6 · **precedent: bin/check-diff-coverage.sh (T006) skeleton** · depends: T006 (skeleton parity)
- [ ] **T009** [US3,US4] `--self-test` for `check-mutation.sh` via a stub `Mutation:` command (`cat` a fixture score
  line): enforce + below → exit 1; enforce + above → exit 0; advisory → exit 0; absent `Mutation:` → skip exit 0;
  marker-less → skip; unparseable → WARN exit 0; **`total:0` (no mutable code) → pass exit 0, no crash** (AC-5, AC-6).
  Wire the F3 `gate` line into `bin/verify-batch.sh` and extend the `gates` string. Confirm `verify-batch .` still
  passes (AC-8). `shellcheck` clean.
  — (infra · P8,P10) · AC-5,6,7,8 · **precedent: bin/verify-batch.sh gate list** · depends: T008
  **B3 GATE:** shellcheck clean · self-test all five mode/threshold cases + marker-less skip · `verify-batch .` passes (F3 skip, AC-8).

## Batch B4 — docs + version + ADR  (risk_rank: doc · kind:doc)

- [ ] **T010** [docs] `references/agents-md-contract.md`: document the six new `## Testing` fields —
  `TestGlobs`, `Coverage`, `CoverageThreshold`, `CoverageFile`, `Mutation`, `MutationThreshold`, `MutationMode`
  — with the LCOV / normalized-score contracts and the skip+warn-when-absent rule.
  — (docs · P7) · AC-7 · **precedent: references/agents-md-contract.md** · depends: B1B2B3
- [ ] **T011** [docs] `references/tdd.md`: add F1 (a red must change a test file) to the red-step section.
  — (docs · P9) · AC-7 · depends: B1
- [ ] **T012** [docs] `references/enforcement.md`: add F2/F3 to the `verify-batch` gate list + the floor-not-ceiling
  honest-reach paragraph (intent stays with review; marker-gated ⇒ in-session).
  — (docs · P10) · AC-7 · depends: B1B2B3
- [ ] **T013** [docs] `docs/adr/0003-test-quality-gates.md` — ADR-0003 (plan §5).
  — (docs · P8) · AC-7 · **precedent: docs/adr/0002-closure-from-git-state.md** · depends: B1B2B3
- [ ] **T014** [docs] `VERSION` → `2.17.0`; `CHANGELOG.md` `[2.17.0]` section (F1/F2/F3, contract fields, ADR-0003).
  — (docs · P8) · AC-7 · depends: B1B2B3
- [ ] **T015** [docs] Final sweep: `check-gate-integrity.sh .` clean (no green-by-skip); CI internal-link check
  passes for the new ADR/reference links; re-run all `bin/*.sh --self-test` + `shellcheck --severity=error bin/*.sh`.
  — (docs · P10) · AC-7 · depends: T010T014
  **B4 GATE:** gate-integrity clean · links resolve · all self-tests + shellcheck green.

---

## AC → task coverage (grep-verified before B4 close)

| AC | Tasks |
|---|---|
| AC-1 (tdd-red refuses empty/non-test red) | T002, T004 |
| AC-2 (check-tdd red-window test-touch) | T003, T004 |
| AC-3 (diff-coverage threshold) | T005, T006, T007 |
| AC-4 (no Coverage → skip+warn) | T006, T007 |
| AC-5 (mutation enforce/advisory/absent) | T008, T009 |
| AC-6 (all three marker-gated) | T004, T007, T009 |
| AC-7 (self-test + shellcheck + gate-integrity + no regression) | T004, T007, T009, T015 |
| AC-8 (F2/F3 wired; verify-batch passes tooling-less) | T007, T009 |

Every AC maps to ≥1 task; every code task cites its AC. No orphan AC.

## Risk register (carried from spec §Risks + plan §6)

| # | Risk | Mitigation (task) |
|---|---|---|
| R1 | Coverage/mutation format sprawl | One normalized contract (LCOV `DA` / score line); unparseable → WARN-skip not block (T006,T008); adapters are docs (T010) |
| R2 | Per-batch mutation too slow | F3 advisory-by-default, `enforce` opt-in, scoped to changed files (T008) |
| R3 | False block on tooling-less project | Absent command ⇒ skip+WARN, exercised by self-tests + `verify-batch .` (T007,T009) |
| R4 | Test-glob set misses a convention | Default set + extending `TestGlobs:` (T001) |
| R5 | False confidence (floor read as ceiling) | Out-of-scope + ADR-0003 + docs (T012,T013) |
| R6 | check-tdd self-test regression from F1 | Update fixtures coherently; preserve all prior cases (T004) |
| R7 | Marker-scope overread (CI vs in-session) | Documented in enforcement.md honest-reach (T012); parity with check-tdd |
| R8 | LCOV path mismatch (abs/build-relative) | Suffix-match `SF:` to changed paths, documented (T006) |

## Exit criteria (release gate)

- [ ] All 16 tasks `[x]`; AC→task table fully covered.
- [ ] `bin/*.sh --self-test` green for `tdd-red`, `check-tdd`, `check-diff-coverage`, `check-mutation`;
  existing `check-delivery`/`delivery-stop-hook`/`select-pipeline` self-tests still green (no regression).
- [ ] `shellcheck --severity=error bin/*.sh` clean; `check-gate-integrity.sh .` clean.
- [ ] `verify-batch .` passes on this repo (all three tooling gates skip+warn — AC-8).
- [ ] `VERSION`=2.17.0, `CHANGELOG [2.17.0]`, ADR-0003 present, internal links resolve.
- [ ] Push only on explicit human authorization (P5).
