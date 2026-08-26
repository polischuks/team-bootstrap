# Spec-Kit Pre-Implementation Flow — Universal Manual

A 6-step analytical + design sequence to run BEFORE implementation batches fire on any non-trivial milestone. Produces the artifact stack every implementer reads (spec → plan → tasks → dispatch), plus the doctrine-impact assessment that decides version bumps.

**Applies to any project** that has: (a) a versioned principles/constitution document, (b) a `specs/` (or equivalent) directory convention, (c) a git-backed workflow, (d) some form of subagent or delegated-implementer model.

**Why this flow?** Implementation cycles are expensive. Every wrong assumption caught at planning stage saves N implementation cycles + the cost of reverting bad work. The strongest metric of a milestone's health is the count of drift moments the flow surfaces BEFORE code lands.

## Where this fits in team-bootstrap

This is the **recommended first step** for any non-trivial team-bootstrap milestone.
team-bootstrap's pipelines ([mvp](pipelines/mvp.md), [full](pipelines/full.md),
[single-thread](pipelines/single-thread.md)) start from an *already-drafted* spec — this
flow is what produces that spec, plus the plan/tasks/dispatch stack that feeds them. Run
it first; then Step 6 emits paste-ready dispatch blocks the [orchestrator](orchestrator.md)
fires as implementation batches.

The six steps map onto the bundled `speckit-*` skills, which implement them:
`speckit-constitution` (Step 1) · `speckit-specify` (Step 2) · `speckit-clarify` (Step 3) ·
`speckit-plan` (Step 4) · `speckit-tasks` (Step 5) · `speckit-analyze` /
`speckit-taskstoissues` (cross-check + dispatch). Use the skills to execute each step; use
this manual as the doctrine and quality bar behind them.

> **Scaffolding (present in this repo):** [`constitution.md`](../constitution.md) (Step 1
> principles), [`specs/`](../specs/) with a milestone [`TEMPLATE/`](../specs/TEMPLATE/),
> [`feature.json`](../feature.json) (active-milestone pointer), and [`docs/adr/`](../docs/adr/).
> Copy `specs/TEMPLATE/` to `specs/NNN-slug/` to start a milestone and set `active_spec` in
> `feature.json`.

---

## Steps 1–5 are Spec Kit's, not ours

This file used to restate, in 180 lines, how to write a constitution, a spec, clarifications, a plan
and a task list. Spec Kit's own commands do that work, and a second description of it here could only
do one of two things: agree, and cost maintenance for nothing; or drift, and then be wrong somewhere
no one looks. The duplication is removed rather than kept in sync.

| Step | Command | Produces | What team-bootstrap adds |
|---|---|---|---|
| 1 Principles | `/speckit-constitution` | `constitution.md` | nothing — it is the project's own |
| 2 Spec | `/speckit-specify` | `spec.md` | the sizing signal (`bin/size-from-spec.sh` reads it) |
| 3 Clarify | `/speckit-clarify` | resolved open questions | nothing |
| 4 Plan | `/speckit-plan` | `plan.md` | the work-stream floors (`--per-batch`) |
| 5 Tasks | `/speckit-tasks` | `tasks.md` | `## ` sections become work-streams; `⚠ <role>` declares a role |
| — Check | `/speckit-analyze` | spec↔plan↔tasks consistency | nothing |

Two conventions in `tasks.md` ARE ours, because the harness parses them:

- A `## ` heading starts a **work-stream**, sized on its own paths. A `tasks.md` with none makes
  `size-from-spec.sh --per-batch` report `degraded=1` — no floors are derived and the batch diff sizes
  each batch alone.
- `⚠ <role>` on a task **declares** a review role. It is unioned into the required set and can never
  subtract from what the paths earned.

## The gate between Phase A and Phase B

This is the part that is team-bootstrap's and cannot be delegated: **what makes the artefacts
sufficient to start implementing.**

- The milestone is on disk. `spec_present` on the run marker is the on-disk truth, never the
  operator's claim — a path that does not resolve is a description, and Phase A runs in full for it.
- `/speckit-analyze` is clean: spec, plan and tasks agree.
- Every task carries its target paths. Without them the classifier sees nothing and sizes to the floor.
- The harness has sized the run. The verdict reaches the model as context
  (`bin/delivery-marker-init.sh`); it is not something to go and read out of `.runs/<id>/RUN`.

Phase B may not begin while any of these is unmet, and the harness does not take the orchestrator's
word for it: the gates read the artefacts.

## Step 6 — Team-Bootstrap Dispatch File

**Purpose**: Paste-ready dispatch blocks for orchestrator to fire implementation batches. Each batch is a self-contained subagent prompt.

**Deliverable**: `specs/NNN-milestone-slug/team-bootstrap-dispatches.md` (~600-2000 lines depending on batch count)

### Structure

- **Universal preamble** — pasted for each batch (discipline invariants, cumulative context, precedent files to read, doctrine constraints)
- **Per-batch blocks** — one paste-ready subagent prompt per batch containing:
  - Scope (which tasks in this batch)
  - Precedent files to read
  - Verification gate (which tests must pass)
  - Commit format (commit message template)
  - Final report shape (what the subagent must surface)
- **Order of execution + push cadence** — table showing batch → phase → track count → risk flag
- **Notes for orchestrator** — carry-forward items + lockstep risks + threshold verifications

### Batch decomposition patterns

| Milestone shape | Typical batch count | Track count |
|---|---|---|
| Small patch | 1-3 batches (may include parallel tracks) | 3-6 |
| Focused (single theme) | 6-10 batches | 10-20 |
| Mega (multi-theme) | 10-15 batches | 20-30 |

### Batch structuring rules

- **Single sequential subagent** — when coherence matters (data-layer coherence, agent skeleton + rubric together, canary helper + smoke tests)
- **Parallel tracks (2-4)** — when file trees are independent AND tasks are parallel-safe
- **Cross-batch dependencies** — surface explicitly (Phase 0 gate; ADR before principles PATCH; migration before repository code)
- **Single-file conflicts** — flag when 2 tracks would touch the same file; either sequence them or explicitly document merge strategy

---


## Implementation Loop Pattern (post-Step 6)

Not part of pre-impl, but the flow the dispatch file feeds into.

### Fire-batch cycle

```
Founder/orchestrator: signals "fire Batch N"
Orchestrator: dispatches subagent(s) per batch definition (parallel if multi-track)
Subagents: read precedents → verify sources → commit LOCALLY (never push)
Subagents: return report with commit SHA + drift findings + gate status
Orchestrator: reviews report → marks tasks.md [x] via chore commit → pushes batch commits after auth
```

### Batch closure commit format

Every batch closure chore commit includes:
- Task IDs shipped
- SHA references for parallel-track commits
- Numbered new discipline catches (#N-M)
- Cumulative catches counter update
- Phase → unblocks-Phase-N+1 dependency note

### Discipline invariants enforced

- **NEVER push to main without explicit auth** — orchestrator commits locally; founder authorizes pushes
- **Actual contracts > brief** — cumulative discipline catches counter grows each batch
- **Lockfile regeneration** if dependency file touched (avoid deploy failures)
- **Type checker + linter + formatter** mandatory before commit
- **Precedent files read** before drafting (mirror shape from prior work)

---

## Autonomy Modes

- **Fully autonomous** (steps 1-6) — orchestrator runs 6 steps back-to-back with push after each step; used when scope is well-understood
- **Step-by-step review** — founder fires each step manually; orchestrator surfaces report after each; used when scope is unclear or novel
- **Hybrid** — autonomous steps 1-3 (analysis + spec + clarify); founder reviews at Step 4 plan; autonomous steps 5-6

Choose based on:
- **Novelty**: Novel domain / vendor / architecture → step-by-step
- **Similarity to prior work**: If milestone mirrors precedent → fully autonomous
- **Risk profile**: High-risk (payments, security-critical) → step-by-step regardless of similarity
- **Founder availability**: Async / long-cycle → autonomous with explicit checkpoints

---

## Discipline Invariants (Universal)

Regardless of project domain, the flow enforces:

1. **Actual contracts > brief** — verify vendor claims + registry counts + type shapes against reality before writing prose
2. **Read-before-editing precedent** — mirror shape from most recent milestone artifacts
3. **Numbered discipline catches** — every drift finding gets a number + cumulative counter + explanatory prose
4. **NEVER push without auth** — orchestrator's job is to commit locally + surface state; founder/human authorizes pushes
5. **Type checker + linter + formatter** — mandatory before every commit
6. **Lockfile regeneration** — if dependency manifest touched, regenerate lockfile in same commit (prevent deploy drift)
7. **Precedent citation** — every task carries a `precedent: <SHA OR memory-marker>` reference — enables future readers to trace pattern lineage

---

## Adaptation Notes

To adapt this flow to a project different from the source:

### Replace project-specific terminology

- "Founder" → your product owner / lead / decision-maker role
- "Orchestrator" → whoever runs the meta-flow (could be human, could be primary agent)
- "Subagent" → whatever your delegated-implementer model is (could be humans, could be AI, could be both)

### Adapt to your version scheme

- Semver works out of the box (PATCH/MINOR/MAJOR)
- Calver, milestone-numbering, sprint-numbering all work — adapt Step 1 rationale prose

### Adapt to your artifact conventions

- If you don't have ADRs, treat plan.md's Related Decisions section as ADR-equivalent
- If you don't have a formal constitution, use whichever `principles.md` / `charter.md` / `styleguide.md` documents architectural invariants
- If you don't have a `feature.json` pointer, use `README.md` in the active spec directory to signal "current milestone"

### Adapt to your review model

- If you have PR-based review, per-track commits become PRs; batch closure = "merge queue"
- If you have trunk-based development, batch closure = squash-merge to main
- If you have release trains, batch closure = feature-flag rollout

### Cumulative catches metric

The "discipline catches counter" is the single strongest signal of the flow's value. Track it per-milestone AND cumulative. Falling numbers mean either:
- Scope is uncharacteristically simple (fine)
- Or discipline is slipping (investigate)

Rising numbers mean the flow is doing its job — surfacing drift before it becomes expensive.

---

## Summary

The flow's core value proposition: **shift verification cost from implementation phase to planning phase**. Each Step 3 web-verification catch saves N implementation cycles. Each Step 4 principles matrix guards against doctrine drift. Each Step 5 task-format invariant reduces reader cost across the milestone lifetime.

The flow assumes:
- The team values discipline over speed-to-implementation-start
- Drift is expensive enough to justify pre-verification investment
- The orchestrator has bandwidth to run analytical steps before firing subagents

If those assumptions hold, this 6-step sequence pays for itself after the first milestone.
