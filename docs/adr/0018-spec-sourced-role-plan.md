# ADR-0018 — Spec-sourced role planning

- Status: Accepted
- Date: 2026-08-25
- Milestone: `spec-sourced-role-plan` (v2.33.0)
- Supersedes in part: [ADR-0017](0017-harness-owned-pipeline-sizing.md) — this is its missing front half.

## Context

ADR-0017 made sizing harness-owned but sourced it from the **batch diff**, which is only readable
after the code is written. The decision it informs — how many independent reviewer subagents to
dispatch — has to be made before that.

`/deliver` made it earlier still, and badly. Three verified defects:

1. **The tier came from the first argument token, with `full` as the fallback.** A path to a milestone
   is never the literal word `mvp` or `full`, so `/deliver specs/<slug>/spec.md` selected the 20-role
   pipeline every time, mechanically, with no way for the operator to ask for anything else short of
   typing a tier by hand.
2. **The tier was grepped from the whole prompt.** A slug that merely contained a tier word decided
   the tier: `specs/full-text-search` bought twenty roles.
3. **Phase A had no existing-spec branch** and was documented as "in order, no skipping". All eight
   steps — including `speckit-specify`, whose job is to *draft the spec* — ran against milestones whose
   `spec.md`, `plan.md` and `tasks.md` were already on disk.

Two measured runs against an already-written spec spent **2h21m** in Phase A (six
`architecture-reviewer` passes, spec revisions to v5/v6) before any code, ran 3h45m and 3h56m, and
neither finished the milestone.

The default also contradicted the plugin's own architecture documentation, which calls `single-thread`
*"the recommended default"* and states that roles there are *"activated as output styles at phase
boundaries — not as separate agents with private context"* because that matches where SOTA autonomous
coding agents converged. `/deliver` was the one surface overriding the architecture it shipped with.

## Decision

**The harness decides which roles run, by evaluating the spec.**

1. **A spec path is a machine fact.** `delivery-marker-init.sh` resolves the argument and records
   `spec_path`, `spec_present`, `spec_artifacts` (sha256 per artifact), `tier_source` and `sizing`.
   `spec_present` is on-disk truth, never the operator's claim.
2. **The spec is the sizing input.** `bin/size-from-spec.sh` reads the paths `tasks.md` names and
   delegates classification to `select-pipeline.sh`'s existing `recommend()`. There is no second copy
   of the risk classifier. Task count substitutes for the unavailable line-count signal and lifts only
   as far as `mvp`; escalation to `full` stays owned by the risk signals.
3. **The plan is per work-stream, not per milestone.** A blanket milestone tier would restore the
   uniform fan-out ADR-0017 existed to end. `--per-batch` emits one entry per `tasks.md` section, so a
   docs stream and an auth stream get different role sets inside one milestone.
4. **Authority order: plan floors, diff lifts, invariant blocks.** The spec-sourced tier is a floor;
   the diff-sourced `required_roles_for_batch` may raise it and never lower it; the ≥1
   independent-reviewer floor is untouched by either.
5. **`auto` replaces `full` as the fallback**, and is safe by construction: every reader exempts only
   `single-thread` and fails closed on anything else, so an unresolved tier enforces the strictest
   posture rather than opening a bypass.
6. **Phase A splits on `spec_present`.** Mode 2 runs the *checking* steps and skips the *producing*
   ones. Re-checking finished work is cheap and load-bearing; re-producing it is pure cost.

## Enforceability ceiling

**The Phase A skip cannot be observed directly.** `record-dispatch.sh` matches `Agent|Task`, and
`speckit-specify` is a **Skill** — its invocation is invisible to the harness. Mode 2 is therefore
prose, and prose lands ~70% of the time against a hook's ~100% (`references/enforcement.md`).

The workaround observes the **artifact** rather than the call: hashed at run start, compared by
`check-preflight`. That detects an unjustified *rewrite*; it does not detect a wasteful *re-read*.
The residual gap is real and is stated here rather than papered over. Drift is **WARN** for one
release — revising a spec mid-flight is legitimate, and shipping a block on an unvalidated heuristic
would reproduce the false-block class ADR-0015 spent a milestone removing.

## Consequences

- Passing a finished milestone no longer buys twenty roles by accident.
- Sizing is visible: the Phase B gate prints the verdict and its reasons, so it can be challenged.
- Two fail-opens found while wiring this, both pre-existing and both affecting diff-sourced sizing:
  three risk categories matched only the nested directory form, so root-level `api/`, `models/` and
  `.github/workflows/` changes did not escalate; and an all-doc change tripped the layer thresholds
  and bought `mvp` or `full` for documentation.
- What is NOT fixed: the best-practices brief pull rule remains prose, and Phase A's own step count is
  not yet sized for the description form.
