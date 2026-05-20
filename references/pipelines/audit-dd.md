# Audit-DD Pipeline

Read-only **due-diligence** assessment of a company / project for investment, acquisition, or board consumption. Produces an investor-grade memo with a clear capital-allocation recommendation. **No implementation roles run.** Output is a deliverable artifact (the memo), not a backlog.

Distinct from the `audit` pipeline:
- **`audit`** focuses on technical / operational readiness (15 roles, internal team perspective, output = backlog).
- **`audit-dd`** focuses on commercial / financial / strategic readiness (6 DD-specific roles, investor / acquirer perspective, output = memo).

The two pipelines compose well: run `audit` first to assess technical posture, then `audit-dd` to wrap commercial DD around it.

Pipeline metadata:

```yaml
name: audit-dd
version: 1.0.0
```

## When to use

- Pre-fundraise DD (founder side — build the data room) or investment-thesis assembly (investor side)
- M&A exploration (either direction — buyer or seller)
- Annual board package
- Pre-Series-B / C readiness check
- Strategic-options memo for shareholders

Do **not** use this pipeline to:
- Drive implementation work (use `single-thread` / `mvp` / `full`)
- Conduct a technical-only audit (use `audit`)
- Make a release go/no-go for a software ship (use `audit` → `release-manager`)

## Roles (in order)

1. `financial-analyst` — ARR build, unit economics, capital efficiency, valuation triangulation
2. `market-analyst` — TAM/SAM/SOM, competitive moat, AI-search displacement risk
3. `customer-health-analyst` — cohort retention, NRR/GRR, concentration, churn taxonomy
4. `ip-contracts-reviewer` — license / patent / TM / customer contracts / data residency
5. `culture-team-dd` — org depth, key-person risk, retention, founder dynamics, sentiment
6. `investment-thesis-author` — synthesize → 1-page memo + 10-page deep dive + invest/pass/conditional

## Composition with `audit`

For a complete DD package, run `audit` first then `audit-dd`:

```
team-bootstrap audit <spec-or-checklist>      # produces technical backlog
team-bootstrap audit-dd <thesis-question>     # consumes technical backlog + adds commercial layers
```

When run in sequence, `investment-thesis-author` reads both blackboards (technical + commercial) and produces the consolidated memo. When run standalone, `audit-dd` covers commercial-only.

## Parallelization

Roles 1–5 can be dispatched as parallel subagents — they read from independent input sources (financial model, market refs, customer data, contracts, org chart). Sequential execution remains the conservative default.

`investment-thesis-author` must run **last** — it consumes all prior outputs.

## Required Handoff Outputs

| Role | Must produce before next role |
| --- | --- |
| `financial-analyst` | ARR build, unit-economics block, valuation Bull/Base/Bear |
| `market-analyst` | TAM/SAM/SOM (triangulated), moat scoring, displacement-horizon assessment |
| `customer-health-analyst` | Cohort retention curves, NRR/GRR/logo retention, concentration table |
| `ip-contracts-reviewer` | OSS license audit, foundation-model TOS check, contract red-flags, data-residency map |
| `culture-team-dd` | Org depth, retention signals, comp posture, founder dynamics |
| `investment-thesis-author` | One-page memo + ten-page deep dive + invest/pass/conditional verdict |

## Common modifications

- **Skip `ip-contracts-reviewer`** if no IP-heavy concerns (commodity SaaS without proprietary models, no AGPL deps, simple contracts) — saves ~30% of run time.
- **Skip `culture-team-dd`** if team is < 5 people (founder + early hires, dynamics will be evaluated by `investment-thesis-author` directly) — saves ~20% of run time.
- **Run `customer-health-analyst` twice** for marketplaces (supply-side and demand-side cohorts are different beasts).
- **Augment `market-analyst`** with a `discovery-research` pass if the segment is unfamiliar to the auditor — supplies industry context before market sizing.

## Anti-patterns

- **Don't use `audit-dd` to write a pitch deck.** The memo is investor-side / acquirer-side honesty, not founder marketing. The pitch deck uses the data; it's not the same artifact.
- **Don't bypass `investment-thesis-author`.** Without the synthesizer, the role outputs are fragments — the audience needs the integrated thesis.
- **Don't omit `financial-analyst` to save time.** Every other role's findings are recalibrated against unit economics; financial reality dominates DD.

## See also

- [roles/](../roles/) — each role's playbook
- [audit.md](./audit.md) — technical-readiness audit (complementary)
- [../subagent-dispatch.md](../subagent-dispatch.md) — parallelization rules
- [../failure-policy.md](../failure-policy.md) — handling missing inputs (common in DD — founder data gaps are first-class)
