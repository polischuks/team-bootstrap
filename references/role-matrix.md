# Role Matrix

## Audit Team (15 roles, read-only)

Use this for project-state assessment against a reference (spec, design, production-readiness checklist). Output: prioritized backlog. Each item then runs through `single-thread` / `mvp` / `full` separately. See [pipelines/audit.md](pipelines/audit.md).

| Role | Purpose |
| --- | --- |
| `discovery-research` | Gather external context: spec docs, design refs, standards. |
| `cto-tech-lead` | Set quality bar and risk posture for the audit. |
| `solution-architect` | Assess architecture against spec; identify structural gaps. |
| `data-schema-reviewer` | Schema, migrations, data integrity. |
| `security-reviewer` | OWASP, secrets, auth, PII. |
| `accessibility-reviewer` | WCAG compliance of shipped UI. |
| `performance-reviewer` | N+1, memory, scalability, hot paths. |
| `ai-engineer` (optional) | LLM/RAG/agent layer state, evals, cost. |
| `legal-compliance-checker` (optional) | GDPR/CCPA/HIPAA/PCI/COPPA/platform-policy. |
| `ux-researcher` (optional) | Design compliance, friction. |
| `qa-test-engineer` | Test coverage, suite health. |
| `overengineering-reviewer` | Complexity vs value. |
| `code-reviewer` | Overall code quality, conventions. |
| `documentation-agent` | Docs gap analysis. |
| `release-manager` | Synthesize → backlog + go/no_go. |

## MVP Team (7 roles)

Use this by default for quick iterations.

| Role | Purpose | Typical outputs |
| --- | --- | --- |
| `product-ba` | Convert the spec into user stories, requirements, and edge cases. | brief, stories, requirements, edge cases |
| `delivery-manager` | Turn requirements into an execution plan. | delivery plan, task breakdown, dependency map |
| `cto-architect` | Define constraints, contracts, and decisions. | technical direction, constraints, contracts, ADR |
| `backend-engineer` | Implement backend changes. | code, backend notes |
| `frontend-engineer` | Implement frontend changes. | code, frontend notes, UI notes |
| `qa-test-engineer` | Validate behavior and collect evidence. | test plan, QA report, defect list |
| `release-docs` | Make the final go or no-go and doc handoff. | release decision, release notes, runbook notes |

## Full Team (20 roles)

Use this for production releases with full quality gates.

| Role | Purpose | Category |
| --- | --- | --- |
| `discovery-research` | Gather external evidence and examples. | Discovery |
| `product-manager` | Define scope and success metrics. | Product |
| `business-analyst` | Formalize requirements and flows. | Product |
| `test-designer` | Design test strategy and cases BEFORE implementation (TDD/BDD). | **Quality (Pre-impl)** |
| `delivery-manager` | Plan execution and dependencies. | Planning |
| `cto-tech-lead` | Set quality bar and risk posture. | Architecture |
| `solution-architect` | Define architecture and integration boundaries. | Architecture |
| `backend-engineer` | Implement backend changes. | Implementation |
| `frontend-engineer` | Implement frontend changes. | Implementation |
| `devops-platform` | Handle infrastructure and CI concerns. | Infrastructure |
| `data-schema-reviewer` | Review migrations, backwards compatibility, data integrity. | **Review** |
| `accessibility-reviewer` | Review WCAG compliance, keyboard nav, screen readers. | **Review** |
| `performance-reviewer` | Review N+1 queries, memory leaks, scalability. | **Review** |
| `security-reviewer` | Review OWASP risks, secrets, auth flows, PII handling. | **Review** |
| `qa-test-engineer` | Validate and report defects. | Quality |
| `overengineering-reviewer` | Audit complexity vs product value. | Review |
| `code-reviewer` | Review the diff and evidence. | Review |
| `release-manager` | Decide release readiness. | Release |
| `stakeholder-communicator` | Translate technical changes to business language. | **Communication** |
| `documentation-agent` | Update README, changelog, runbooks, notes. | Documentation |

## Optional Roles (not in normal flow)

| Role | Purpose | Trigger | Inserts after |
| --- | --- | --- | --- |
| `incident-responder` | Execute rollback, post-mortem, prevention planning. | Production incident | (separate `incident` pipeline) |
| `ai-engineer` | Implement LLM/RAG/agent features with evals and cost budgets. | Spec mentions LLM/RAG/agents/embeddings | `solution-architect` (before implementation) |
| `ux-researcher` | Surface user segments, friction, mental models. | New user-facing flow without prior research | `discovery-research` (before product-manager) |
| `ux-designer` | Translate research into IA, flows, wireframes, interaction patterns, mental-model mapping, UX writing. | New user-facing product/feature; novel interaction patterns; UX = core moat | `ux-researcher` or `product-manager` (before ui-designer) |
| `ui-designer` | Translate UX architecture into design tokens, component library, reference prototype. | New product visual identity; design-system from scratch; visual polish = differentiation | `ux-designer` (before frontend-engineer) |
| `whimsy-injector` | Add delightful micro-interactions, copy, animations. | New user-facing UI surface | `frontend-engineer` (before accessibility-reviewer) |
| `chaos-engineer` | Design (and optionally run) failure experiments. | New external dep in hot path; SLO change | `qa-test-engineer` (before release-manager) |
| `legal-compliance-checker` | Flag GDPR/CCPA/HIPAA/PCI/COPPA/platform-policy obligations. | PII/PHI/payments/new region/new processor | `security-reviewer` (before release-manager) |

## Audit-DD Team (6 roles, read-only)

Use this for **commercial / financial / strategic** due diligence — pre-fundraise, M&A, board prep, annual review. Distinct from `audit` (technical / operational). Composes well with `audit`: run technical audit first, then DD around it. See [pipelines/audit-dd.md](pipelines/audit-dd.md).

| Role | Purpose |
| --- | --- |
| `financial-analyst` | ARR build, unit economics, capital efficiency, valuation (Bull/Base/Bear). 2026 benchmarks: NRR ≥ 110%, Rule of 40 ≥ 40%, Burn Multiple < 2×. |
| `market-analyst` | TAM/SAM/SOM (triangulated top-down × bottoms-up), 5-vector moat scoring, AI-search displacement risk. |
| `customer-health-analyst` | Cohort retention curves, NRR/GRR/logo retention separately, concentration table, AI-product-specific signals. |
| `ip-contracts-reviewer` | OSS license audit (AGPL/SSPL/Elastic-2.0 contamination), foundation-model TOS (2026-aware), customer contract red flags, data residency (GDPR/CCPA/India DPDPA). |
| `culture-team-dd` | Org depth, key-person risk (bus factor), retention signals, comp posture, founder dynamics, ethically-gathered public sentiment. |
| `investment-thesis-author` | Synthesize → one-page memo + ten-page deep dive + invest/pass/conditional verdict with probability-weighted MOIC. |

## Selection Rule

- **Audit:** Project-state assessment, production-readiness review, quarterly health check. Read-only; outputs a backlog for `single-thread` / `mvp` / `full` follow-up runs.
- **Audit-DD:** Pre-fundraise, M&A, board prep — commercial / financial / strategic DD. Outputs investor-grade memo. Compose with `audit` for full technical + commercial coverage.
- **MVP:** Quick iterations, internal tools, low-risk changes.
- **Full:** Production releases, customer-facing features, security-sensitive changes.
- **With security-reviewer:** Any auth, payment, PII, or external API integration.
- **With data-schema-reviewer:** Any database migration or schema change.
- **With accessibility-reviewer:** Any user-facing UI changes.
- **With performance-reviewer:** Any data-heavy or high-traffic endpoints.
- **With ai-engineer:** Any LLM/RAG/agent/embeddings feature.
- **With ux-researcher:** New audience or redesigned flow without prior research.
- **With ux-designer:** New user-facing product/feature with novel flows; UX architecture decisions can't be left to frontend-engineer's discretion.
- **With ui-designer:** New product visual identity; need design tokens + reference prototype before frontend implementation.
- **With whimsy-injector:** New user-facing surface where delight matters.
- **With chaos-engineer:** New hot-path dependency or tightened SLO.
- **With legal-compliance-checker:** PII/PHI/payments, new region, new processor, or platform-policy surface.

## Role Dependencies

```
test-designer → must run BEFORE backend-engineer/frontend-engineer
data-schema-reviewer → must run AFTER devops-platform (migrations deployed)
security-reviewer → must run BEFORE qa-test-engineer (security issues block QA)
stakeholder-communicator → must run AFTER release-manager (release decision made)
```

## Tool surfaces and per-role schemas

As of v1.0, every role declares a `tool_surface` and `permission_mode` in its frontmatter (validated by [schemas/role-frontmatter.schema.json](schemas/role-frontmatter.schema.json)) and adds per-role required handoff fields where applicable (validated by [schemas/role-output.schema.json](schemas/role-output.schema.json)). See [versioning.md](versioning.md).

## Pipeline default

The default pipeline as of v1.0 is [single-thread](pipelines/single-thread.md). MVP and Full are opt-in for tasks needing role-by-role audit trail. See [../ARCHITECTURE.md](../ARCHITECTURE.md) for rationale.
