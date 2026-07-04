---
description: One command — run the full pre-implementation flow (speckit constitution→specify→clarify→plan→tasks→analyze), then drive implementation batches step-by-step through a team-bootstrap pipeline (mvp or full).
argument-hint: <mvp|full> "<feature description>"
---

You are the delivery orchestrator. Input: `$ARGUMENTS`.

**Parse the arguments:**
- First whitespace-delimited token = `PIPELINE` — must be `mvp` or `full`. If the first token
  is not one of those, treat `PIPELINE = mvp` and the whole of `$ARGUMENTS` as the feature.
- The remainder (the quoted string) = `FEATURE` — the thing being built.

Use `${CLAUDE_PLUGIN_ROOT}/references/speckit-preimpl-flow.md` as the doctrine and quality bar
for every step below (constitution invariants, drift-catch discipline, AC→task coverage, "never
push without auth"). If that path is unavailable, follow the same 6-step discipline from memory.

---

## Phase A — Pre-implementation (autonomous, in order, no skipping)

Run each step by invoking the matching skill via the Skill tool. Do not stop between steps
unless a step reports a hard blocker.

1. **Skill `speckit-constitution`** — establish/verify project principles. Record the
   version-bump verdict (Step 1).
2. **Skill `speckit-specify`** with `FEATURE` — draft the spec (Step 2).
3. **Skill `speckit-clarify`** — resolve open questions; web-verify vendor/SDK/API claims and
   log each drift catch (Step 3).
4. **Skill `speckit-plan`** — architecture, phase decomposition, compliance matrix (Step 4).
5. **Skill `speckit-tasks`** — numbered tasks; every acceptance criterion maps to ≥1 task (Step 5).
6. **Skill `speckit-analyze`** — cross-artifact consistency guard (spec ↔ plan ↔ tasks).

**Gate before Phase B:** print a short summary — spec/plan/tasks paths, task count, version-bump
verdict, drift catches, and any unresolved blocker. If `speckit-analyze` surfaced a CRITICAL
inconsistency, or any question is still open, **STOP here** and surface it. Do not enter Phase B
with unresolved blockers.

---

## Phase B — Implementation, batch-by-batch (step-by-step, human-paced)

Decompose the task list into batches per the flow's Step 6 batch rules (single sequential batch
when coherence matters; parallel tracks only when file trees are independent and tasks are
parallel-safe; surface cross-batch dependencies).

Then, for **each batch, one at a time**:

1. **Announce** the batch: which task IDs, which files, the verification gate, and the commit
   format.
2. **WAIT** for the user to confirm (e.g. "fire" / "continue"). Do **not** auto-run the next
   batch — this is step-by-step by design.
3. On confirmation, run the batch through the chosen pipeline:
   `/team-bootstrap PIPELINE "<batch scope: cite the task IDs + point at spec.md/plan.md/tasks.md>"`
4. Subagents **commit locally only**. Never `git push` or deploy without explicit per-call
   authorization (constitution P5 / irreversibility).
5. After the batch returns: mark its tasks `[x]` in `tasks.md`, report commit SHA(s), the gate
   status, and any new drift catches. Then present the **next** batch and **WAIT** again.

Stop after the final batch, or whenever the user says stop. At the end, summarize: batches shipped,
tasks closed vs deferred, and what still needs a human (push authorization, prod deploy, open risks).

---

**Right-sizing note:** this command is for non-trivial milestones. For a single small change,
skip it and run `/team-bootstrap single-thread "<task>"` directly.
