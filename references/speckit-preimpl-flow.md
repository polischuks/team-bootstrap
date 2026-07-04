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

## Prerequisites

Before running the flow, the project needs:

1. **A principles document** (call it `principles.md` or `constitution.md`) — versioned; documents architectural invariants, sanctioned exceptions, and boundary rules
2. **A `specs/` directory convention** — one subdirectory per milestone, using stable naming (`NNN-milestone-slug/`)
3. **An ADR directory** — for architectural decisions that outlive individual milestones
4. **A stable milestone version scheme** — semver works; PATCH for fixes-only, MINOR for new features, MAJOR for breaking changes
5. **A feature-pointer file** — something like `feature.json` that points to the current active spec directory
6. **A precedent chain** — completed milestones you can mirror structure from (bootstrap with first-milestone template from a similar project)

---

## Step 1 — Principles / Constitution Analysis

**Purpose**: Determine if the milestone requires principles/constitution evolution BEFORE spec drafting. Pure analytical — no code changes.

**Deliverable**: `docs/mNN-principles-analysis.md` (~100-200 lines)

### Sections

1. **Existing doctrine coverage assessment** — for each scope item, classify impact:
   - **No impact** (implementation-only; doctrine already sanctions the primitive)
   - **PATCH bump** (clarification / extension without rule redefinition)
   - **MINOR bump** (new doctrine section OR new principle)
   - **MAJOR bump** (breaking change — rare)
2. **ADR candidates** — enumerate NEW ADRs that should land in Phase 1
3. **Version bump recommendation** — pick a single option with explicit rationale
4. **Enumeration invariant checks** — if principles reference specific lists (sanctioned dependencies, allowed vendors, approved patterns), verify current count + expected delta
5. **Registry impact assessment** — new components add rows to registries (vendor lists, tool taxonomies, sub-processor manifests)
6. **Verdict + recommended action** — final version target + proceed-or-pause

### Discipline

- Read the existing principles document IN FULL — not summarize from memory
- Verify claims via grep/rg — if the principles reference N sanctioned instances, count actual instances in codebase before claiming threshold
- Cross-check against ADRs — some architectural decisions constrain scope
- Surface hidden invariants — "we've done X 4 times, doing X 5 times triggers doctrine documentation" is a common pattern

### Common outcomes

- **No bump** — hardening/patch milestones typically qualify
- **PATCH bump** — new sanctioned enumeration entry (new agent type, new tool category)
- **MINOR bump** — new doctrine section (new action class, new enforcement rule)
- **MAJOR bump** — restructuring existing invariants (rare)

---

## Step 2 — Spec Drafting

**Purpose**: Draft the milestone specification. Bake founder/orchestrator rulings from Step 1 as pre-resolutions.

**Deliverable**: `specs/NNN-milestone-slug/spec.md` (~300-900 lines depending on scope)

### Standard sections

- **Overview + In/Out of scope** — bounded scope; explicit exclusions
- **User Stories (US1-N)** — one per deliverable + perspective stories (agent/auditor/operator)
- **Acceptance criteria (AC-1..AC-N)** — each CI-testable OR QA-verifiable; grouped by US
- **Pre-resolutions (F1-N)** — verbatim from Step 1 rulings (founder/product decisions that constrain scope)
- **Open questions (OQ-1..OQ-N)** — items for Step 3 to resolve; include RECOMMENDED direction for each
- **Principles compliance matrix** — every AC → doctrine clause + verification approach
- **Risks table** (≥8 rows) — vendor uncertainty, scope creep, technical unknowns
- **Dependencies** — prior milestones + external services + timing constraints

Also updates the feature-pointer file to reference the new spec directory.

### Discipline

- Mirror structure verbatim from most recent spec — consistent shape reduces reader cost
- OQ prose includes RECOMMENDED direction — makes Step 3 autonomous resolution viable
- Web-verifiable OQs get explicit flags for Step 3 to check (vendor SDK names, endpoints, auth models)
- Every AC is testable by an automated check OR named human verification step

---

## Step 3 — Clarify (Autonomous OQ Resolution)

**Purpose**: Pre-resolve OQ-1..OQ-N with defaults + web-verify vendor claims. Add F+1 rows if new founder-relevant decisions emerge from verification.

**Deliverable**: modified `spec.md` — OQ section marked `[x] Resolution:` per item

### Pattern

For each OQ:
1. Read the RECOMMENDED direction from Step 2
2. WebFetch vendor API docs to verify auth model, endpoint shape, SDK availability
3. Mark `[x] Resolution: <default>` + 1-2 sentence rationale
4. If verification surfaces drift (API deprecated, endpoint changed, SDK doesn't exist), **OVERRIDE** default + document the drift inline as a numbered discipline catch

### Drift catch pattern

The strongest value of Step 3 is web-verifying vendor claims that would otherwise become expensive implementation mistakes:

- **SDK availability** — "vendor X has a Python SDK" (verify — sometimes vendor only publishes JS SDK)
- **API deprecation** — "we'll use API endpoint /v1/foo" (verify — endpoint may have been retired)
- **Auth model** — "use OAuth" (verify — may be admin-consent-only, not user-OAuth)
- **Version pins** — "SDK version ^1.0" (verify — actual latest may be 0.3.x)
- **Feature availability** — "extension supports X-dimension vectors" (verify — real support may have hard caps)

Each drift catch is numbered + logged in commit body — they compound into a milestone-wide discipline signal.

### F+1 flag

If verification surfaces a decision that needs a founder/orchestrator review (e.g., "sub-agent split needed", "vendor choice unclear"), add F+1 row in pre-resolutions with prose explaining trigger. Escalate before Step 4.

---

## Step 4 — Plan

**Purpose**: Design architecture + phase decomposition. 6 artifact files ship together for internal coherence.

**Deliverables** in `specs/NNN-milestone-slug/`:

1. **plan.md** (~400-1000 lines) — Principles compliance matrix + architecture diagrams (sequence, dependency) + N-phase plan + dependency DAG + ADR candidates + migration shape (if applicable)
2. **data-model.md** (~200-600 lines) — Schema changes (migration up + down); access control posture per table; type extensions; constraint changes
3. **research.md** (~150-300 lines) — Numbered decisions traced to pre-resolutions + resolved OQs + surfaced catches
4. **contracts/api.md** (~150-400 lines) — External-facing route contracts; endpoints; auth; error envelopes
5. **contracts/tools.md** OR **contracts/interfaces.md** (~100-500 lines) — Internal component contracts; scope changes; registry impacts
6. **quickstart.md** (~150-300 lines) — Operator walkthrough (real usage sequence, not test scenarios)

### Critical plan-level decisions to document

- Component scope changes (if size caps constrain — split vs bundle)
- Migration split vs single (rollback isolation)
- Doctrine threshold checks (are we approaching invariant limits?)
- ADR candidates (which land in Phase 1 vs deferred)
- Failure mode classification (per action class or per critical path)
- Compliance matrix (doctrine → AC → CI test binding)

### Discipline

- Actual contracts > brief — verify claim counts via `rg -n` before writing
- Precedent files read fully — mirror structure from most recent plan; preserves reader intuition
- Phase decomposition includes explicit lockstep risks (e.g., Phase 0 gates Phase 1)

---

## Step 5 — Tasks

**Purpose**: Decompose plan into numbered actionable tasks with strict formatting invariants.

**Deliverable**: `specs/NNN-milestone-slug/tasks.md` (~300-800 lines)

### Task entry format

Each task follows this template:

```markdown
- [ ] Txxx [P?] [USx?] Description
  - Explicit file path(s) within
  - (category · principle) suffix — category ∈ {foundation, backend, frontend, data, security, docs, infra}
  - AC-N pointer (which acceptance criterion this task satisfies)
  - **precedent: <commit-sha OR memory-marker>** — cite prior milestone precedent
  - — depends on TyyyTzzz chain
  - **⚠ {reviewer-type} flag** where applicable (data-schema-reviewer / security-reviewer / etc.)
```

Where:
- `[P]` = parallelizable within phase
- `[USx]` = ties task to user story from spec
- `category` = which subsystem this touches
- `principle` = which principle(s) this task upholds

### Structure

- Header (Status / Source plan / Source spec / Principles version pin / Total tasks / Effort estimate)
- Conventions section (explaining task ID scheme + tags)
- Dependency diagram (Mermaid or similar)
- Linear sequence (critical path — what MUST be sequential)
- Hard front gates (blocks all subsequent work)
- Per-phase sections (grouped tasks)
- Dependencies & parallelization (within-phase lanes; critical seams)
- Story completion order (which US closes when)
- Out-of-scope / deferred (explicit)
- Risk register (≥8 rows for focused milestone; ≥12 for large)
- Risk-flagged tasks (mandatory reviewer types)
- Final exit criteria (release gate checklist)

### AC mapping coverage

Every AC-N from spec.md MUST map to ≥1 task. Grep-verify before commit. If any AC has no task, either the spec is over-specified or the task list is incomplete.

---

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
