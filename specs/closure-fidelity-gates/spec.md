# Spec — closure-fidelity-gates

> From a post-delivery retrospective: a HIGH bug (a CAS predicate `IN (owed-set)` where the candidates
> were `= 'done'` → UPDATE matched 0 rows → infinite loop) passed every gate and was caught only by an
> independent post-review. Root cause, sharpened: the gates that would have caught it — P9 red-first
> (`check-tdd`), diff-coverage (F2), mutation (F3) — **all silently skipped** because the project
> declared no `Test:`/`Coverage:`/`Mutation:` tooling. The bug slipped through *disarmed* gates, not
> absent ones. Same self-disarm-on-absent-input class as the marker-whitespace bug (v2.18.1). And the
> recurring symptom — post-`/deliver` review keeps finding undone tasks / unimplemented spec parts —
> is a third failure: **closure certifies mechanics (code_delta + gates green), not fidelity (all ACs
> implemented) nor non-vacuousness (tests actually assert).** This milestone adds three gates that
> close that gap. Delivered via `/deliver`.

## Overview

Closure today = "verify-batch passed" = "tests green." That is silent on three things this milestone makes
machine-visible:

- **A — enforcement-visibility.** On an armed code-delivery run, a quality gate that *skips* for lack of
  project tooling (`Test:`/`Coverage:`/`Mutation:`) must not do so **silently**. Record the gaps in the
  marker and require an acknowledgement before a code batch closes — so "shipped with red-first / coverage
  / mutation OFF" is a logged decision, not an invisible default (parity with the precond-ack pattern).
- **B — completeness.** A closing batch's declared `task_ids` must be `[x]` in `tasks.md`; at milestone
  finalization no `[ ]` may remain and every `AC-N` in `spec.md` must be referenced by ≥1 test file.
  Catches "closed but undone / unimplemented spec part."
- **C — high-risk-seam ack.** The architecture review's highest-risk seams are recorded in the marker;
  closing a batch that touches a flagged seam requires a recorded ack naming the seam and the shipped
  commit — turning "named risk → named manual verification" from spoken discipline into a recorded step.

All three: marker-gated ⇒ in-session, git/artifact-grounded, `--self-test`, `shellcheck` clean, never a
false block on a non-delivery session. Honest boundary (stated up front): A/C acks are the human's
(presence enforced, honesty logged not proven — parity with `risk_rank`/precond); B's `[x]` is
orchestrator-set (the AC→test mapping is the machine-grounded half). None replaces mutation testing (F3)
as the judge of test non-vacuousness — they make its **absence** visible and force the decision.

## In scope

- **A — `bin/check-enforcement.sh`** (new `verify-batch` gate):
  - For an armed `intends_code` run, detect which quality dimensions are **unenforceable** on this project:
    red-first (no `Test:`), diff-coverage (no `Coverage:`), mutation (no `Mutation:` or `MutationMode` ≠
    `enforce`). Record them as `enforcement_gaps:[…]` in the RUN marker.
  - A code batch may not close while `enforcement_gaps` is non-empty and `enforcement_ack` ≠ `true`
    (same blocking-ack machinery as precond). Ack records the human's decision to ship with those OFF.
  - No gaps ⇒ pass. Not armed ⇒ skip.
- **B — `bin/check-completeness.sh`** (per-batch `verify-batch` gate **and** a `--final` mode):
  - Per closing batch: every `task_id` in the batch's ledger entry is checked `[x]` in
    `specs/<slug>/tasks.md` (slug from the marker `feature`). Any `[ ]` among them ⇒ fail.
  - `--final` (run by `/deliver` at milestone end, before declaring done): **no** `[ ]` remain in
    `tasks.md`, and **every** `AC-N` in `spec.md` is referenced by ≥1 **test-path** file (`is_test_path`).
    Unchecked task or AC-with-no-test ⇒ fail.
- **C — `bin/check-seam-ack.sh`** (new `verify-batch` gate) + the `architecture-reviewer` handoff:
  - `architecture-reviewer` emits `high_risk_seams:[{seam,paths}]`; the orchestrator records them to the
    marker (`high_risk_seams`).
  - Closing a batch whose files intersect a flagged seam's paths requires a `seam_acks` entry naming the
    seam and the batch's stamped commit — a recorded "read in the shipped code" (`file:line` + note).
    Missing ack for a touched seam ⇒ fail.
- Wire A, B(per-batch), C into `bin/verify-batch.sh`; wire B `--final` into `commands/deliver.md`'s
  end-of-run finalization. Marker schema + `agents-md-contract.md` + `enforcement.md` docs; version bump.

## Out of scope

- **Providing the test/coverage/mutation tooling** — the target project declares `Test:`/`Coverage:`/
  `Mutation:` (the immediate unblock for the DB project; the existing F1/F2/F3 then actually run). A only
  makes the *absence* loud, never invents tooling (P7).
- **Proving the acks are honest** — `enforcement_ack`, `seam_acks`, and `[x]` are recorded, blocking, and
  git/artifact-anchored where possible, but their truthfulness is the human's (parity with `risk_rank` /
  precond honesty). Machine enforces *presence and reference*, not consent.
- **Judging whether a test asserts the right behavior** — that is F3 (mutation); this milestone makes F3's
  skip visible (A) but does not re-implement it.
- **Auto-marking tasks `[x]`** — B reads `tasks.md`, never writes it.
- **CI enforcement** — marker-gated ⇒ in-session, like every peer gate.

## User stories

- **US1** (A) — As the founder, I want a delivery run with **no `Test:`/`Coverage:`/`Mutation:`** to
  **record and require acknowledgement** of that gap, so "we shipped with test-quality enforcement OFF"
  is a conscious, logged decision — not the silent skip that let the CAS bug through.
- **US2** (B) — As the founder, I want a batch that leaves its own `task_ids` unchecked, or a milestone
  with an **AC that no test references**, to **fail** — so post-review stops finding undone tasks and
  unimplemented spec parts.
- **US3** (C) — As the founder, I want the architecture review's **highest-risk seams** to require a
  recorded "read in the shipped code" ack before the touching batch closes — the manual verification the
  retrospective says I skipped on the CAS seam.
- **US4** — As an engineer, I want every gate to **skip cleanly** on a non-delivery session (no marker),
  never a false block.

## Acceptance criteria

- **AC-1** (US1, A) — armed run + no `Test:` command → `check-enforcement.sh` records `enforcement_gaps`
  containing `red-first` and **fails** (exit 1) until `enforcement_ack:true`; with the ack → exit 0.
  *(Fixtures: gap+no-ack → 1; gap+ack → 0.)*
- **AC-2** (US1, A) — all of `Test:`/`Coverage:`/`Mutation: enforce` present → no gap, exit 0. *(Fixture.)*
- **AC-3** (US2, B) — a closing batch whose ledger `task_ids` include an unchecked `[ ]` task in
  `tasks.md` → `check-completeness.sh` exit 1; all `[x]` → exit 0. *(Fixtures both sides.)*
- **AC-4** (US2, B) — `check-completeness.sh --final`: any remaining `[ ]` in `tasks.md`, or any `AC-N` in
  `spec.md` not referenced by a test-path file → exit 1; complete + all ACs referenced → exit 0. *(Fixtures.)*
- **AC-5** (US3, C) — with `high_risk_seams` recorded, closing a batch whose files intersect a seam's
  paths but with **no** matching `seam_acks` entry → `check-seam-ack.sh` exit 1; with an ack naming the
  seam + a commit that is **reachable from HEAD, post-baseline, and actually changed the seam's paths**
  (B5 — not merely resolvable) → exit 0; a resolvable-but-unrelated commit (e.g. the baseline) → exit 1;
  a batch touching **no** flagged seam → exit 0. *(Fixtures.)*
- **AC-6** (US4) — all three gates: no active `intends_code` marker ⇒ exit 0 (skip), identical to peers.
- **AC-7** — each ships `--self-test`; `check-gate-integrity.sh` clean (none green-by-skip; each fires);
  `shellcheck --severity=error bin/*.sh` clean; existing gate self-tests unregressed (no regression).
- **AC-8** — A, B(per-batch), C wired into `verify-batch.sh`; B `--final` invoked by `deliver.md` at
  finalization. `verify-batch.sh` on this repo still passes (gaps acked or tooling declared).

## Pre-resolutions (from the retrospective — founder rulings)

- **F1** — The gates that would have caught the CAS bug **exist** (P9/F2/F3); they **silently skipped** for
  lack of project tooling. The fix is to make that skip **loud and blocking**, not to rebuild the gates.
- **F2** — Same self-disarm class as v2.18.1: a gate that turns off when its input is absent, without a
  signal. Closure must never certify more than what actually ran (parity with the `GIT-VERIFIED [...]`
  anchor-enumeration principle).
- **F3** — Acks (`enforcement_ack`, `seam_acks`) and `[x]` are **recorded, blocking, referenced** — honesty
  is the human's, logged not proven. That is the accepted limit, stated, not silently assumed.
- **F4** — The immediate unblock for a real project is to **declare `Test:`/`Coverage:`/`Mutation:`** in its
  AGENTS.md so F1/F2/F3 run — a config step, out of this plugin's scope but documented.

## Open questions (for `/deliver` Step 3 — clarify)

- **OQ-1** (A) — Should high-risk batches (`risk_rank: run-rate|irreversible`) **hard-require** the tooling
  (no ack escape), while `feature`/`doc` allow the ack? RECOMMENDED: yes — tie enforcement strictness to
  `risk_rank`; the CAS bug was a run-rate reconciliation path. · web-verify: no.
- **OQ-2** (B) — AC→test reference match: exact `AC-N` string in a test file, or a looser map? RECOMMENDED:
  the literal `AC-N` (or a configurable `AcPattern:`) must appear in a test-path file. · web-verify: no.
- **OQ-3** (C) — Does `architecture-reviewer` reliably emit structured `high_risk_seams`, or does the
  orchestrator transcribe them? RECOMMENDED: add `high_risk_seams` to the reviewer's handoff schema; until
  then the orchestrator records them (prose→marker), and C enforces presence. · web-verify: no.
- **OQ-4** (C) — Seam↔batch intersection by file path is coarse (a batch touching the file but not the
  risky lines still needs an ack). RECOMMENDED: accept coarse (over-ask beats under-ask on the highest-risk
  seam); note it. · web-verify: no.

### Resolutions (Step 3 — clarify)

All four OQs are `web-verify: no` (no vendor/SDK/API surface — the gates are in-house bash mirroring
four existing peer gates), so each adopts its RECOMMENDED direction; no drift catch surfaced.

- **[x] OQ-1 → yes (risk-tied strictness).** `check-enforcement.sh` reads the in-flight batch's
  `risk_rank`; a `run-rate|irreversible` batch with any `enforcement_gaps` **hard-fails even with the
  ack** (no ack escape), while `feature|doc` may pass on `enforcement_ack:true`. The CAS bug was a
  run-rate reconciliation path — the strictest tier is where the silent skip cost the most (R1).
- **[x] OQ-2 → literal `AC-N`, `AcPattern:` configurable.** B's `--final` AC→test reference is satisfied
  when the literal token `AC-N` for each `AC-N` in `spec.md` appears in ≥1 `is_test_path` file. An
  optional `AcPattern:` (AGENTS.md/CLAUDE.md) overrides the `AC-[0-9]+` default for projects that label
  differently.
- **[x] OQ-3 → orchestrator records; C enforces presence.** `architecture-reviewer`'s handoff gains a
  `high_risk_seams:[{seam,paths}]` field (soundness mode); until every reviewer run emits it the
  orchestrator transcribes prose→marker (`high_risk_seams`). `check-seam-ack.sh` enforces *presence of a
  matching ack for a touched seam* regardless of which path recorded the seam (R4).
- **[x] OQ-4 → accept coarse path intersection (noted).** Seam↔batch intersection is by file path: a
  batch that touches a flagged seam's file but not its risky lines still needs the ack. Over-ask on the
  highest-risk seam is cheap; under-ask is what let the CAS bug through (R3). Noted as a known limit.

## Principles compliance matrix

| AC | Constitution | Verification |
|---|---|---|
| AC-1, AC-2 | P6, P10 | unenforced dims recorded + block until acked — no silent skip (declared ⇒ exercised) |
| AC-3, AC-4 | P9, P10 | task/AC completeness is machine-checked against tasks.md/spec.md + test references |
| AC-5 | P3, P11 | highest-risk seam requires a recorded, commit-anchored "read it" ack |
| AC-6 | P3 | marker-gated skip, identical to peers |
| AC-7, AC-8 | P8, P10 | self-tests + gate-integrity + shellcheck; wired + demonstrably fires |

## Risks

| # | Risk | L | I | Mitigation |
|---|---|---|---|---|
| R1 | A becomes an ack-rubber-stamp (operator always acks the gap) | H | M | OQ-1: hard-require tooling for run-rate/irreversible batches; the ack is *recorded and dated*, visible in post-review |
| R2 | B's `[x]` is self-report — orchestrator can check a box it didn't do | M | M | The AC→test reference (AC-4) is machine-grounded; `[x]` catches the *forgotten* box (the recurring symptom), not the lie |
| R3 | C over-asks (batch touches the file but not the risky lines) | M | L | Accepted (OQ-4): over-ask on the highest-risk seam is cheap; under-ask is what let the CAS bug through |
| R4 | C depends on `architecture-reviewer` emitting seams | M | M | OQ-3: orchestrator-records until the handoff schema carries `high_risk_seams`; C enforces presence regardless |
| R5 | More acks = more friction, operators route around `/deliver` | M | M | Keep skips clean on non-delivery sessions (AC-6); acks only on armed runs; the friction *is* the visibility |

## Dependencies

- Delivered artifacts: `bin/verify-batch.sh` gate list + finalization, `bin/delivery-lib.sh`
  (`resolve_marker`, field extractors, `is_test_path`, `shas_of_line`), `bin/check-preconditions.sh`
  (the `precond`-ack machinery this mirrors), `bin/check-tdd.sh`/`check-diff-coverage.sh`/`check-mutation.sh`
  (the skip-behavior A detects), `commands/deliver.md` (Phase-A arch review + finalization),
  `references/agents-md-contract.md`.
- Constitution **P6/P9/P10/P3/P11** governing; **P8** version-bump gate.
- Delivery: built via `/deliver` (recommended order A → B → C; A first, it directly closes the
  silent-skip root cause). Confirm sizing with `select-pipeline.sh`.
- **Operational (out of plugin scope, documented):** declare `Test:`/`Coverage:`/`Mutation: enforce` in the
  target project's AGENTS.md so the existing F1/F2/F3 run — the immediate unblock.
