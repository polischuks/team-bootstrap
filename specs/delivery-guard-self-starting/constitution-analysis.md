# Step 1 — Principles / Constitution Analysis — delivery-guard-self-starting

**Constitution read in full:** [`constitution.md`](../../constitution.md) v1.0.0 (P1–P11).
**Asset VERSION:** 2.11.0. **Method:** counts grep-verified against reality, not asserted.

## 1. Existing doctrine coverage assessment (per scope item)

| Scope item | Governing principle(s) | Impact classification |
|---|---|---|
| **F-A** unforgeable closure (recompute delta from git objects) | P9 (verify by evidence), P11 (ground in mechanism), P6 | **No constitution impact** — implements P9/P11; the principle already *requires* grounding in the terminal mechanism, this makes the gate obey it |
| **F-B** fail-closed under an active run | P10 (fail-closed; vacuous gate = failure) | **No impact** — closes a green-by-skip hole P10 already forbids |
| Run marker `.runs/<run>/RUN` (machine fact "delivery active") | P3 (harness-enforced, not LLM-decided) | **No impact** — new *artifact*, not a new rule; realises P3 |
| **F-C** delivery-aware Stop/SubagentStop hook | P3, P6, P9 (Stop-hook enforcement already sanctioned) | **No impact** — `hooks.md` already sanctions Stop-hook enforcement; this is a narrower, safer instance |
| **F-D** recorded, blocking precondition ack | P5 (irreversibility gated; never push without auth) | **No impact** — records an ack P5 already demands |
| **F-E** declared `risk_rank` ordering | P10, P11 | **No impact** — a ledger field + gate check, not a doctrine change |
| Doc edits: `enforcement.md`, `failure-policy.md`, `deliver.md`, `hooks.md` | P8 (versioned evolution) | **No impact** — corrective wording (removes a now-false claim) |

**Every scope item implements or strengthens an existing invariant. None adds, weakens, redefines, or removes one.**

## 2. Enumeration invariant checks (grep-verified)

| Invariant | Constitution claims | Reality (`ls`/`grep`) | Delta |
|---|---|---|---|
| Role playbooks `references/roles/*.md` | 51 | **51** | 0 — no new role |
| Pipelines `references/pipelines/*.md` | 6 | **6** | 0 — no new pipeline |
| Reviewer roles w/ `severity_counts` | 4 | **4** | 0 — no new reviewer dimension |
| Irreversibility action classes | see irreversibility.md | unchanged | 0 — the Stop hook blocks *completion*, it is not a new irreversibility class |

No enumeration threshold is crossed. The Stop/SubagentStop hook is a **completion-blocking** hook (blocks a session ending with unclosed code work); it does not introduce a new irreversible action class, so it adds **no** row to the enumeration-invariants table.

## 3. Constitution version-bump verdict

**CONSTITUTION: No bump — stays v1.0.0.**

Rationale: constitution SemVer bumps on *changing an invariant* (MAJOR), or *adding a principle / sanctioned exception / enumeration invariant* (MINOR), or *wording* (PATCH). This milestone does none — it is a pure **enforcement-hardening** milestone that makes the harness actually obey P3/P5/P6/P9/P10/P11 as already written. The doctrine's own Step-1 guidance: "hardening/patch milestones typically qualify for No bump."

## 4. Asset version-bump verdict (P8, distinct from constitution SemVer)

**ASSET VERSION: 2.11.0 → 2.12.0 (MINOR).**

Rationale: adds new capability surfaces — git-derived closure, the run marker, a delivery-aware Stop hook, and the `risk_rank` field/gate — **without breaking** existing behavior. The new fail-closed branch is gated behind an active run marker (AC-5 pins the no-marker exit-0 path), so non-delivery and docs-only sessions are unaffected; nothing previously-sanctioned is removed. Additive + backward-compatible ⇒ MINOR, not MAJOR. Per P8 the changed scripts/hook must pass their self-tests + `shellcheck` + `check-gate-integrity.sh` before landing (AC-10).

## 5. ADR candidates (land in Phase 1 / this milestone)

- **ADR-0002 — Closure is a function of git-provable repository state, not a self-declared ledger field.** Captures the F-A decision (recompute non-doc delta over the stamped `commit_shas` set; reject missing SHAs and inflated `code_delta`) and the harness-owned run marker that lets every gate invert absent-input from skip→fail. Architecturally significant: it changes *what "closed" means* from an assertion to a derivation. **Recommended: author in the doc batch of this milestone.**

## 6. Registry impact

None. No role added ⇒ no `role-output.schema.json` branch, `role-matrix.md` row, or `skills-manifest.json` `used_by` entry required. `CHANGELOG.md` gets a `[2.12.0]` section; `VERSION` → `2.12.0` (both in the doc batch).

## 7. Verdict + recommended action

- **Constitution:** no bump (v1.0.0). **Asset:** MINOR → **2.12.0**.
- **Proceed** to Step 2. No principle escalation required; no invariant threshold crossed.
- Carry ADR-0002 into the plan as the doc-batch deliverable.
