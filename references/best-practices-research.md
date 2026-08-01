# Best-practices research before implementation

Before an engineer implements in a domain, the domain's **current best practices** should be on the
blackboard — grounded, not recalled from stale memory. This operationalizes source-grounding
([source-driven-development], ground truth from the environment,
[Building Effective Agents](https://www.anthropic.com/engineering/building-effective-agents)) at the
*domain* level, not just the API level. Done naively it is expensive; done right it is negligible.

## The rule of thumb: **per domain, not per task**

Research **once per domain** a milestone touches and reuse the result across every task in that
domain — not once per task. Auth practices are researched once and cited by all auth tasks; a
per-task sweep would re-pay the cost N times and re-create the fan-out token burn.

## Four moves that keep it cheap

1. **Per-domain, cached.** Produce one `best-practices brief` per domain, cache it on the shared
   blackboard; downstream tasks cite it, they don't re-research.
2. **`tavily-research`, not manual triangulation.** Use the cited-research skill (~10× fewer tokens
   than WebSearch + multiple WebFetch); reserve `source-driven-development` for exact API specifics.
3. **Novelty gate — research only what's new or risky.** Research a domain when it is unfamiliar,
   security-/data-sensitive, uses an external vendor/SDK, or introduces a new pattern. **Skip** for
   familiar, trivial, in-house work — and **log the skip with a reason** (never silently). Mirrors
   the risk-triggered specialist dispatch in [pipelines/single-thread.md](pipelines/single-thread.md).
4. **Distill.** The brief is a compact, cited summary (the recommended patterns + the pitfalls to
   avoid + source links), not the raw pages — distilled returns keep every downstream role's context
   clean ([Effective context engineering](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)).

## The brief (what a domain research pass produces)

`discovery-research` ([roles/discovery-research.md](roles/discovery-research.md)), dispatched as a
clean-context subagent per novel domain, emits a **best-practices brief**:

- **Recommended patterns** for the domain, each with a source (URL/doc).
- **Anti-patterns / pitfalls** to avoid (the expensive mistakes).
- **Version/API specifics to verify** (handed to `source-driven-development` at implementation).
- **Confidence / gaps** — where the evidence is thin, say so.

## Who consumes it

`backend-engineer` / `frontend-engineer` **cite the domain brief** for design decisions and
`source-driven-development` for exact APIs; a `completed` engineering handoff in a researched domain
references the brief. An implementation that contradicts the brief without a stated reason is a
review finding.

## Cost envelope

- Right-sized (per-domain, tavily, novelty-gated, distilled): **~5–15K tokens per domain**, so
  **~15–45K per milestone** — single-digit % of implementation + verification cost.
- Naive (per-task, manual triangulation): hundreds of K to >1M per milestone — **do not do this**.

[source-driven-development]: (invoke via the `source-driven-development` skill)
