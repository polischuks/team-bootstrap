# 0005 — Closure must certify fidelity + non-vacuousness, not just "tests green"

- **Status:** Accepted
- **Date:** 2026-08-17
- **Constitution clause(s):** P6, P9, P10, P3, P11

## Context

A post-delivery retrospective found a HIGH bug — a CAS reconciliation predicate `IN (owed-set)` where the
candidates were `= 'done'`, so the `UPDATE` matched 0 rows and looped forever — that **passed every gate**
and was caught only by an independent post-review. Sharpened, the root cause was not a missing gate but
**three disarmed ones**: P9 red-first (`check-tdd`), F2 diff-coverage (`check-diff-coverage`), and F3
mutation (`check-mutation`) all **silently skipped** because the project declared no `Test:`/`Coverage:`/
`Mutation:` tooling. The bug slipped through gates that were *off*, not *absent* — the same
self-disarm-on-absent-input class as the v2.18.1 marker-whitespace bug.

Two adjacent gaps compounded it: closure certifies **mechanics** (`code_delta` > 0 + gates green), but is
silent on **fidelity** (are the batch's declared tasks actually done, is every acceptance criterion
exercised by a test?) and on the **named-but-unread high-risk seam** (the CAS predicate was exactly such a
seam; the manual "read it in the shipped code" step was skipped).

## Decision

Add three `verify-batch` gates, each mirroring the existing peer-gate contract (marker-gated ⇒ in-session,
git/artifact-grounded, `--self-test`, `shellcheck` clean, never a false block on a non-delivery session):

- **A — [`check-enforcement.sh`](../../bin/check-enforcement.sh).** On an armed code run, detect which
  quality dimension is unenforceable (no `Test:`→`red-first`, no `Coverage:`→`diff-coverage`, no
  `Mutation:`/`MutationMode≠enforce`→`mutation`), record `enforcement_gaps` in the RUN marker, and **block
  a code batch from closing** until `enforcement_ack:true`. A `run-rate|irreversible` batch **hard-fails**
  on any gap regardless of the ack (OQ-1) — the strictest tier is where the silent skip cost the most.
  "Shipped with test-quality enforcement OFF" becomes a logged, dated decision, never an invisible default.
- **B — [`check-completeness.sh`](../../bin/check-completeness.sh).** Per batch: every `task_id` in the
  in-flight ledger entry must be `[x]` in `specs/<slug>/tasks.md` (reads it, never writes it). `--final`
  (run by `deliver.md` at milestone end): **no** `[ ]` may remain and **every** `AC-N` in `spec.md` must
  appear in ≥1 `is_test_path` file (`AcPattern:` configurable). Catches "closed but undone / unimplemented".
- **C — [`check-seam-ack.sh`](../../bin/check-seam-ack.sh).** The architecture review records its highest-
  risk seams to the marker (`high_risk_seams:[{seam,paths}]`); a batch whose files intersect a flagged
  seam's paths must carry a `seam_acks` entry naming the seam + a resolvable commit — a recorded
  "read it in the shipped code". Turns "named risk → named manual verification" into a recorded step.

The gates are wired into [`verify-batch.sh`](../../bin/verify-batch.sh) (A, B-per-batch, C) and B `--final`
into [`deliver.md`](../../commands/deliver.md)'s finalization. The A/C acks are the human's (recorded,
blocking, git-anchored where possible; honesty logged not proven — parity with `risk_rank`/precond). B's
`[x]` is orchestrator-set; its **AC→test reference** is the machine-grounded half. None replaces mutation
testing as the judge of assertion strength — they make its **absence** visible and force the decision.

## Consequences

- The silent skip that let the CAS bug through is now **loud and blocking**: on a project with no
  `Test:`/`Coverage:`/`Mutation:`, a code batch cannot close without a recorded acknowledgement (or
  declaring the tooling — the immediate unblock, F4).
- This milestone **dogfooded all three on itself**: A flagged this bash-gate repo's three gaps (acked,
  feature-rank); B verified each batch's own task_ids `[x]` and the milestone's AC→test coverage at
  `--final`; C required (and got) a `seam_acks` entry on B3, which touched the recorded `marker-rewrite`
  seam. Building A's marker rewrite even surfaced a real bash-5.2 `${//}` backslash-leak bug in the
  marker-write path — the exact seam C guards — now regression-locked (R6).
- The honest limit (stated, not assumed): A/C acks and B's `[x]` are **recorded, blocking, referenced** —
  their truthfulness is the human's, not the machine's.

## Alternatives considered

- **Rebuild the skipped gates so they can't skip** — rejected (F1): the gates exist and are correct; the
  fix is to make the *skip* loud and blocking, not to re-implement P9/F2/F3.
- **Auto-mark tasks `[x]` / auto-provide coverage tooling** — rejected: B reads `tasks.md`, never writes
  it; providing test/coverage/mutation runners is the target project's job (P7), documented (F4), not this
  plugin's scope. A only makes the absence loud.
- **Prove the acks are honest** — out of scope: presence + reference is enforced, consent is the human's
  (parity with the `risk_rank`/precond honesty boundary).
