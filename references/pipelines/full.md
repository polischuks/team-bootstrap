# Full Pipeline

Run roles in this order:

1. `discovery-research`
2. `product-manager`
3. `business-analyst`
4. `test-designer` ← **NEW: TDD/BDD test cases before implementation**
5. `delivery-manager`
6. `cto-tech-lead`
7. `solution-architect`
8. `backend-engineer`
9. `frontend-engineer`
10. `devops-platform`
11. `data-schema-reviewer` ← **NEW: migrations, backwards compatibility**
12. `accessibility-reviewer` ← **NEW: WCAG compliance**
13. `performance-reviewer` ← **NEW: N+1, memory, scalability**
14. `security-reviewer` ← **NEW: OWASP, secrets, auth**
15. `qa-test-engineer`
16. `overengineering-reviewer`
17. `code-reviewer`
18. `release-manager`
19. `stakeholder-communicator` ← **NEW: non-technical release notes**
20. `documentation-agent`

## Optional Roles (triggered by incidents, not part of normal flow)

- `incident-responder` — triggered when production issues occur

Use the same handoff rule as the MVP pipeline: no silent skips, explicit `next_role`, stop on `blocked` or `needs_input`.

## Role Flow Diagram

```
discovery-research
       ↓
product-manager
       ↓
business-analyst
       ↓
test-designer ← defines tests BEFORE implementation
       ↓
delivery-manager
       ↓
cto-tech-lead
       ↓
solution-architect
       ↓
backend-engineer → frontend-engineer
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
                  qa-test-engineer
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
