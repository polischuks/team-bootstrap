# Tasks — closure-fidelity-gates

**Source plan:** [plan.md](plan.md) · **Source spec:** [spec.md](spec.md) · **Constitution pin:** 1.0.1 ·
**Version target:** 2.19.0 · **Total:** 18 tasks across 4 batches.

Conventions: `[P]` parallel-safe within batch · `(category · principle)` · `AC-N` pointer · precedent SHA.
Every `AC-N` in spec.md maps to ≥1 task (coverage check at bottom). Vertical slices, risk-first order.

## B1 — Gate A `check-enforcement.sh` + shared marker-list helpers (`kind:code`, `risk_rank:feature`) — CLOSED (cab07eb)

- [x] **T001** — `bin/delivery-lib.sh`: add `record_marker_list KEY JSON` + `marker_list KEY` (pure-bash
  marker rewrite, no `sed`; mirrors `record_precond`). *(foundation · P10)* — precedent: `record_precond`
  in `bin/check-preconditions.sh`. *(AC-1)*
- [x] **T002** — `bin/check-enforcement.sh`: marker-gate; detect gaps — no `Test:`→`red-first`, no
  `Coverage:`→`diff-coverage`, no `Mutation:`/`MutationMode≠enforce`→`mutation`; record
  `enforcement_gaps`. *(security · P6,P10)* — precedent: skip logic in `check-tdd.sh`/`check-mutation.sh`. *(AC-1)*
- [x] **T003** — block while `enforcement_gaps` non-empty ∧ `enforcement_ack`≠true; OQ-1 hard-require for
  in-flight `risk_rank` ∈ `{run-rate,irreversible}`; all-tooling ⇒ exit 0. *(security · P6)* *(AC-1, AC-2)*
- [x] **T004** — marker-gate: no active `intends_code` marker ⇒ exit 0 skip. *(security · P3)* *(AC-6)*
- [x] **T005** — `--self-test`: gap+no-ack→1, gap+ack→0, all-tooling→0, run-rate+gap+ack→1, marker-less→0,
  marker round-trips (non-target keys survive). *(foundation · P8)* *(AC-1, AC-2, AC-6, AC-7)*
- [x] **T006** — `tests/check-enforcement.test.sh` (`is_test_path`) running A `--self-test` + carrying
  `AC-1`/`AC-2`/`AC-6` tokens; wire A into `bin/verify-batch.sh`; shellcheck + gate-integrity clean;
  peer self-tests unregressed. *(infra · P8,P10)* *(AC-7, AC-8)*

## B2 — Gate B `check-completeness.sh` (`kind:code`, `risk_rank:feature`) — CLOSED (d021264)

- [x] **T007** — `bin/check-completeness.sh` per-batch: slug from marker `feature`→`specs/<slug>/tasks.md`;
  every in-flight-entry `task_id` must be `[x]`; any `[ ]`⇒fail. Never writes tasks.md. *(backend · P9,P10)*
  — precedent: ledger read in `check-tdd.sh`. *(AC-3)*
- [x] **T008** — `--final`: no `[ ]` left in tasks.md ∧ every `AC-N` in spec.md in ≥1 `is_test_path` file;
  `AcPattern:` override (default `AC-[0-9]+`). *(backend · P9,P10)* — precedent: `is_test_path` in
  `delivery-lib.sh`. *(AC-4)*
- [x] **T009** — marker-gate: no active marker ⇒ exit 0 skip. *(security · P3)* *(AC-6)*
- [x] **T010** — `--self-test`: per-batch `[x]`→0 / `[ ]`→1; `--final` complete+AC-referenced→0 /
  unchecked-or-AC-unreferenced→1; marker-less→0. *(foundation · P8)* *(AC-3, AC-4, AC-6, AC-7)*
- [x] **T011** — `tests/check-completeness.test.sh` (`AC-3`/`AC-4` tokens); wire per-batch B into
  `verify-batch.sh`; shellcheck + gate-integrity clean; peer self-tests unregressed. *(infra · P8,P10)*
  *(AC-7, AC-8)*

## B3 — Gate C `check-seam-ack.sh` + reviewer handoff (`kind:code`, `risk_rank:feature`)

- [x] **T012** — `bin/delivery-lib.sh`: `json_has_obj_field ARRAYJSON FIELD VALUE` (seam_acks presence
  test over array-of-objects). *(foundation · P10)* *(AC-5)*
- [x] **T013** — `bin/check-seam-ack.sh`: read `high_risk_seams`; if in-flight batch files intersect a
  seam's paths (coarse, OQ-4) require a matching `seam_acks` entry naming the seam + a resolvable commit;
  no flagged seam touched ⇒ exit 0. *(security · P3,P11)* *(AC-5)*
- [x] **T014** — marker-gate: no active marker ⇒ exit 0 skip. *(security · P3)* *(AC-6)*
- [x] **T015** — `--self-test`: touched-seam+no-ack→1, touched-seam+ack(seam+resolvable commit)→0,
  no-flagged-seam→0, marker-less→0. *(foundation · P8)* *(AC-5, AC-6, AC-7)*
- [x] **T016** — `references/roles/architecture-reviewer.md` handoff: add `high_risk_seams:[{seam,paths}]`
  (soundness mode, OQ-3); `tests/check-seam-ack.test.sh` (`AC-5` token); wire C into `verify-batch.sh`;
  shellcheck + gate-integrity clean; peer self-tests unregressed. *(infra · P8,P10)* *(AC-7, AC-8)*

## B4 — docs + wiring + version bump (`kind:doc`, `risk_rank:doc`) — CLOSED (pending)

- [x] **T017** — `references/agents-md-contract.md` (`AcPattern:`, marker schema: `enforcement_gaps`,
  `enforcement_ack`, `high_risk_seams`, `seam_acks`) + `references/enforcement.md` (new closure-fidelity
  layer) + `commands/deliver.md` (wire B `--final` at finalization + Phase-B ack steps) + ADR. *(docs · P7)*
  *(AC-8)*
- [x] **T018** — CHANGELOG `[2.19.0]`; bump `VERSION` + `plugin.json` + `marketplace.json` (metadata +
  plugins[]) to 2.19.0 (B1's dogfood + `check-version-sync` verify they stay in sync); final sweep
  (shellcheck, all self-tests, `check-completeness --final`, links). *(docs · P8)* *(AC-7, AC-8)*

## Coverage check (every AC → ≥1 task)

| AC | Tasks |
|---|---|
| AC-1 | T001, T002, T003, T005 |
| AC-2 | T003, T005 |
| AC-3 | T007, T010, T011 |
| AC-4 | T008, T010, T011 |
| AC-5 | T012, T013, T015, T016 |
| AC-6 | T004, T009, T014 |
| AC-7 | T005, T006, T010, T011, T015, T016, T018 |
| AC-8 | T006, T011, T016, T017, T018 |

All 8 ACs covered. No orphan tasks.
