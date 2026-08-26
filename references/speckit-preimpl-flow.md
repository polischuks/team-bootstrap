# Spec-Kit Pre-Implementation Flow — Universal Manual

A 6-step analytical + design sequence to run BEFORE implementation batches fire on any non-trivial milestone. Produces the artifact stack every implementer reads (spec → plan → tasks → dispatch), plus the doctrine-impact assessment that decides version bumps.

**Applies to any project** that has: (a) a versioned principles/constitution document, (b) a `specs/` (or equivalent) directory convention, (c) a git-backed workflow, (d) some form of subagent or delegated-implementer model.

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

The two `tasks.md` conventions the harness parses are ours; they are the first two rows of the
Phase-A→B contract table below, with what each failure costs.

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

## What Phase B needs from Phase A

Dispatch blocks used to be a seventh step described here in ~60 lines. They are produced by
[`/team-bootstrap:deliver`](../commands/deliver.md) and shaped by
[`references/orchestrator.md`](orchestrator.md) and [`references/subagent-dispatch.md`](subagent-dispatch.md);
restating their shape here could only agree at a maintenance cost, or drift and be wrong in the copy
nobody opens. What belongs here is the **contract between the phases**, which those files consume:

| Phase A produces | Phase B reads it through | Fails how, if absent |
|---|---|---|
| `tasks.md` `## ` headings | `size-from-spec.sh --per-batch` → work-stream floors | `degraded=1 reason=no-ws-headings`; each batch sized by its diff alone |
| `file:` lines on each task | the path classifier → risk categories → roles | no signal; the batch sizes to the invariant floor |
| `⚠ <role>` declarations | `required_roles_for_batch` (union, never subtraction) | the role is simply not added |
| spec/plan prose | `_prose_reasons` → the tier the paths cannot see | the exactly-once blind spot returns (ADR-0019) |

## Discipline invariants

Enforced by the harness, not by this document — each line names what enforces it:

1. **Red before green, per batch** — `bin/check-tdd.sh` (`--record-red` observes it; the gate verifies
   the ordering against git).
2. **Never push without authorisation** — `bin/guard-git.sh` refuses a default-branch write and
   escalates a history rewrite to a human.
3. **Every task carries `precedent:`** — a SHA or a memory marker, so a future reader can trace the
   pattern's lineage. Convention, not gate.
4. **Typecheck + lint before completion** — `bin/quality-gate.sh` on the `Stop` hook.
5. **Closure from git state** — `bin/check-delivery.sh`; a batch closes on commits reachable from HEAD
   and after the run baseline (ADR-0002), never on an assertion.
6. **Assigned roles actually ran and answered** — `bin/check-role-dispatch.sh` and
   `bin/check-role-verdict.sh`.

## Autonomy modes

- **Fully autonomous** — the six steps run back to back. Use when the milestone mirrors precedent.
- **Step-by-step** — each step is fired manually and reported on. Use for a novel domain, an unfamiliar
  vendor surface, or anything high-risk (payments, auth, migrations) regardless of similarity.
- **Hybrid** — autonomous through clarify, human review at the plan, autonomous through tasks.

The tier the harness assigns is a *review-depth* decision and is independent of this choice; do not use
autonomy mode as a proxy for it.

## Adapting this to another project

The flow is not team-bootstrap-specific. Three substitutions cover most of it: your decision-maker role
for "founder", whatever runs the meta-flow for "orchestrator", and whatever your delegated implementer
is for "subagent". Semver is assumed but calver and sprint-numbering work unchanged. Without ADRs, the
plan's decisions section is the equivalent; without a constitution, whichever file records your
architectural invariants.

## Why the flow pays for itself

It shifts verification cost from implementation to planning. Every drift caught at Step 3 or Step 4
saves the implementation cycles that would have gone into building on the wrong assumption, plus the
cost of unwinding them. The count of drift moments a milestone surfaces **before** code lands is the
metric worth tracking; rising numbers mean the flow is working, and falling ones mean either an
unusually simple scope or slipping discipline — the two are distinguishable only by looking.
