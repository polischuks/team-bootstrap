# Cost measure — roles-as-first-class-agents (#148, AC-8)

**Claim (AC-8):** promoting every delivery role to a first-class in-repo agent did **not** increase the
number of subagent dispatches on sequential build batches, versus the inline-build-by-default policy
(#144). Agent-**as-definition** ≠ agent-**as-dispatch** (F2/AC-5).

**Metric:** subagent dispatches recorded on the `/deliver` run that shipped this milestone
(`.runs/148-roles-as-first-class-agents/dispatch.jsonl`, the harness-observed `PreToolUse[Agent]` record).

**After (this run), by migration batch (snapshot at migration close P0–WD):** P0=6, WA=5, WB=7, WC=6, WD=5.
`dispatch.jsonl` is an append-only log, so the running total keeps growing as later batches (P5, …) run
their OWN review fan-outs — do not read a fixed total as the metric. **The metric is the KIND of dispatch,
and it is invariant: every recorded dispatch is a REVIEW role** (integration-verifier, architecture-reviewer,
regression-guardian, `tb-code-reviewer` [the code-reviewer role's slug], plus the risk-sized
devops-platform / chaos-engineer / data-schema-reviewer). **Zero delivery/build-role dispatches** across the
whole run: not one `backend-engineer`, `frontend-engineer`, `ai-engineer`, `product-manager`, … was
dispatched as a subagent, even though all 37 now exist as first-class agents.

**Before (baseline policy):** a sequential build batch dispatches builders per the pipeline only when the
pipeline chooses to; the recommended default is inline single-thread (#144, constitution P1). The review
fan-out is the only mandated dispatch, and it is unchanged by this milestone.

**Conclusion:** the review fan-out (the pre-existing cost) is the sole dispatch driver; making the delivery
roles first-class agents added **0** per-role build dispatches. The build-side delegation that *did* occur
in this milestone (the Wave A–D fold builders) was the #144 large-separable-batch exception — a deliberate
parallelism choice over ~10–14 independent files, not a per-role dispatch the agent-is-source design forced.
The cost envelope ([[cost-tiered-verification]], #145) is therefore preserved: definition ≠ dispatch holds.

*Named-human-verifiable:* re-derive the "after" numbers with
`python3 -c "import json,collections;c=collections.Counter(json.loads(l)['subagent_type'] for l in open('.runs/148-roles-as-first-class-agents/dispatch.jsonl') if l.strip());print(c)"` — no delivery-role slug appears.
