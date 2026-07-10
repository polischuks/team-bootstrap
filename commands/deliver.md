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
7. **Role `architecture-reviewer` (`review_mode: soundness`)** — an independent review of `plan.md`
   against the project's [architecture baseline](../references/architecture-baseline.md): is the
   *planned* architecture correct and does it fit the app as a whole? `analyze` checks that the
   artifacts agree with each other; this checks that the architecture is actually sound.

**Gate before Phase B:** print a short summary — spec/plan/tasks paths, task count, version-bump
verdict, drift catches, and any unresolved blocker. **STOP here** if `speckit-analyze` surfaced a
CRITICAL inconsistency, any question is still open, or `architecture-reviewer` returned
`architecture_sound: false` — fix the plan before any batch fires. Do not enter Phase B with
unresolved blockers.

---

## Phase B — Implementation, batch-by-batch (step-by-step, human-paced)

Decompose the task list into batches per the flow's Step 6 batch rules. **Prefer vertical slices
over horizontal layers:** a batch should deliver one working end-to-end path (e.g. endpoint +
the frontend that calls it + the wiring), not "all backend" then "all frontend." Horizontal
slicing is what produces an endpoint with no consumer — dead code that each builder reports as
done. Only split a slice across batches when a genuine dependency forces it, and then name the
cross-batch wiring explicitly.

Then, for **each batch, one at a time**:

1. **Announce** the batch: which task IDs, which files, the verification gate, and the commit
   format.
2. **WAIT** for the user to confirm (e.g. "fire" / "continue"). Do **not** auto-run the next
   batch — this is step-by-step by design.
3. On confirmation, run the batch through the chosen pipeline:
   `/team-bootstrap PIPELINE "<batch scope: cite the task IDs + point at spec.md/plan.md/tasks.md>"`
4. Subagents **commit locally only**. Never `git push` or deploy without explicit per-call
   authorization (constitution P5 / irreversibility).
5. **Integration gate (hard).** The pipeline's `integration-verifier` runs after the builders,
   with a clean context: it executes the E2E command from `AGENTS.md` and scans for orphans
   (any endpoint/component the batch produced with no live consumer). **Do not mark the batch
   done, and do not present the next batch, while `orphans_found > 0` or the E2E path fails.**
   Send the orphan back to the builder; after 3–5 failed attempts, **stop and ask the human**
   (rollback the batch's local commits rather than shipping unwired code). Outcome over
   self-report: trust the verifier's run, not the builders' "done."
   Then the **architecture conformance gate (hard):** `architecture-reviewer` (`review_mode:
   conformance`) runs the fitness functions against the [baseline](../references/architecture-baseline.md)
   — a batch can pass E2E and still **drift** (wrong layer, bypassed boundary). Do not close the
   batch while `drift_findings > 0`; send drift back to the builder, 3–5 attempts → human / rollback.
6. After the batch **passes the gate**: mark its tasks `[x]` in `tasks.md`, report commit SHA(s),
   the verifier's result (E2E + 0 orphans), and any drift catches. Then present the **next**
   batch and **WAIT** again.

Stop after the final batch, or whenever the user says stop. At the end, summarize: batches shipped,
tasks closed vs deferred, and what still needs a human (push authorization, prod deploy, open risks).

---

**Right-sizing note:** this command is for non-trivial milestones. For a single small change,
skip it and run `/team-bootstrap single-thread "<task>"` directly.
