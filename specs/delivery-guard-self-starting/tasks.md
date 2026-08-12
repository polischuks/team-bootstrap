# Tasks — delivery-guard-self-starting

**Status:** ready · **Source plan:** [`plan.md`](plan.md) · **Source spec:** [`spec.md`](spec.md)
**Constitution pin:** v1.0.0 (no bump) · **Asset target:** 2.12.0 · **Total tasks:** 21 · **Batches:** 5
**Rev:** amended after Step-7 architecture review (`architecture_sound:false → resolved`): F-1 harness-written
marker (`delivery-marker-init.sh`, `UserPromptSubmit`), F-2 commit-to-batch binding, F-3 ack-honesty scoped
out, F-4 omitted-marker fixture, F-5 noted in ADR.

## Conventions

`Txxx [P?] [USx?] Description` · `[P]` parallel-safe within batch · category ∈ {foundation, infra, docs} ·
each task cites the AC it satisfies, a **precedent** SHA from v2.11.0, and its depends-on chain.
`⚠ reviewer` = mandatory reviewer flag.

## Dependency spine (critical path)

```
T001 delivery-lib.sh ──► T002 check-delivery recompute ──► T003 verify-batch shared-delta ──► [B1 gate]
        │
        └─► T-hook (ground UserPromptSubmit) ──► T005a marker-init hook ──► T005b register+enrich
                                                        │
T002,T005a ──► T005 marker-read + fail-closed + F-2 binding ──► T007 fixtures ──► [B2 gate]
[B2] ──► T008 stop-hook ──► T009 register ──► T010 gate-integrity(both marker paths) ──► [B3 gate]
[B3] ──► T011 preconditions-ack ──► T012 check-delivery ack-assert ──► T013 risk_rank ordering ──► [B4 gate]
[B4] ──► T015..T018 docs+version+ADR ──► [B5 gate]
```

## Hard front gate (blocks everything)

- [x] **T000** [foundation · P9] Capture red state: add fixtures that MUST fail against v2.11.0 today — the
  `deadbeef` forged-closure line (AC-1) and an inflated-`code_delta` line (AC-2) — and run them to *see them
  pass wrongly* (exit 0) before any fix. `bin/check-delivery.sh` self-test scaffold. **precedent: e6bba5d**.
  — proves the defect is real (P9 red→green), gates T002.

---

## Batch B1 — F-A unforgeable closure  (risk_rank: irreversible · kind:code)

- [x] **T001** [US1] Create `bin/delivery-lib.sh` (`# shellcheck shell=bash`): `resolve_ledger`, `resolve_marker`,
  `resolve_sha` (abbrev-safe `git rev-parse --verify -q "$1^{commit}"`), `nondoc_delta_of_shas` (per-commit
  `git show --numstat` sum over non-doc paths), `risk_rank_int`, `field_str`, `field_num`.
  — (foundation · P11) · AC-1,2 · **precedent: e6bba5d** (extractors + delta loop lifted from verify-batch/check-delivery) · depends: T000
- [x] **T002** [US1] Rewrite `bin/check-delivery.sh` closure check to source the lib: `git cat-file -e`/`resolve_sha`
  each `commit_sha` (missing → fail, AC-1); `recomputed = nondoc_delta_of_shas`; **`stamped > recomputed` → fail**
  (AC-2, literal "exceeds", NOT `!=` — Catch #1); require ≥1 non-doc-touching commit.
  — (foundation · P9,P11) · AC-1,2 · **precedent: e6bba5d** · depends: T001 · ⚠ security-reviewer (forgery surface)
- [x] **T003** [US1] Point `bin/verify-batch.sh` `stamp_batch_closed` at `nondoc_delta_of_shas` (drop the inline
  range-diff loop) so stamp == recompute by construction (R1).
  — (foundation · P10) · AC-3 · **precedent: 377ea38** (per-batch delta) · depends: T001
- [x] **T004** [US1] Self-test in `check-delivery.sh`: deadbeef→exit1 (AC-1), inflated-delta→exit1 (AC-2), replay
  historical B1–B5 → exit0 (AC-3). `shellcheck --severity=error bin/*.sh` clean.
  — (foundation · P9) · AC-1,2,3 · **precedent: e6bba5d** · depends: T002T003
  **B1 GATE:** shellcheck clean · deadbeef & inflated fixtures fail · historical ledger passes · verify-batch self-test green.

## Batch B2 — F-B fail-closed + **harness-written** marker + F-2 binding  (risk_rank: run-rate · kind:code)

> **Revised after Step-7 architecture review (F-1/F-2/F-4):** the marker must be **harness-written**, not
> `/deliver` prose — else absence-of-marker fails open for the "orchestrator skips the protocol" threat.

- [x] **T-hook** [US3] Ground the mechanism (P11): verify the Claude Code **`UserPromptSubmit`** hook contract
  (payload carries the submitted prompt; a command hook can write a file) against the harness docs BEFORE
  building T005a. If unavailable, use the documented fallback (`PreToolUse` floor on first `Skill` + deliver.md
  step 0). — (foundation · P11) · AC-6 · depends: T001
- [x] **T005a** [US3] Create `bin/delivery-marker-init.sh` (`UserPromptSubmit` hook): on a prompt invoking
  `commands:deliver`/`/deliver` with `mvp|full`, **ensure** `.runs/<run>/RUN` exists with
  `{intends_code:true, source:"harness", baseline_sha:<HEAD>, run:<derived>}`; no-op on any other prompt.
  — (infra · P3) · AC-6 · **precedent: quality-gate.sh / hooks.json** · depends: T-hook · ⚠ security-reviewer (on-by-default writer; must no-op off-deliver)
- [x] **T005b** [US3] Register `delivery-marker-init.sh` under `UserPromptSubmit` in `hooks/hooks.json`; `commands/deliver.md`
  step 0 **enriches** (never sole-writes) the floor marker with `pipeline,feature,precond`.
  — (infra · P3) · AC-6 · **precedent: hooks/hooks.json** · depends: T005a
- [x] **T005** [US2] Add marker-aware branches to `bin/check-delivery.sh`: no-marker+no-ledger → exit0 (AC-5);
  marker `intends_code:true` + (no ledger OR zero `closed kind:code`) → exit1 (AC-4). **F-2 binding (active
  marker only):** a `commit_sha` in >1 `closed` batch → exit1; a `commit_sha` that is an ancestor of
  `baseline_sha` → exit1. Marker-less replay skips binding (preserves AC-3 — history reuses e6bba5d).
  — (foundation · P10,P11) · AC-4,5 · **precedent: a9b9a8b** · depends: T001,T002,T005a
- [x] **T007** [US2][P] Self-test: AC-4 (no-ledger, doc-only-closures → exit1) · AC-5 (no marker → exit0) ·
  **F-4 fixture:** simulate a `/deliver`-shaped prompt through `delivery-marker-init.sh` and assert the marker
  is created (fails if the floor writer didn't run — the omitted-marker threat, not just marker-present) ·
  **F-2 fixture:** reused-SHA across two closed batches under an active marker → exit1.
  — (foundation · P9,P10) · AC-4,5,6 · depends: T005,T005a
  **B2 GATE:** shellcheck clean · harness floor writes marker on `/deliver` prompt · marker+no-code → exit1 ·
  no-marker → exit0 · reused-SHA → exit1.

## Batch B3 — F-C delivery-aware Stop / SubagentStop hook  (risk_rank: run-rate · kind:code)

- [x] **T008** [US2] Create `bin/delivery-stop-hook.sh` sourcing the lib: `TEAM_BOOTSTRAP_DELIVERY_GATE=off`→0;
  no active marker→0; active marker + announced-unclosed `kind:code` (or zero closed code)→**exit 2** (block) with
  actionable stderr; else 0. Exit 2 not 1 (Catch #2).
  — (infra · P3,P6) · AC-8 · **precedent: quality-gate.sh / hooks.json** · depends: T001 · ⚠ security-reviewer (completion-block surface)
- [x] **T009** [US2] Register the hook under `Stop` AND `SubagentStop` in `hooks/hooks.json`
  (`${CLAUDE_PLUGIN_ROOT}/bin/delivery-stop-hook.sh`).
  — (infra · P3) · AC-8 · **precedent: hooks/hooks.json** · depends: T008
- [x] **T010** [P] Self-test + gate-integrity: block fixture (marker+unclosed→2), allow fixtures (all closed→0, no
  marker→0); `check-gate-integrity.sh` confirms the hook demonstrably fires — against **both** the marker-present
  AND the omitted-marker path (F-4: not vacuous in the case it exists for), i.e. it must show the marker gets
  created and the block triggers, not merely that a pre-seeded marker blocks. (AC-10, declared⇒exercised).
  — (foundation · P10) · AC-8,10 · depends: T008,T009
  **B3 GATE:** shellcheck clean · block/allow fixtures pass · gate-integrity shows hook fires.

## Batch B4 — F-D recorded ack + F-E risk_rank ordering  (risk_rank: feature · kind:code)

- [x] **T011** [US4] `bin/check-preconditions.sh`: on exit 2 with a marker present, write `precond={exit:2,items:[…],ack:false}`
  into `.runs/<run>/RUN`. Exit codes 0/1/2 preserved.
  — (foundation · P5) · AC-7 · **precedent: a9b9a8b** · depends: T001
- [x] **T012** [US4] `bin/check-delivery.sh` assert: marker `precond.exit==2 && precond.ack==false` + ≥1 announced
  batch → exit1 ("Phase-A deliverability ack not recorded"). Makes AC-7 machine-enforced, not prose.
  — (foundation · P5,P10) · AC-7 · **precedent: e6bba5d** · depends: T005,T011
- [x] **T013** [US5] `bin/check-delivery.sh` risk_rank ordering: over closed `kind:code` entries **declaring**
  `risk_rank`, rank-int (via `risk_rank_int`) must be non-increasing in close order; an ascent → exit1 (AC-9).
  Entries without `risk_rank` unconstrained (AC-3 backward-compat).
  — (foundation · P10,P11) · AC-9 · **precedent: 0b7d409** (ordering invariant) · depends: T002
- [x] **T014** [P] Self-test: ack-pending→exit1 (AC-7), rank-ascent (feature-before-irreversible)→exit1 (AC-9),
  historical-no-rank→exit0 (AC-3 still green).
  — (foundation · P9) · AC-7,9 · depends: T012,T013
  **B4 GATE:** shellcheck clean · ack-pending→1 · rank-ascent→1 · history still passes.

## Batch B5 — docs + version + ADR  (risk_rank: doc · kind:doc · LAST)

- [x] **T015** [docs] Correct `references/enforcement.md`: replace the false "the orchestrator's prose cannot flip a
  batch to closed" line with the git-derived guarantee (recompute + SHA-existence + marker); note the forgeable-JSON
  gap F-A closed. — (docs · P11) · AC-10 · **precedent: e6bba5d** · depends: T002
- [x] **T016** [docs][P] Update `references/failure-policy.md` (fire-means-code now binds even if the ledger is
  skipped, via marker+CI) and `references/hooks.md` (document the delivery-aware Stop/SubagentStop hook + the
  `TEAM_BOOTSTRAP_DELIVERY_GATE=off` escape). — (docs · P6) · AC-10 · **precedent: 4d4a42d** · depends: T008
- [x] **T017** [docs][P] `docs/adr/0002-closure-from-git-state.md` per plan §6; `commands/deliver.md` prose polish
  (risk_rank in Announce, ack-record step). — (docs · P8) · **precedent: docs/adr/0001** · depends: T002,T006,T011
- [x] **T018** [docs] `VERSION` → `2.12.0`; `CHANGELOG.md` `[2.12.0]` section (F-A..F-E). Final:
  `shellcheck --severity=error bin/*.sh` + all self-tests + `check-gate-integrity.sh` green (AC-10).
  — (docs · P8) · AC-10 · **precedent: 2.11.0 release f104f0b** · depends: T015,T016,T017
  **B5 GATE:** gate-integrity green · version+changelog consistent · ADR-0002 present.

---

## AC → task coverage (grep-verified: every AC maps to ≥1 task)

| AC | tasks |
|---|---|
| AC-1 | T000, T001, T002, T004 |
| AC-2 | T000, T001, T002, T004 |
| AC-3 | T003, T004, T014 |
| AC-4 | T005, T007 |
| AC-5 | T005, T007 |
| AC-6 | T-hook, T005a, T005b, T007 (F-4 omitted-marker fixture) |
| AC-7 | T011, T012, T014 |
| AC-8 | T008, T009, T010 |
| AC-9 | T013, T014 |
| AC-10 | T004, T010, T018 |

## Risk-flagged tasks (mandatory reviewers)

- **T002** ⚠ security-reviewer — the forgery/anti-forgery surface (the headline defect).
- **T005a** ⚠ security-reviewer — the harness `UserPromptSubmit` marker writer (on-by-default; must no-op off-deliver, must not mis-fire).
- **T008** ⚠ security-reviewer — the completion-blocking hook (on-by-default; must be no-op-safe without a marker).

## Out of scope / deferred

- Committed `summary.json` for CI-without-push (OQ-2) — follow-on.
- Proving `risk_rank` honesty (R4) — enum-constrained + logged only.
- The code-clean gates (orphans/architecture/gate-integrity logic) — unchanged.

## Risk register (carried from spec §Risks + plan §7)

R1 shared-lib divergence (M/H) → `delivery-lib.sh` single source + §4 fixture. R2 nag (M/H) → strict `intends_code`
gate + AC-5. **R3 omitted marker (M/H) → CLOSED: harness `UserPromptSubmit` floor writes the marker, not prose
(F-1 fix); skipping a step can't no-op the gate.** R4 rank gaming (H/M) → enum + logged (accepted). R5 hook loop
(L/M) → actionable msg + ~8-block cap. R6 abbrev-SHA mismatch (M/M) → `resolve_sha` normalization (Catch #3). R7
range-diff vs per-commit-sum drift (M/H) → `>=` tolerance, proven §4. R8 doc-file miscount (L/M) → shared non-doc
path filter, one definition. **F-2 commit-reuse forge (M/H) → active-marker binding (no cross-batch SHA reuse +
reachable-after-baseline). F-3 ack honesty (M/M) → presence-enforced, honesty logged (accepted). F-5 history
rewrite (L/L) → ADR-noted, accepted.**

## Exit criteria (release gate)

All 18 tasks `[x]` · every batch gate green · `shellcheck --severity=error bin/*.sh` clean · every changed script
self-tests · `check-gate-integrity.sh` confirms no green-by-skip and the new hook fires · historical ledger passes
(no false positive) · `VERSION`=2.12.0 + CHANGELOG + ADR-0002 · **no push** without explicit authorization (P5).
