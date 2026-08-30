---
description: One command — run the full pre-implementation flow (speckit constitution→specify→clarify→plan→tasks→analyze), then drive implementation batches step-by-step through a team-bootstrap pipeline (mvp or full).
argument-hint: [full|mvp] "<feature description>" | [full|mvp] specs/<slug>[/spec.md]  (default: the harness sizes it)
---

You are the delivery orchestrator. Input: `$ARGUMENTS`.

**Parse the arguments:**
- First whitespace-delimited token = `PIPELINE` — `mvp` or `full` **pins** the tier, and the harness
  records `tier_source: operator`. Anything else is not a tier: `PIPELINE = auto`, and **the harness
  sizes the run itself** (`tier_source: harness`).
- The remainder = `FEATURE`. It may be a **description** of the thing to build, **or a path to a
  milestone that already exists** (`specs/<slug>` or `specs/<slug>/spec.md`). These are different
  runs — see Phase A.

**Do not choose the tier yourself, and do not treat `auto` as "pick `full` to be safe".** The harness
has already decided by the time you read this: `bin/delivery-marker-init.sh` resolved the argument,
and — when the milestone is on disk — ran `bin/size-from-spec.sh` over its `tasks.md`/`plan.md` before
your first tool call. **The verdict is already in your context** — `delivery-marker-init.sh` states it
on the `UserPromptSubmit` channel: pipeline, `tier_source`, review depth, the risk categories it
detected, the roles it assigned, and the per-work-stream plan. It is not something to go and read;
`.runs/<id>/RUN` holds the same fields for the gates, and is a reference if you want the raw record.
Do not recompute the verdict and do not override it. `auto` surviving in the marker means the
tier is not yet knowable (a description with no spec on disk); every gate treats it as fail-**closed**,
so nothing is skipped while it stands.

`full` used to be the fallback for an unrecognized token, which meant a spec **path** — never the
literal word `mvp` or `full` — silently selected the 20-role pipeline every time. That contradicted
this plugin's own architecture doc, which calls `single-thread` *"the recommended default"*
(`references/pipelines/single-thread.md`), and it was the largest single cost lever in the system.

Use `${CLAUDE_PLUGIN_ROOT}/references/speckit-preimpl-flow.md` as the doctrine and quality bar
for every step below (constitution invariants, drift-catch discipline, AC→task coverage, "never
push without auth"). If that path is unavailable, follow the same 6-step discipline from memory.

---

## Phase 0 — Setup-readiness (hard, before Phase A)

Before any analytical step, run `${CLAUDE_PLUGIN_ROOT}/bin/check-preflight.sh` — the setup-readiness
gate. `check-preconditions.sh` (end of Phase A) asks *"can the output land?"*; this asks the other
half, at the cheapest point: *"is the project scaffolded so the pre-implementation flow can even run
correctly here?"* It is a **readiness** gate (pipeline-integrity-hardening WS-B), not merely a scaffold
linter — it verifies, fail-**closed**:
- **Scaffold:** a constitution resolvable **via `feature.json`**, the `specs/` dir, a parseable
  `feature.json`, `docs/adr/`, and a run marker with `intends_code`+`baseline_sha`.
- **Readiness (WS-B):** a runnable `Test:` command exists (a code run must be red-first-verifiable) and
  its **binary resolves** (on PATH or as a file); a present dependency **lockfile has its install dir**
  (deps were actually provisioned); `baseline_sha` **resolves** to a commit (now HARD, was a warning); and
  the run's own **docs-contract** (`spec.md`/`plan.md`/`tasks.md` under the marker's `feature`) is present
  in the build tree (no split-brain). Only `specs/TEMPLATE/` absence is a warning. **Detect-and-report
  only** — it never creates scaffold or installs anything.

**`Prepare:` — provision deps in a named phase, before the pipeline fires.** Declare a network-permitted
setup command as `Prepare:` in `AGENTS.md` (e.g. `Prepare: \`npm ci\``; `N/A` when the toolchain needs no
install). The orchestrator runs it **here in Phase 0, before Phase A**, so dependencies are present when
`check-preflight` and later `quality-gate` run — rather than discovering "command not found" reactively
mid-Phase-B. This is the "prepare-before-firing" that makes the readiness probes meaningful.

- **Exit 0** — setup-ready; it records `preflight:{exit:0,…}` into the run marker and Phase A proceeds.
- **Exit 1 (hard)** — it prints the named gap set and records `preflight:{exit:1,gaps:[…]}`. **STOP.**
  Surface the gaps to the human; fix the scaffold/readiness gap (you never create it silently) and re-run,
  **or**, on the human's go-ahead, record a **governed waiver** — `preflight.ack:true` **plus**
  `preflight.by`, `preflight.reason`, and `preflight.expires` (`YYYY-MM-DD`, unexpired) — in
  `.runs/<run>/RUN`. A **bare** `ack:true` no longer clears it (WS-B AC-B5): `check-delivery` requires
  `governed_waiver_ok` so a one-time ack can't become a standing free pass across a later independent
  readiness failure on the same run. The one gap no waiver can paper over is a target that is **not a git
  repo**: `check-preflight` fails on it outright, and a non-git target has no delivery run to record a
  waiver in — fix the repo, don't try to proceed.

This is a **blocking machine fact**, not a spoken note: `check-delivery.sh` refuses to let an
`intends_code` run announce a `kind:code` batch while `preflight` is absent (gate never ran), or
`preflight.exit!=0` without a valid `governed_waiver_ok` (by/reason/unexpired-expires). A skipped Phase 0 cannot silently pass. Phase 0 **complements**
— does not replace — the end-of-Phase-A deliverability precondition (they answer different questions and
record different marker keys: `preflight` vs `precond`).

---

## Phase A — Pre-implementation (autonomous, in order)

**`spec_present` selects which of the two Phase A modes you are in**, and it is stated in the harness
context you already have (the marker carries the same field for the gates).

### Mode 1 — `spec_present: false` (a description). Produce the milestone.

Run every step 1–8 below, in order, no skipping. This is the unchanged path.

### Mode 2 — `spec_present: true` (the milestone is already on disk). **Check it; do not re-draft it.**

`spec.md`/`plan.md`/`tasks.md` exist at `spec_path`. Run **only the checking steps**:

- **step 6 `speckit-analyze`** — cross-artifact consistency (spec ↔ plan ↔ tasks; every AC maps to ≥1 task)
- **step 7 `architecture-reviewer`** — is the planned architecture sound

Then go to the Phase B gate. **Skip steps 2–5** (`specify`, `clarify`, `plan`, `tasks`) — they are the
*producing* steps, and what they produce already exists. Skip step 1 unless `constitution.md` is
missing. Run step 8's briefs per the pull rule as usual.

**If a check reports a gap, re-open ONLY the step that fills it** — `tasks.md` absent or an AC with no
task ⇒ `speckit-tasks`, and nothing else. Do not run the whole producing chain to fix one artifact.

The line is *producing* vs *checking*: re-checking finished work is cheap and load-bearing, while
re-producing it is pure cost. Two measured runs against an already-written spec spent **2h21m** in
Phase A — six `architecture-reviewer` passes and spec revisions to v5/v6 — before the first line of
code, and neither run finished the milestone.

**This is observed, not trusted.** The harness hashed each artifact at run start (`spec_artifacts` in
the marker). If an artifact's content changes during Phase A, `check-preflight` reports it. Editing a
spec mid-flight is legitimate — but it must follow a recorded finding, not a silent re-draft.

---

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
verdict, drift catches, any unresolved blocker, and **the harness's sizing verdict**: `pipeline`,
`tier_source`, `sizing` (the reasons), the detected risk categories, the assigned roles, and the
per-work-stream `role_plan` — all of it already stated in your context.
State it even when it is `full` — a sizing decision nobody sees is a sizing decision nobody can
challenge. If `tier_source: harness`, name the reasons that drove it. **STOP here** if `speckit-analyze` surfaced a
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
   - **Withdrawing an announced batch after a pre-code reviewer no_go (#75).** A reviewer returning
     `no_go` on an announced batch — *before* any code is committed (e.g. `architecture-reviewer`
     rejects the plan: wrong sink/source, the effect already exists upstream) — is a **normal,
     expected** outcome, not a failure of the run. The sanctioned response is to **withdraw** the
     batch and re-plan, recorded as a first-class ledger fact: **append** one line to
     `.runs/<run>/batches.jsonl` — `{"id":"<this same batch id>","status":"withdrawn","reason":"<reviewer role> no_go: <why>. Re-planning."}`
     — leaving the original `announced` line in place (do **not** hand-edit or delete it). This is the
     terminal counterpart to `closed`: `check-delivery.sh` resolves each id to its **latest** status,
     so a `withdrawn` id is **terminal** — it earns no delivery credit, and it is **not** an
     "announced-then-abandoned" batch (nor does it count as an abandoning *later* batch for a prior
     announced one). Withdraw with a recorded reason rather than silently dropping the announce: a
     bare announce with no closure and a different later batch is still read as abandonment and
     fails the run. (Parallels the `{"confirm":…}` and regression-lock records — a legitimate flow
     action needs a recognized ledger form the gates read, not a manual ledger reset.)
2. **Default NON-STOP — the stop is a mechanism, not this prose (#56).** A **reversible** batch
   (`risk_rank: feature|doc`, no role question) needs no operator prompt: announce it, then proceed to
   run it. The pause that matters is enforced deterministically by
   [../bin/check-batch-confirm.sh](../bin/check-batch-confirm.sh), a `PreToolUse[Bash]` gate that reads
   the ledger, so it does **not** depend on you remembering to check the rank:
   - When the in-flight batch's declared `risk_rank ∈ {irreversible, run-rate}` **or** it carries
     `manual_approval_requested: true` (a role flagged a genuine question), the gate **blocks the
     `git commit`/`git merge`** (exit 2) until a confirmation for that batch is recorded — the human is
     pulled in exactly when the cost is unrecoverable-by-`reset` or a role asked, and never when
     `git reset` fixes everything.
   - **Recording a confirmation** is what the operator's "fire" / "continue" authorizes: append one line
     to `.runs/<run>/batches.jsonl` — `{"confirm":"<this batch id>"}` — then the commit proceeds. Write
     it **only** on the operator's explicit go, never pre-emptively; it is an auditable ledger fact, not
     a self-issued waiver.
   - This checkpoint only ever **adds friction above** the action-class layer. `risk_rank` is
     self-declared and forgeable (ADR-0006), so a batch that forges a lower rank escapes *this* gate —
     but its irreversible **actions** are still caught: a commit on the default branch by
     [../bin/guard-git.sh](../bin/guard-git.sh), and push/deploy by the remote's branch-protection
     ([../references/irreversibility.md](../references/irreversibility.md)). Never treat `risk_rank` as
     the sole guard for irreversibility.
3. Run the batch through the chosen pipeline:
   `/team-bootstrap PIPELINE "<batch scope: cite the task IDs + point at spec.md/plan.md/tasks.md>"`
   **"fire" means code, not another review.** The required response to a delivery confirmation is a
   pipeline run that produces committed code (a stamped `code_delta > 0`) — not fresh analysis, more
   briefs, or another review pass. Answering a delivery command with analysis is a policy violation
   ([../references/failure-policy.md](../references/failure-policy.md)); the ledger enforces it — the
   next batch cannot be announced until this one is closed by a real run.
4. Subagents **commit locally only**, on a feature/milestone branch — never on the default branch
   (`main`/`master`). A `PreToolUse[Bash]` guard ([../bin/guard-git.sh](../bin/guard-git.sh), ADR-0011)
   machine-blocks a `git commit`/`git merge` while HEAD is the default branch (exit 2, "branch first") on an
   armed run — best-effort, kill-switchable. Never `git push` or deploy without explicit per-call
   authorization (constitution P5 / irreversibility); the guard does **not** gate push/`gh pr merge` (the
   remote's branch-protection is that backstop — [../references/irreversibility.md](../references/irreversibility.md)).
   **Red-first, per batch (P9).** At this batch's red step — after writing the failing test(s), before
   implementing — run `${CLAUDE_PLUGIN_ROOT}/bin/check-tdd.sh --record-red --batch <this batch id>`; it
   requires the `Test:` suite to actually fail and records the observed red anchored to the commit that
   carries the failing test. `check-tdd.sh` (in `verify-batch`, below)
   fails the batch if this code batch has no red recorded before its own commits — every code batch must
   be red-first in its own window (see [../references/tdd.md](../references/tdd.md)).
   **Emergent / verification batch — no honest red? Lock it, don't hide it (#89).** Some legitimate
   `kind:code` batches have NO natural red: an *emergent* batch whose property is already satisfied
   because earlier batches were correct, or a pure *verification* batch that only adds a test pinning an
   already-correct behaviour. Do **not** fabricate a red, and do **not** fold the work into a doc batch to
   dodge the gate. Ship it as `kind:code` with the **regression-lock** form (#67): commit the test that
   pins the property, then run `${CLAUDE_PLUGIN_ROOT}/bin/check-tdd.sh --record-lock --batch <id>` with the
   locked behaviour **mutated** (uncommitted) in the tree — the lock must REDDEN under the mutation
   (mutation-kill proof), then revert so HEAD is green. `check-tdd` accepts a code batch on **either** a
   red record **or** a lock record; the lock test need not precede the code (a lock *is* a test). This is
   the honest proof for a green-on-arrival property — see [../references/tdd.md](../references/tdd.md).
   **Scoped suite for the inner loop; full suite only at close (#86).** The full `Test:` suite is
   load-bearing at exactly one place: batch **close** (`verify-batch`, which runs it whole). Re-running
   the whole suite on every red observation and every green iteration is the single largest time sink of
   a run. So iterate fast on the **affected subset**: pass the batch's touched test path(s) to
   `--record-red --scope "<paths>"` — it appends them to *your* `Test:` runner (e.g.
   `… --record-red --batch B2 --scope "tests/test_foo.py"`), observes the red on that subset, and applies
   the same #68 wrong-cause and F1 red-touches-tests bars; seeing one new test fail never needed the
   whole suite. Use the same scoped invocation for your own green-iteration feedback. Do **not** run
   `verify-batch` until you are green — it is the close gate, and it runs the full suite by design.
   (Note: `bin/run-tests.sh --changed` is team-bootstrap's OWN self-test runner — it has nothing to do
   with a target repo's `Test:` suite and must not be invoked for a delivery.)
5. **`full` means the HARNESS sizes each batch — not "four roles every time" (#27).**
   At announce, the harness computes this batch's required review roles from **its own diff and its
   declared `risk_rank`** (`required_roles_for_batch`, recorded on the ledger entry) — because the
   operator picks a tier once, before any batch exists, while cost accrues per batch. Dispatch **the
   set it asks for**. Any risk touch (auth · schema · infra · API · deps) or an
   `irreversible`/`run-rate` rank still pulls in the full four; only ordinary batches size down.
   `bin/select-pipeline.sh --batch <id>` shows the recommendation, and now reports **over**-provisioning
   as well as under- (it used to be silent when you overspent). The floor is **hard on every code
   batch, and you do not arm it**: `verify-batch.sh` records the sized set on the ledger entry itself,
   in code, immediately before the dispatch gate reads it. It is recorded *there* rather than at
   announce because that is where the batch's diff exists — at announce the window is still empty, so
   the set computed then is the wrong one.
   **Two floors that never move:** every code batch keeps **≥1 independent reviewer** (the
   anti-collapse guarantee — it is never sized away), and `check-role-dispatch` **fails closed** on a
   required role that was not dispatched. Dispatching **more** than the set is reported, never blocked —
   blocking it would push review inline, which is the collapse this exists to prevent.

   **The four review roles run AFTER the builders — but CONCURRENTLY with each other (#23 item 4).**
   `integration-verifier`, `architecture-reviewer` (conformance), `regression-guardian` and the
   `code-reviewer` all read the same closed batch diff and **do not consume each other's output**, so
   nothing orders them: `roles_covered` is a set-union and `reviewer_dispatch_count` is a count —
   neither depends on dispatch order. Dispatch them in ONE parallel fan-out. Serialising them was a
   doctrine artefact, and it is expensive: each reviewer is a full subagent (measured 3.6–11.8 min), so
   a chain of four costs 4× the latency of the slowest one. Their gates below are still **each hard**;
   collect all four verdicts, then act on every finding.
   **Record each verdict as it returns (the synchronous capture channel, #81).** The host does not emit
   `SubagentStop` for Agent-tool dispatches (#60, a proven host limit), so a reviewer's typed verdict does
   not reach `verdicts.jsonl` on its own — and `check-role-verdict --gate` then falls back to the
   capture-dropped waiver on every batch. Close the loop yourself: for **each** reviewer that returns, pipe
   its typed verdict object (the `role-output.schema.json` shape it emitted) to
   `${CLAUDE_PLUGIN_ROOT}/bin/check-role-verdict.sh --record <role>` — e.g.
   `printf '%s' '{"role":"code-reviewer","approval_status":"approved", …}' | …/check-role-verdict.sh --record code-reviewer`.
   It validates the shape (a shapeless verdict is rejected), refuses a role you did not actually dispatch,
   and on success writes the record `verify-batch` reads — so the batch closes on a **real recorded
   verdict, not a waiver**. Record the verdict of a review that genuinely ran; never fabricate one to clear
   the gate (a skipped role stays blocked by design — dispatch it instead).
   **Know the shape before you record (#88).** Each role requires role-specific fields. Get them upfront —
   `${CLAUDE_PLUGIN_ROOT}/bin/check-role-verdict.sh --fields <role>` prints exactly what that role's
   verdict must carry — instead of discovering them by hitting a rejection. The reviewer is also told its
   own required shape in its dispatch brief (SubagentStart), so a verdict that comes back should already
   fit; if you must record by hand, `--fields` is the reference.
   *(Caveat: two of them execute test suites — on a machine where those are CPU-bound, expect
   contention rather than a clean 4× win. The saving is in the reasoning time, which dominates.)*
   **Reviewers flag only what affects correctness or the stated requirements.** A reviewer asked to
   find gaps will report some even when the work is sound — that is what it was asked to do — and
   chasing every finding produces over-engineering: extra layers, defensive code, tests for cases that
   cannot happen. Treat the rest as optional. This is the missing exit condition behind multi-round
   review loops (measured: one batch took four full rounds, ~16 dispatches, with findings decaying to
   LOW).

   **Re-verification after remediation is scoped to the FIX (#23 item 3):** when you send findings back
   and they are fixed, re-review the **remediation diff plus the findings it claims to close**, not the
   whole batch window again. A full re-fan-out is right when the fix is structural — not for a 40-line
   point fix. (Measured: a second full four-role round on one batch cost ~30–80 min.)

   **Integration gate (hard).** The pipeline's `integration-verifier` runs after the builders,
   with a clean context: it executes the E2E command from `AGENTS.md` and scans for orphans
   (any endpoint/component the batch produced with no live consumer). **Do not mark the batch
   done, and do not present the next batch, while `orphans_found > 0` or the E2E path fails.**
   Send the orphan back to the builder; after 3–5 failed attempts, **stop and ask the human**
   (rollback the batch's local commits rather than shipping unwired code). Outcome over
   self-report: trust the verifier's run, not the builders' "done."
   The **architecture conformance gate (hard):** `architecture-reviewer` (`review_mode:
   conformance`) runs the fitness functions against the [baseline](../references/architecture-baseline.md)
   — a batch can pass E2E and still **drift** (wrong layer, bypassed boundary). Do not close the
   batch while `drift_findings > 0`; send drift back to the builder, 3–5 attempts → human / rollback.
   The **regression & invariant gate (hard):** `regression-guardian` re-runs the accumulated
   invariant/regression suite **across all workflows**, **graduates** this batch's verified acceptance
   into the suite, and meta-checks gate integrity (no green-by-skip / no disabled gate). Do not close
   the batch while `regressions_found > 0`, the suite isn't current, or a gate didn't actually run —
   this is what stops "closed for the workflow that existed that day." See
   [../references/regression-and-invariants.md](../references/regression-and-invariants.md).
   Then the **machine backstop (hard):** run `${CLAUDE_PLUGIN_ROOT}/bin/verify-batch.sh` — the same
   script CI runs — which re-checks the OUTCOMES (dead code / drift / green-by-skip) regardless of
   which roles ran. A non-zero exit blocks the batch.
   **Give it room to finish (#90).** It runs the full `Test:` suite plus the whole gate cascade, which
   routinely exceeds the Bash tool's ~2-minute default timeout. Invoke it with an explicit long
   timeout (e.g. `timeout: 600000`) **or** run it in the background — a verify killed by the default
   timeout reads as a *failure* and forces a full re-run of suite+gates (the repeated-work cost of #86).
   A slow-but-passing verify is a pass, not a timeout. The reviewer roles can be skipped by an LLM;
   this script and CI cannot ([../references/enforcement.md](../references/enforcement.md)). On pass
   it also runs `check-delivery` (no prior kind:code batch announced-but-never-closed) and **stamps
   this batch `closed`** in the ledger with `commit_shas` + `code_delta` — closure becomes a recorded
   machine fact, not a claim.
   **Independent review gate (hard, in `verify-batch`, v2.20.0).** A `kind:code` batch also runs
   `check-review-ack` (gate C): dispatch a **clean-context** code-reviewer subagent on the batch diff
   (only the diff + refutation criteria, not the run doc), record its `review_acks` (reviewer≠builder,
   context:clean, verdict:go, commit anchored) + `review_refutations` to the marker; a credible refutation
   becomes a MEDIUM+ `review_findings` governed by gate B. A `blocked` verdict or an `irreversible` batch
   escalates to a human ack — never self-close (P5). See [../references/enforcement.md](../references/enforcement.md).

   **Closure-fidelity gates (hard, in `verify-batch`).** The backstop also runs the three closure-fidelity
   gates: **A** (`check-enforcement`) records `enforcement_gaps` and blocks until you record
   `enforcement_ack:true` in the marker — surface the gap set to the human and, on their go-ahead, set it
   (a `run-rate|irreversible` batch cannot ack — declare the tooling or split the risk); **B**
   (`check-completeness`) requires this batch's `task_ids` to be `[x]` in `tasks.md` — so mark them the
   moment the work is done-and-self-tested, before the backstop runs; **C** (`check-seam-ack`) blocks a
   batch touching a recorded `high_risk_seams` path — **or the always-present `control-surface` seam** (the
   plugin's own machinery: `bin/check-*.sh`, `verify-batch.sh`, `delivery-lib.sh`,
   `record-dispatch.sh`, `hooks/*.json`, `.claude`, `.mcp.json`, `AGENTS.md`, `commands`, `agents`, the list
   file — from `references/control-surface.txt`) — until you record a `seam_acks` entry naming the seam +
   the shipped commit + a `file:line` note. When a batch legitimately edits the machinery (this repo does,
   every milestone), record `{"seam":"control-surface","commit":"<sha>","note":"path:line — why"}` after the
   commit that ships the change; a non-`control-surface`-named ack does not satisfy the standing seam
   ([ADR-0012](../docs/adr/0012-control-surface-protection.md), [enforcement.md](../references/enforcement.md)).
   All are the same recorded-blocking-ack machinery as the precond ack — honesty is the human's, presence is
   enforced.
6. After the batch **passes all gates**: `verify-batch.sh` has stamped the ledger entry
   `status:closed` with `commit_shas` + `code_delta`. **Read closure from the ledger — do not assert
   it.** A batch is closed only if its entry says so; if it still reads `announced`, the pipeline did
   not run and the batch is **not** closed — do not present the next batch. On real closure, mark its
   tasks `[x]` in `tasks.md`, report the stamped SHA(s) and gate results (E2E + 0 orphans + 0 drift +
   0 regressions), and any catches. Then present the **next** batch and proceed (step 2): reversible
   batches roll on non-stop; only an `irreversible`/`run-rate` or role-flagged batch stops for a recorded
   confirmation, enforced by `check-batch-confirm.sh` rather than by a prose pause here.

**Milestone finalization (hard, before declaring done).** After the final batch closes, run
`${CLAUDE_PLUGIN_ROOT}/bin/check-completeness.sh --final` — the closure-fidelity completeness
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
