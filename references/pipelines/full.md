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
- `ux-designer` — inserted after `ux-researcher` (or `product-manager` if research skipped), before `ui-designer` — when novel interaction patterns or UX = core moat
- `ui-designer` — inserted after `ux-designer` (or `product-manager` if design skipped), before `frontend-engineer` — when new product visual identity or design-system-from-scratch
- `whimsy-injector` — inserted after `frontend-engineer` (before `accessibility-reviewer`)
- `ai-engineer` — inserted after `solution-architect` (before implementation) when spec mentions LLM/RAG/agents
- `chaos-engineer` — inserted after `qa-test-engineer` (before `release-manager`) for new hot-path deps / SLO changes
- `legal-compliance-checker` — inserted after `security-reviewer` (before `release-manager`) for PII/PHI/payments
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
