# Evaluator

The evaluator is an **independent quality gate** that judges a role's artifact against success
criteria *before* the handoff is accepted into the blackboard. It exists to counter
**self-evaluation bias** — the well-documented tendency of an agent to overrate its own output,
find a flaw, talk itself out of it, and approve work that should not pass.

## The one place shared context is wrong

team-bootstrap defaults to **inline, shared-context** execution (Cognition's "Don't Build
Multi-Agents"). The evaluator is the **single sanctioned exception**. The generator — backend,
frontend, architects, any role that *produces* an artifact — stays inline. The **judge** does not.

GAN-style separation: the agent that built the artifact never grades it. The evaluator runs as a
**fresh subagent with a context reset**, receiving only:

1. the **success criteria** (acceptance criteria / spec slice / role's `checks`), and
2. the **artifact itself** (file diffs, paths, the handoff object).

It does **not** receive the generator's reasoning narrative, the build history, or the full
blackboard. Two reasons: (a) seeing *how* the artifact was built biases the judge toward accepting
it; (b) a verifier doesn't need the construction history — only the criteria and the result
(Anthropic's verification-subagent finding). A fresh context also avoids the "model turns cautious
near the context limit" effect that compaction introduces.

The judge runs on a strong model regardless of the role's own tier ([model-tiers.md](model-tiers.md)) —
a Haiku-tier role is still judged by a Sonnet/Opus-tier evaluator.

## Which roles are evaluated

Evaluation costs a subagent call; it is **not** run on every role.

| Class | Roles | Policy |
|---|---|---|
| **Mandatory** | `release-manager`, `security-reviewer`, and any role that writes code/migrations (`backend-engineer`, `frontend-engineer`, `data-schema-reviewer`, `ai-engineer`, `devops-platform`) | Always evaluated |
| **On-demand** | any role | Evaluated when the user requests it, or when the orchestrator's confidence in the handoff is low (e.g. a barely-passing self-check) |
| **Skip** | pure-research / comms / planning roles with no verifiable artifact | Not evaluated (nothing to blackbox-test against criteria) |

## Rubric

Score **one dimension at a time** — never a single blurry overall score (Anthropic/OpenAI both
recommend per-dimension judging). Each dimension is a **categorical integer 0–4** with an explicit
definition per level, plus a one-line justification citing **concrete evidence** (a file path, a
check's output, a spec line) — not a vague descriptor.

| Dimension | Asks | Evidence the justification must cite |
|---|---|---|
| `criteria_coverage` | Does the artifact satisfy **every** stated acceptance criterion / spec requirement? | Which criteria are met / unmet, by reference |
| `grounding` | Do the handoff's claims and artifact references point to things that **actually exist** (real files, real command output)? | The referenced path/command and whether it resolves |
| `correctness` | Is the work **actually correct** — logic sound, checks genuinely pass, no regressions introduced? | The passing/failing check or the specific defect |
| `safety` | No secrets/PII in artifacts, no irreversibility-class violation, no scope creep beyond the task | The scanned artifact / action class |
| `quality` | Readability, maintainability, idiom appropriate to the role and surrounding code | The specific construct judged |

### Scale (applies to every dimension)

| Score | Meaning |
|---|---|
| 4 | Fully satisfies the dimension; no reservations |
| 3 | Satisfies with minor, non-blocking nits |
| 2 | Partially satisfies; a real gap remains |
| 1 | Largely fails the dimension |
| 0 | Absent or fundamentally wrong |

### Bias controls

- **Shuffle dimension order** per evaluation — judges are sensitive to dimension ordering; permuting
  it cancels position bias.
- **Evidence-or-it-didn't-happen** — a score without a concrete citation is invalid; re-ask.
- **Calibration examples** — keep 1–2 graded examples per dimension in the eval suite
  ([../evals/README.md](../evals/README.md)) so scores map onto a stable standard.

## Verdict and the evaluator-optimizer loop

Combine the per-dimension scores into a gate verdict:

- **pass** — every dimension ≥ `3` **and** `safety` has no `0`/`1`.
- **revise** — any non-safety dimension at `2`, or a `3` the judge flags as fragile.
- **fail** — any non-safety dimension ≤ `1`.
- **safety-fail** — `safety` is `0` or `1`. **Hard stop, no optimizer retry.**

Orchestrator handling (Step 5.5):

1. `pass` → accept the handoff; record the verdict; continue to Step 6.
2. `revise` / `fail` → run **one** optimizer cycle: re-activate the *original* role inline with the
   evaluator's per-dimension feedback as additional input. Re-evaluate. Cap at
   `max_evaluator_cycles` (default `1`). Still failing → `blocked`,
   `stop_reason: evaluator_gate_failed`.
3. `safety-fail` → do **not** retry. `blocked`, `stop_reason: evaluator_gate_failed`, escalate to
   human ([guardrails.md](guardrails.md) output-guardrail applies).

The optimizer cycle is bounded and one-directional: the evaluator never edits the artifact itself
(that would re-merge the contexts it was separated from) — it returns feedback; the generator
revises.

## Output shape

The evaluator returns a structured verdict (append to the blackboard, set as a span attribute
`team_bootstrap.evaluator_verdict`):

```yaml
evaluator_verdict: pass | revise | fail | safety-fail
role_evaluated: <role-name>
scores:
  criteria_coverage: { score: 0-4, evidence: "<concrete citation>" }
  grounding:         { score: 0-4, evidence: "<concrete citation>" }
  correctness:       { score: 0-4, evidence: "<concrete citation>" }
  safety:            { score: 0-4, evidence: "<concrete citation>" }
  quality:           { score: 0-4, evidence: "<concrete citation>" }
  dimension_order: [<shuffled order actually used>]
cycle: 0            # which optimizer cycle produced this verdict
```

## See also

- [trace-evals.md](trace-evals.md) — the run-level grader catalog this rubric extends
- [subagent-dispatch.md](subagent-dispatch.md) — the evaluator is the sanctioned context-reset case
- [model-tiers.md](model-tiers.md) — judge runs on a strong model independent of the role's tier
- [failure-policy.md](failure-policy.md) — `evaluator_gate_failed`, optimizer-cycle bound
- [../bin/eval-role.sh](../bin/eval-role.sh) — runnable static + judge eval for a role
