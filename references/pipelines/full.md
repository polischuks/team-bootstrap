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
10. `integration-verifier` ← **outcome-based: E2E path runs + no orphans (dead code) — hard gate**
11. `architecture-reviewer` ← **conformance: no drift from the app's architecture baseline — hard gate**
12. `regression-guardian` ← **cumulative: invariants across all workflows + graduate + gate integrity — hard gate**
13. `devops-platform`
14. `data-schema-reviewer` ← **migrations, backwards compatibility**
15. `accessibility-reviewer` ← **WCAG compliance**
16. `performance-reviewer` ← **N+1, memory, scalability**
17. `security-reviewer` ← **OWASP, secrets, auth**
18. `qa-test-engineer`
19. `overengineering-reviewer`
20. `code-reviewer`
21. `release-manager`
22. `stakeholder-communicator` ← **non-technical release notes**
23. `documentation-agent`

## Optional Roles (triggered by spec content, not part of normal flow)

Inserted into the pipeline at the position noted in [role-matrix.md](../role-matrix.md):

**Pre-release optional roles:**
- `ux-researcher` — inserted after `discovery-research` (before `product-manager`) when new user-facing flow lacks prior research
- `product-marketer` — inserted after `product-manager` (before `business-analyst`) when new product / new ICP / repositioning / pricing change / new GTM motion
- `ux-designer` — inserted after `product-marketer` / `business-analyst`, before `ui-designer` — when novel interaction patterns or UX = core moat
- `ui-designer` — inserted after `ux-designer`, before `frontend-engineer` — when new product visual identity or design-system-from-scratch
- `whimsy-injector` — inserted after `frontend-engineer` (before `accessibility-reviewer`)
- `ai-engineer` — inserted after `solution-architect` (before implementation) when spec mentions LLM/RAG/agents
- `chaos-engineer` — inserted after `qa-test-engineer` (before `release-manager`) for new hot-path deps / SLO changes
- `legal-compliance-checker` — inserted after `security-reviewer` (before `release-manager`) for PII/PHI/payments

**Post-release optional roles (v1.4 + v1.5 — parallel fan-out before growth synthesis):**

After `release-manager` makes the go decision, up to 3 strategic roles can run in **parallel** (CSM, partnerships, community), each producing artifacts that `growth-marketer` then synthesizes into the unified channel + content strategy. Sequential fallback works if parallel dispatch isn't available.

- `customer-success-manager` — retention model + VoC + cohort dashboard. Required when subscription business or expansion motion.
- `partnerships-lead` — ecosystem strategy + partner pipeline. Required when ecosystem-first GTM or distribution-ceiling problem.
- `community-manager` — community channel strategy + ambassador program. Required when buyer evaluates through community signals.
- `growth-marketer` — synthesizes the above three (if run) into channel mix + content engine + AI search posture + growth loops. Position: after the parallel fan-out, before `stakeholder-communicator`.

**Incident pipeline (separate):**
- `incident-responder` — separate `incident` pipeline when production issues occur

Use the same handoff rule as the MVP pipeline: no silent skips, explicit `next_role`, stop on `blocked` or `needs_input`.

## Role Flow Diagram

```
discovery-research
       ↓
   [ux-researcher?]            ← optional
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
        ┌────────────────┼────────────────┐         ← v1.5: parallel post-release fan-out
        ↓                ↓                ↓
[customer-      [partnerships-    [community-
 success-        lead?]            manager?]
 manager?]
        └────────────────┼────────────────┘
                         ↓
              [growth-marketer?]            ← synthesizes CSM/partnerships/community outputs
                         ↓
             stakeholder-communicator
                         ↓
               documentation-agent
```

## Design stages — when to include

The two design roles (`ux-designer` + `ui-designer`) are **opt-in**. Triggers:

- **Greenfield consumer / prosumer product** — both roles strongly recommended; UX decisions made at `frontend-engineer` runtime tend toward generic AI-aesthetic
- **B2B product where UX = core moat** — both roles recommended (e.g. operator-first tools, agentic workflows, novel interaction patterns)
- **Internal admin tool / dashboard** — neither role; `frontend-engineer` can follow shadcn/ui defaults
- **Iteration on existing design system** — `ui-designer` skipped (use existing tokens); `ux-designer` if interaction patterns change
- **Visual refresh of existing product** — `ui-designer` only

Both roles produce artifacts that the next role inherits:
- `ux-designer` → IA + flows + wireframes + interaction patterns + component inventory → consumed by `ui-designer`
- `ui-designer` → design tokens + component library spec + reference prototype + implementation mapping → consumed by `frontend-engineer`

## Marketing stages — when to include

The two marketing-strategy roles (`product-marketer` + `growth-marketer`) are **opt-in**. Triggers:

- **Greenfield product launch with reach goals** — both roles strongly recommended; positioning informs scope; growth strategy maps launch to compounding motion
- **New feature in different ICP** — `product-marketer` recommended (repositioning); `growth-marketer` if channel strategy changes
- **Pricing change > 20%** — `product-marketer` required (pricing strategy + competitive battle cards)
- **Repositioning (pivot)** — both roles required; old positioning needs explicit retirement, new positioning needs full GTM plan
- **Existing product growth plateau** — `growth-marketer` required (diagnose channel exhaustion, surface new growth loops)
- **AI search / GEO category shift** — `growth-marketer` required (AEO posture + content engine repositioning)
- **Internal tool / private beta / dev-only feature** — neither role (no market motion)
- **Patch / bug fix / incremental improvement to existing product** — neither role (use `stakeholder-communicator` for release notes)

## Post-release stages — when to include (v1.5)

The three post-release strategic roles (`customer-success-manager` + `partnerships-lead` + `community-manager`) are **opt-in** and run in **parallel** after `release-manager`, before `growth-marketer` synthesizes their outputs. Triggers:

**`customer-success-manager`:**
- Subscription product with retention as primary revenue mechanism (NRR / GRR matters)
- Stalling existing retention / rising churn / declining health scores
- Expansion motion design (multi-seat, multi-product, multi-tier upsell)
- Pricing change > 20% (renewal cohort risk)
- Voice-of-customer synthesis after material feedback collection
- **Skip when:** transactional product (one-and-done), pre-revenue, no retention goals

**`partnerships-lead`:**
- Ecosystem-first GTM (developer tools, platform plays, multi-CMS / multi-stack integrations)
- Existing product reaching distribution ceiling on direct channels
- Trust-transfer category (security, finance, healthcare, B2B SaaS to non-tech buyer)
- Geographic expansion via local partners (regulatory, cultural, language fit)
- M&A signal in adjacent category creating partnership window
- **Skip when:** product can scale on direct channels (consumer freemium, paid acquisition primary), early-stage with no partner audience

**`community-manager`:**
- Product whose buyer evaluates through community signals (developer tools, prosumer SaaS, AI products, indie hackers, agencies)
- Existing community present but lacking strategy / metrics / cadence
- Launch where social proof from community matters more than ad spend (PLG, bottoms-up adoption, freemium)
- Crisis / negative sentiment requiring community moderation + VoC
- Category where competitors own communities and we're outside the conversation
- **Skip when:** enterprise-only direct-sales product (community not buyer signal), pre-product (nothing to discuss yet)

**Coordination pattern (parallel fan-out → synthesis):**

When 2+ of {CSM, partnerships, community} run, they execute in parallel as separate subagent dispatches (if available) or sequentially (if not). Each produces independent strategic artifacts. `growth-marketer` then runs **after** them and **synthesizes**:

- Channel mix incorporates partnership channel target (from partnerships-lead) + community channel target (from community-manager) + retention loops (from CSM)
- Content engine incorporates community-led content (community-manager) + customer story content (CSM)
- AI search posture works with community-manager on which community surfaces influence AI citations
- Growth loops incorporate CSM expansion loops + community advocacy loops + partnership amplification loops

**Skill-blocking constraint:** All three v1.5 roles have strictly required skills that cause `status: blocked` if missing. Unlike other roles where skills degrade gracefully:

| Role | Blocking skills | Why blocking |
|---|---|---|
| `customer-success-manager` | `persona-customer-support`, `research-synthesis`, `humanize-ai-text` | CSM comms can't be AI-detectable without destroying customer trust |
| `partnerships-lead` | `idea-refine`, `humanize` | Partnership outreach gets autoflagged when AI-detected; thesis convergence requires structured narrowing |
| `community-manager` | `humanize`, `humanize-ai-text` | Communities reject AI-detected content faster than any other audience; non-negotiable |

If a blocking skill is missing, the role returns `status: blocked` with the skill named in `risks_or_blockers`. The pipeline halts (per [failure-policy.md](../failure-policy.md)) until the skill is installed or the role is explicitly excluded.
