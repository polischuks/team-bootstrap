---
description: One command — run the full pre-implementation flow (speckit constitution→specify→clarify→plan→tasks→analyze), then drive implementation batches step-by-step through a team-bootstrap pipeline (mvp or full).
argument-hint: <full|mvp> "<feature description>"  (default: full)
---

You are the delivery orchestrator. Input: `$ARGUMENTS`.

**Parse the arguments:**
- First whitespace-delimited token = `PIPELINE` — must be `mvp` or `full`. If the first token
  is not one of those, treat `PIPELINE = full` (the safer default — full role coverage + audit
  trail) and the whole of `$ARGUMENTS` as the feature. Pass `mvp` explicitly for the lighter pipeline.
- The remainder (the quoted string) = `FEATURE` — the thing being built.

Use `${CLAUDE_PLUGIN_ROOT}/references/speckit-preimpl-flow.md` as the doctrine and quality bar
for every step below (constitution invariants, drift-catch discipline, AC→task coverage, "never
push without auth"). If that path is unavailable, follow the same 6-step discipline from memory.

---

## Phase A — Pre-implementation (autonomous, in order, no skipping)

Run each step by invoking the matching skill via the Skill tool. Do not stop between steps
unless a step reports a hard blocker.

0. **Run marker (enrichment).** The harness `UserPromptSubmit` hook
   (`${CLAUDE_PLUGIN_ROOT}/bin/delivery-marker-init.sh`) already wrote `.runs/<run>/RUN`
   (`intends_code:true`, `baseline_sha`) when this `/deliver` was submitted — that marker is the
   machine fact "a delivery run is active", and it is what makes every gate fail-**closed** instead of
   skipping (`check-delivery.sh`, the Stop hook). **Do not rely on writing it yourself** — it is
   harness-owned so skipping a step cannot disable the gate (see `references/enforcement.md`). Here you
   only *enrich* it: confirm/append `pipeline`, `feature`, and (after step 8's precondition) `precond`.
   If the marker is somehow absent (older harness without the hook), create it now so Phase B is gated.
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
8. **Best-practices briefs (novelty-gated, pulled per-batch).** For each **novel/risky domain** the
   tasks touch (unfamiliar tech, security-/data-sensitive, external vendor/SDK, new pattern), dispatch
   `discovery-research` as a clean-context subagent to produce a **best-practices brief** (once per
   domain, cached on the blackboard) so builders implement against current practice, not stale
   memory. Skip familiar/in-house domains and **log the skip**. Use `tavily-research` and distill —
   ~5–15K tokens per domain ([../references/best-practices-research.md](../references/best-practices-research.md)).
   **Pull, don't front-load:** produce a domain's brief when the first batch touching it fires in
   Phase B — not all briefs here before any delivery. Front-loading 100% of analysis before 0% of
   delivery is the failure this avoids; the load-bearing code leads and the analysis it needs arrives
   with it. Here in Phase A, do only the briefs the earliest batches need.

**Gate before Phase B:** print a short summary — spec/plan/tasks paths, task count, version-bump
verdict, drift catches, and any unresolved blocker. **STOP here** if `speckit-analyze` surfaced a
CRITICAL inconsistency, any question is still open, or `architecture-reviewer` returned
`architecture_sound: false` — fix the plan before any batch fires. Do not enter Phase B with
unresolved blockers.

**Deliverability precondition (hard).** Run `${CLAUDE_PLUGIN_ROOT}/bin/check-preconditions.sh` — the
ten-second `git ls-remote` that belongs at the plan, not after the files are written: remote reachable,
current branch on the remote / diverged, a build-from-git deploy source and which branch it builds,
and whether publication needs authorization. **Exit 1 (hard) STOPS** — delivery cannot land, fix it
before any batch. **Exit 2 (advisory)** must be **surfaced and acknowledged** before Phase B (e.g. "the
deploy builds from `main` and this branch isn't pushed"). Do not plan a route into a wall and walk to
the wall.

`check-preconditions.sh` **records** an exit-2 advisory into the run marker
(`precond:{exit:2,items:[…],ack:false}`). This is a **blocking machine fact**, not a spoken note:
`check-delivery.sh` fails any run that has announced a batch while `precond.exit==2 && precond.ack!=true`.
To acknowledge, surface the advisory to the human and, on their go-ahead, set `precond.ack:true` in
`.runs/<run>/RUN` — then Phase B may announce batch 1. (Presence of the ack is enforced; its *honesty*
is the human's, logged not proven — parity with `risk_rank`.)

**Right-sizing (advisory).** Pipeline choice is the one high-leverage call left to the operator, and the
same "just ship it" pressure that skips review also picks the *lighter* pipeline. Run
`${CLAUDE_PLUGIN_ROOT}/bin/select-pipeline.sh --chosen PIPELINE` against the change scope (it sizes the
diff — files, non-doc lines, layers, and risk touches: security/auth, data/schema, infra/deploy,
API/contract, deps). **Exit 2** means the diff is heavier than `PIPELINE` (e.g. you chose `single-thread`
but it touches auth across layers → recommends `full`): **surface the recommendation**. This is a
**visible nudge, not a block** — the operator still decides (constitution P1). No diff yet (fresh run) →
it recommends the lightest tier and stays silent; re-run it as batches land, or against `<base>..HEAD`.

---

## Phase B — Implementation, batch-by-batch (step-by-step, human-paced)

Decompose the task list into batches per the flow's Step 6 batch rules. **Prefer vertical slices
over horizontal layers:** a batch should deliver one working end-to-end path (e.g. endpoint +
the frontend that calls it + the wiring), not "all backend" then "all frontend." Horizontal
slicing is what produces an endpoint with no consumer — dead code that each builder reports as
done. Only split a slice across batches when a genuine dependency forces it, and then name the
cross-batch wiring explicitly.

**Order batches by load-bearing risk, not by ease of writing.** The first batch is the code that
most reduces irreversible risk or run-rate — the thing that stops the bleeding — never the document
that explains why the bleeding can be stopped. Doc-only batches (ADRs, doctrine, notes) go **last**
and mark themselves `kind:doc` in the ledger; they earn no delivery credit and `check-delivery.sh`
**rejects a run whose first batch is `kind:doc` while code batches wait behind it**. Writing the
easy-to-write documents first while the load-bearing code waits is the ordering failure this enforces
against — put the metre before the cut only where a cut genuinely depends on it.

Then, for **each batch, one at a time**:

1. **Announce** the batch: which task IDs, which files, the verification gate, and the commit
   format. Then **write the announced ledger entry** to `.runs/<run>/batches.jsonl` — one compact
   JSON object:
   `{"id","scope","task_ids","files","gate","kind":"code|doc","risk_rank":"irreversible|run-rate|feature|doc","status":"announced"}`.
   `risk_rank` declares the batch's load-bearing rank; `check-delivery.sh` rejects a higher-rank
   `kind:code` batch closing **after** a lower-rank one (order by risk, bleeding-stopper first). This
   is the *record* of intent, not closure: only `verify-batch.sh` can flip it to `closed`
   (see [../references/enforcement.md](../references/enforcement.md), delivery-occurred layer).
2. **WAIT** for the user to confirm (e.g. "fire" / "continue"). Do **not** auto-run the next
   batch — this is step-by-step by design.
3. On confirmation, run the batch through the chosen pipeline:
   `/team-bootstrap PIPELINE "<batch scope: cite the task IDs + point at spec.md/plan.md/tasks.md>"`
   **"fire" means code, not another review.** The required response to a delivery confirmation is a
   pipeline run that produces committed code (a stamped `code_delta > 0`) — not fresh analysis, more
   briefs, or another review pass. Answering a delivery command with analysis is a policy violation
   ([../references/failure-policy.md](../references/failure-policy.md)); the ledger enforces it — the
   next batch cannot be announced until this one is closed by a real run.
4. Subagents **commit locally only**. Never `git push` or deploy without explicit per-call
   authorization (constitution P5 / irreversibility).
   **Red-first, per batch (P9).** At this batch's red step — after writing the failing test(s), before
   implementing — run `${CLAUDE_PLUGIN_ROOT}/bin/tdd-red.sh --batch <this batch id>`; it requires the
   `Test:` suite to actually fail and records the observed red. `check-tdd.sh` (in `verify-batch`, below)
   fails the batch if this code batch has no red recorded before its own commits — every code batch must
   be red-first in its own window (see [../references/tdd.md](../references/tdd.md)).
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
   Then the **regression & invariant gate (hard):** `regression-guardian` re-runs the accumulated
   invariant/regression suite **across all workflows**, **graduates** this batch's verified acceptance
   into the suite, and meta-checks gate integrity (no green-by-skip / no disabled gate). Do not close
   the batch while `regressions_found > 0`, the suite isn't current, or a gate didn't actually run —
   this is what stops "closed for the workflow that existed that day." See
   [../references/regression-and-invariants.md](../references/regression-and-invariants.md).
   Then the **machine backstop (hard):** run `${CLAUDE_PLUGIN_ROOT}/bin/verify-batch.sh` — the same
   script CI runs — which re-checks the OUTCOMES (dead code / drift / green-by-skip) regardless of
   which roles ran. A non-zero exit blocks the batch. The reviewer roles can be skipped by an LLM;
   this script and CI cannot ([../references/enforcement.md](../references/enforcement.md)). On pass
   it also runs `check-delivery` (no prior kind:code batch announced-but-never-closed) and **stamps
   this batch `closed`** in the ledger with `commit_shas` + `code_delta` — closure becomes a recorded
   machine fact, not a claim.
   **Closure-fidelity gates (hard, in `verify-batch`).** The backstop also runs the three closure-fidelity
   gates: **A** (`check-enforcement`) records `enforcement_gaps` and blocks until you record
   `enforcement_ack:true` in the marker — surface the gap set to the human and, on their go-ahead, set it
   (a `run-rate|irreversible` batch cannot ack — declare the tooling or split the risk); **B**
   (`check-completeness`) requires this batch's `task_ids` to be `[x]` in `tasks.md` — so mark them the
   moment the work is done-and-self-tested, before the backstop runs; **C** (`check-seam-ack`) blocks a
   batch touching a recorded `high_risk_seams` path until you record a `seam_acks` entry naming the seam +
   the shipped commit + a `file:line` note. All three are the same recorded-blocking-ack machinery as the
   precond ack — honesty is the human's, presence is enforced.
6. After the batch **passes all gates**: `verify-batch.sh` has stamped the ledger entry
   `status:closed` with `commit_shas` + `code_delta`. **Read closure from the ledger — do not assert
   it.** A batch is closed only if its entry says so; if it still reads `announced`, the pipeline did
   not run and the batch is **not** closed — do not present the next batch. On real closure, mark its
   tasks `[x]` in `tasks.md`, report the stamped SHA(s) and gate results (E2E + 0 orphans + 0 drift +
   0 regressions), and any catches. Then present the **next** batch and **WAIT** again.

**Milestone finalization (hard, before declaring done).** After the final batch closes, run
`/Users/sergey_polishchuk/.claude/plugins/cache/team-bootstrap/team-bootstrap/2.18.1/bin/check-completeness.sh --final` — the closure-fidelity completeness
gate in milestone mode: **no** `[ ]` may remain in `specs/<slug>/tasks.md`, and **every** `AC-N` in
`spec.md` must be referenced by ≥1 test-path file (`is_test_path`; `AcPattern:` configurable). A non-zero
exit means the milestone is **not** done — an unchecked task or an acceptance criterion with no test. Fix
(implement the task / add the test, or defer it explicitly with rationale) before declaring the milestone
complete. This is the machine half of "post-review keeps finding undone tasks / unimplemented spec parts"
([../references/enforcement.md](../references/enforcement.md), closure-fidelity layer).

Stop after the final batch, or whenever the user says stop. At the end, summarize: batches shipped,
tasks closed vs deferred, and what still needs a human (push authorization, prod deploy, open risks).

---

**Right-sizing note:** this command is for non-trivial milestones. For a single small change,
skip it and run `/team-bootstrap single-thread "<task>"` directly.
