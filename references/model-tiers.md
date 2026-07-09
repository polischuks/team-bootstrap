# Model Tiers

Each role declares the model it runs on via the `model:` field in its frontmatter
([schemas/role-frontmatter.schema.json](schemas/role-frontmatter.schema.json)). Roles are
**not** uniform: a `whimsy-injector` and a `security-reviewer` have very different reasoning
demands, and running both on the top tier wastes tokens. This file is the source of truth for
which role sits in which tier and why.

Rationale follows Anthropic's multi-agent findings (token use explains most of the performance
spread — spend it where reasoning depth changes the outcome) and the tiered-model strategy
popularized by marketplace agent collections.

## Tier assignment rule

| Tier | Model | Use for |
|---|---|---|
| **1 — Opus** | `claude-opus-4-8` | Production-critical, irreversible, or high-stakes reasoning: architecture, security, legal/IP/compliance, money, release go/no-go, incident response, schema migrations, core AI engineering. |
| **2/3 — Sonnet** | `claude-sonnet-4-6` | Implementation, most reviews, and product/design/research/analysis. The balanced default. |
| **4 — Haiku** | `claude-haiku-4-5-20251001` | Mechanical, low-reasoning, or comms-drafting work: simple structural checks, docs/release-notes generation, stakeholder/community copy. |

Default tier for any unlisted or new role is **Sonnet**. Promote to Opus only when a wrong answer
is expensive or irreversible; demote to Haiku only when the task is largely mechanical.

## Current assignment

**Opus (12)** — architecture / security / money / legal / irreversible decisions:
`cto-architect`, `cto-tech-lead`, `solution-architect`, `security-reviewer`,
`ip-contracts-reviewer`, `legal-compliance-checker`, `financial-analyst`,
`investment-thesis-author`, `release-manager`, `incident-responder`, `data-schema-reviewer`,
`ai-engineer`.

**Haiku (6)** — mechanical / comms / simple checks:
`overengineering-reviewer`, `whimsy-injector`, `documentation-agent`, `release-docs`,
`stakeholder-communicator`, `community-manager`.

**Sonnet (24)** — everything else (implementation, reviews, product/design/research, growth,
customer, delivery): `backend-engineer`, `frontend-engineer`, `qa-test-engineer`,
`test-designer`, `code-reviewer`, `performance-reviewer`, `accessibility-reviewer`,
`devops-platform`, `chaos-engineer`, `business-analyst`, `product-ba`, `product-manager`,
`delivery-manager`, `discovery-research`, `ux-researcher`, `ux-designer`, `ui-designer`,
`market-analyst`, `growth-marketer`, `customer-health-analyst`, `customer-success-manager`,
`partnerships-lead`, `product-marketer`, `culture-team-dd`.

## Extended thinking

Independent of the model tier, high-reasoning roles request **extended thinking** via the
`thinking: extended` frontmatter field — more test-time reasoning where the decision is hard and
expensive to get wrong ([Anthropic — Building Effective Agents](https://www.anthropic.com/engineering/building-effective-agents)).
Reserve it for architecture, verification, and final release calls; routine roles omit it (or use
`standard`) to keep latency/cost down.

Roles that carry `thinking: extended`:

- `cto-architect`, `cto-tech-lead`, `solution-architect` — architecture and constraint decisions
- `integration-verifier` — the outcome-based wiring gate
- `release-manager` — the final go/no-go under the disposition gate

`thinking` is advisory to the harness in the same way `model` is: honored where the host supports a
per-call thinking budget, documentation-of-intent otherwise.

## Notes

- The `model:` field is **advisory to the harness**. When a role is dispatched as a subagent, the
  host resolves the actual model; on harnesses that honor per-subagent model selection this yields
  the cost split directly. On harnesses that don't, the field still documents authoring intent and
  drives the model used when a role is run standalone.
- The **evaluator** ([evaluator.md](evaluator.md)) runs on its own judge model independent of the
  role under review — keep that separation when changing tiers here (a Haiku role is still judged
  by the evaluator's stronger judge model).
- When you bump a role's tier, treat it as a behavior change: re-run its eval
  (`bin/eval-role.sh`) per [trace-evals.md](trace-evals.md) before relying on the new tier.
