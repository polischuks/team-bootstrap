# Step 1 — Principles / Constitution Analysis — test-quality-gates

**Constitution read in full:** [`constitution.md`](../../constitution.md) v1.0.1 (P1–P11).
**Asset VERSION:** 2.16.0. **Method:** counts grep-verified against reality, not asserted.

## 1. Existing doctrine coverage assessment (per scope item)

| Scope item | Governing principle(s) | Impact classification |
|---|---|---|
| **F1** red-touches-tests (tdd-red refuses empty/non-test red; check-tdd requires a test-path change in the red window) | P9 (red→green by evidence), P11 (ground in mechanism) | **No constitution impact** — hardens P9's existing red gate; makes "a red step happened" mean "a *test file* changed", closing a forge P9 already intends to forbid |
| **F2** diff-coverage threshold on the batch's changed lines | P9, P10 (declared ⇒ exercised; fail-closed) | **No impact** — a new `verify-batch` gate implementing P9/P10; adds no rule |
| **F3** opt-in mutation testing (advisory by default) | P1 (right-size), P6 (report truth; no silent drop), P10 | **No impact** — expensive gate made opt-in by contract per P1; advisory runs are *reported*, honoring P6 |
| Skip+warn when tooling absent (all three) | P6 (no silent caps), P10 (a gate that can't run is not a false pass) | **No impact** — mirrors `quality-gate.sh`'s established absent-command skip |
| AGENTS.md contract extension (`TestGlobs`, `Coverage`, `CoverageThreshold`, `Mutation`, `MutationThreshold`, `MutationMode`) | P7 (portable substrate; tooling stays project-side) | **No impact** — new *contract fields*, not bundled runtime; project supplies the runners |
| Doc edits: `tdd.md`, `enforcement.md`, `agents-md-contract.md` | P8 (versioned evolution) | **No impact** — additive documentation of the new gates |

**Every scope item implements or strengthens an existing invariant (P9/P10/P6/P1/P7). None adds, weakens, redefines, or removes one.**

## 2. Enumeration invariant checks (grep-verified)

| Invariant | Constitution claims | Reality (`ls`/`grep`) | Delta |
|---|---|---|---|
| Role playbooks `references/roles/*.md` | 51 | **51** | 0 — no new role |
| Pipelines `references/pipelines/*.md` | 6 | **6** | 0 — no new pipeline |
| Reviewer roles w/ `severity_counts` | 4 | **4** | 0 — no new reviewer dimension |
| Irreversibility action classes | see irreversibility.md | unchanged | 0 — a gate blocks *closure*, it is not a new irreversible action class |

No enumeration threshold is crossed. F2/F3 are **harness gates** (`bin/*.sh`), the same class as `check-tdd`/`check-delivery` — the constitution's enumeration table does not track `bin/` scripts, so adding two crosses no counted threshold.

## 3. Constitution version-bump verdict

**CONSTITUTION: No bump — stays v1.0.1.**

Rationale: constitution SemVer bumps on *changing an invariant* (MAJOR), *adding a principle / sanctioned exception / enumeration invariant* (MINOR), or *wording* (PATCH). This milestone does none — it is a pure **enforcement-hardening / capability** milestone that makes the harness enforce more of P9/P10 as already written. Doctrine's own Step-1 guidance: "hardening/patch milestones typically qualify for No bump."

## 4. Asset version-bump verdict (P8, distinct from constitution SemVer)

**ASSET VERSION: 2.16.0 → 2.17.0 (MINOR).**

Rationale: adds new capability surfaces — two new `verify-batch` gates (`check-diff-coverage.sh`, `check-mutation.sh`), a strengthened red step (F1), and six new AGENTS.md contract fields — **without breaking** existing behavior. All three gates are marker-gated (skip when no run) and skip+warn when the project declares no tooling (AC-4/AC-6/AC-8), so every existing project and non-delivery session is unaffected; nothing previously-sanctioned is removed. Additive + backward-compatible ⇒ MINOR. Per P8 the new/changed scripts must pass their `--self-test` + `shellcheck --severity=error` + `check-gate-integrity.sh`, and the existing gate self-tests must not regress, before landing (AC-7).

## 5. ADR candidates (land in the doc batch)

- **ADR-0003 — Test-quality gates raise the floor mechanically; intent stays with review.** Captures the "floor, not ceiling" framing (F1 pre-resolution): F1 makes a red mean a *test file* changed, F2 enforces *breadth* (changed lines covered), F3 enforces *assertion strength* (mutants killed) opt-in; none certifies the test asserts the *right* behavior — that stays with `test-designer`/`qa-test-engineer`/review. Architecturally significant: it defines the boundary of what the harness will and won't judge about test quality. **Recommended: author in the doc batch of this milestone.**

## 6. Registry impact

None. No role added ⇒ no `role-output.schema.json` branch, `role-matrix.md` row, or `skills-manifest.json` `used_by` entry required. `CHANGELOG.md` gets a `[2.17.0]` section; `VERSION` → `2.17.0` (both in the doc batch). `references/agents-md-contract.md` gains the six new field definitions (contract doc, not a registry).

## 7. Verdict + recommended action

- **Constitution:** no bump (v1.0.1). **Asset:** MINOR → **2.17.0**.
- **Proceed** to Step 2. No principle escalation required; no invariant threshold crossed.
- Carry ADR-0003 into the plan as the doc-batch deliverable.
