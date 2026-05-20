# Full Pipeline

Run roles in this order:

1. `discovery-research`
2. `product-manager`
3. `business-analyst`
4. `test-designer` ← **TDD/BDD test cases before implementation**
5. `delivery-manager`
6. `cto-tech-lead`
7. `solution-architect`
8. `backend-engineer`
9. `frontend-engineer`
10. `devops-platform`
11. `data-schema-reviewer` ← **migrations, backwards compatibility**
12. `accessibility-reviewer` ← **WCAG compliance**
13. `performance-reviewer` ← **N+1, memory, scalability**
14. `security-reviewer` ← **OWASP, secrets, auth**
15. `qa-test-engineer`
16. `overengineering-reviewer`
17. `code-reviewer`
18. `release-manager`
19. `stakeholder-communicator` ← **non-technical release notes**
20. `documentation-agent`

## Optional Roles (triggered by spec content, not part of normal flow)

Inserted into the pipeline at the position noted in [role-matrix.md](../role-matrix.md):

- `ux-researcher` — inserted after `discovery-research` (before `product-manager`) when new user-facing flow lacks prior research
- `product-marketer` — inserted after `product-manager` (before `business-analyst`) when new product / new ICP / repositioning / pricing change / new GTM motion. Positioning shapes downstream requirements.
- `ux-designer` — inserted after `product-marketer` / `business-analyst`, before `ui-designer` — when novel interaction patterns or UX = core moat
- `ui-designer` — inserted after `ux-designer` (or `product-manager` if design skipped), before `frontend-engineer` — when new product visual identity or design-system-from-scratch
- `whimsy-injector` — inserted after `frontend-engineer` (before `accessibility-reviewer`)
- `ai-engineer` — inserted after `solution-architect` (before implementation) when spec mentions LLM/RAG/agents
- `chaos-engineer` — inserted after `qa-test-engineer` (before `release-manager`) for new hot-path deps / SLO changes
- `legal-compliance-checker` — inserted after `security-reviewer` (before `release-manager`) for PII/PHI/payments
- `growth-marketer` — inserted after `release-manager` (before `stakeholder-communicator`) when launch has reach goals, growth plateau, or AI search posture work
- `incident-responder` — separate `incident` pipeline when production issues occur

Use the same handoff rule as the MVP pipeline: no silent skips, explicit `next_role`, stop on `blocked` or `needs_input`.

## Role Flow Diagram

```
discovery-research
       ↓
   [ux-researcher?]            ← optional, when no prior research
       ↓
product-manager
       ↓
   [product-marketer?]         ← optional, when new ICP / launch / repositioning
       ↓
business-analyst
       ↓
   [ux-designer?]              ← optional, when novel UX or UX-as-moat
       ↓
   [ui-designer?]              ← optional, when new visual identity / design-system-from-scratch
       ↓
test-designer ← defines tests BEFORE implementation
       ↓
delivery-manager
       ↓
cto-tech-lead
       ↓
solution-architect
       ↓
   [ai-engineer?]              ← optional, when spec mentions LLM/RAG/agents
       ↓
backend-engineer → frontend-engineer
                          ↓
                   [whimsy-injector?]
                          ↓
                   devops-platform
                          ↓
              ┌──────────┼──────────┐
              ↓          ↓          ↓
    data-schema    accessibility  performance
      reviewer       reviewer      reviewer
              └──────────┼──────────┘
                         ↓
                 security-reviewer
                         ↓
              [legal-compliance-checker?]
                         ↓
                  qa-test-engineer
                         ↓
                  [chaos-engineer?]
                         ↓
             overengineering-reviewer
                         ↓
                   code-reviewer
                         ↓
                  release-manager
                         ↓
              [growth-marketer?]     ← optional, when reach goals / growth plateau / AEO posture
                         ↓
             stakeholder-communicator
                         ↓
               documentation-agent
```

## Design stages — when to include

The two design roles (`ux-designer` + `ui-designer`) are **opt-in** for the full pipeline. Triggers:

- **Greenfield consumer / prosumer product** — both roles strongly recommended; UX decisions made at `frontend-engineer` runtime tend toward generic AI-aesthetic
- **B2B product where UX = core moat** — both roles recommended (e.g. operator-first tools, agentic workflows, novel interaction patterns)
- **Internal admin tool / dashboard** — neither role; `frontend-engineer` can follow shadcn/ui defaults
- **Iteration on existing design system** — `ui-designer` skipped (use existing tokens); `ux-designer` if interaction patterns change
- **Visual refresh of existing product** — `ui-designer` only

Both roles produce artifacts that the next role inherits:
- `ux-designer` → IA + flows + wireframes + interaction patterns + component inventory → consumed by `ui-designer`
- `ui-designer` → design tokens + component library spec + reference prototype + implementation mapping → consumed by `frontend-engineer`

If only one role runs:
- `ux-designer` without `ui-designer` → `frontend-engineer` makes visual decisions (acceptable if existing design system covers it)
- `ui-designer` without `ux-designer` → `ui-designer` infers UX from product brief (acceptable for simple feature additions to existing IA)

## Marketing stages — when to include

The two marketing roles (`product-marketer` + `growth-marketer`) are **opt-in** for the full pipeline. Triggers:

- **Greenfield product launch with reach goals** — both roles strongly recommended; positioning informs scope; growth strategy maps launch to compounding motion
- **New feature in different ICP** — `product-marketer` recommended (repositioning); `growth-marketer` if channel strategy changes
- **Pricing change > 20%** — `product-marketer` required (pricing strategy + competitive battle cards)
- **Repositioning (pivot)** — both roles required; old positioning needs explicit retirement, new positioning needs full GTM plan
- **Existing product growth plateau** — `growth-marketer` required (diagnose channel exhaustion, surface new growth loops)
- **AI search / GEO category shift** — `growth-marketer` required (AEO posture + content engine repositioning)
- **Internal tool / private beta / dev-only feature** — neither role (no market motion)
- **Patch / bug fix / incremental improvement to existing product** — neither role (use `stakeholder-communicator` for release notes)

Both roles produce strategic artifacts that downstream roles inherit:
- `product-marketer` → ICP + positioning + pricing tiers + launch sequencing + battle cards + sales enablement → consumed by `business-analyst` (shapes requirements), `release-manager` (informs launch staging), `frontend-engineer` (landing page copy + pricing UI)
- `growth-marketer` → channel mix + content engine + AI search posture + growth loops + 30/60/90 plan → consumed by `stakeholder-communicator` (brand narrative + channel positioning), `documentation-agent` (content roadmap), future iterations

If only one role runs:
- `product-marketer` without `growth-marketer` → launch happens but compounding growth motion is improvised post-release
- `growth-marketer` without `product-marketer` → channel + content strategy built on assumed positioning (acceptable if existing ICP + messaging are validated)
