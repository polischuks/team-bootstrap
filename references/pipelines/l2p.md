# L2P (Landing-to-Platform) Pipeline

Read-only **gap audit** of a product's landing ↔ platform ↔ docs. Finds where the landing promises, the platform delivers, and the docs describe diverge — then turns each gap into an implementation task. **No implementation roles run.** Output is a prioritized backlog (`l2p-backlog.md`) that feeds `single-thread` / `mvp` / `full` (or `/deliver`), exactly like the `audit` pipeline.

Distinct from `audit` and `audit-dd`:
- **`audit`** — technical/operational readiness (internal team perspective) → backlog.
- **`audit-dd`** — commercial/financial DD (investor perspective) → memo.
- **`l2p`** — conversion-funnel + promise-fulfillment gaps → backlog of implementation tasks.

Pipeline metadata:

```yaml
name: l2p
version: 1.0.0
```

## When to use

- "Where are we losing users between the landing and the product?"
- "Which landing promises does the platform not actually deliver?" (overpromise / vaporware risk)
- "Which real capabilities does the landing never sell?" (undersold)
- "Turn our conversion gaps into an implementation backlog."

Do **not** use `l2p` to drive implementation — it produces the backlog; the delivery pipelines execute it. Do not use it for a technical-only audit (`audit`) or commercial DD (`audit-dd`).

## Roles (in order)

1. `recon` — normalized fact base (claims/surfaces/features/instrumentation, each id-bearing) → `00-grounding.md`
2. `usecase-miner` — personas + JTBD + prioritized use cases → `01-use-cases.md`
3. `cartographer` — landing↔platform promise/fulfillment map + orphans → `02-map.md`
4. `funnel-auditor` — stage-by-stage funnel audit, ICE-ranked findings → `03-funnel-audit.md`
5. `gatekeeper` — per-gate pass/fail thresholds + gate ledger → `04-gates.md`
6. `gap-backlog-author` — synthesize `00`–`04` → `l2p-backlog.md` + `audit-report.md`

## Evidence discipline (the between-stage gate)

`recon` produces four id-bearing tables (`C###`/`S###`/`F###`/`I###`). **Every assertion in every downstream artifact must cite one of those ids**, or be tagged `HYPOTHESIS` / `ESTIMATE`. This is a hard gate between stages — it is what keeps the pipeline from fabricating personas, inventing platform features, or asserting drop-off numbers that were never measured. The gate is enforced two ways:

- Machine check: [../../bin/check-citations.sh](../../bin/check-citations.sh) scans each new `l2p-artifacts/` file for assertions lacking a grounding id.
- Between-stage review: before accepting a handoff, scan the artifact for any uncited claim; send it back or tag it before proceeding.

Do not relax it.

## Ranking

All findings and backlog tasks are ranked by **`ICE = Impact × Confidence × Ease`** ([../l2p/funnel-model.md](../l2p/funnel-model.md)). The Confidence axis encodes the evidence discipline (hypothesis = low). Do not substitute other rankings.

## Sequential vs. parallel

The stages are **cumulative** — each cites the previous artifact — so they run strictly in order, one at a time. If a required upstream artifact already exists in `./l2p-artifacts/`, reuse it instead of regenerating. `gap-backlog-author` must run **last**.

## Tool surface

All `l2p` roles are read-only with respect to project source: their frontmatter `tool_surface.deny` blocks `Edit`, and only `recon` may `Bash`/`WebFetch` (for read-only inspection + fetching the landing/platform). `Write` is allowed **only into `./l2p-artifacts/`** — the deliverables — never into project source. `permission_mode` is `ask` for every role.

## L2P spec contract

The user-supplied spec (`/team-bootstrap l2p <spec>`) **must** provide the three inputs:

- **Landing URL(s)** — the pages to fetch.
- **Platform access** — how the platform can be observed: route list, screenshots, docs, or a live walkthrough.
- **Docs path** — the project docs (PRD, positioning, ICP, messaging).

If the platform can't be observed at all, `recon` runs anyway and marks the entire `features[]` table `unverifiable` — the headline unknown. Missing landing URL or docs path → orchestrator returns `needs_input` at Step 0.

## Output

A single run document plus the `./l2p-artifacts/` set (`00`–`04`, `l2p-backlog.md`, `audit-report.md`). The **backlog is the handoff to Phase 2** — each task has `id`, `title`, `source`, `evidence` (grounding ids), `severity`, `ice`, `acceptance_criteria`, `precedent`, and `recommended_pipeline`. Feed it to `/deliver` or run tasks individually through `single-thread` / `mvp` / `full`.

## Anti-patterns

- **Treating l2p as implementation.** Read-only by design. It finds gaps; the delivery pipelines fix them.
- **Fabricating gaps to look thorough.** A clean map is a valid, short backlog.
- **Asserting drop-off without instrumentation.** "Unmeasured and likely leaking because X" is the honest finding; fixing the measurement is itself a task.
- **Substituting another ranking for ICE.** Scores must compose across stages.

## See also

- [audit.md](./audit.md) — technical-readiness audit (complementary)
- [../l2p/funnel-model.md](../l2p/funnel-model.md), [../l2p/gate-taxonomy.md](../l2p/gate-taxonomy.md), [../l2p/artifact-schemas.md](../l2p/artifact-schemas.md)
- [../subagent-dispatch.md](../subagent-dispatch.md), [../failure-policy.md](../failure-policy.md)
