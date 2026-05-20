# Subagent Mapping

When the orchestrator dispatches a team-bootstrap role as a subagent (per [subagent-dispatch.md](subagent-dispatch.md)), it must pick a concrete `subagent_type` for Claude Code's `Task` tool.

This file is the **single source of truth** for that mapping. It replaces the pre-v1.1 default of always dispatching `subagent_type: general-purpose`.

## How the orchestrator uses this file

1. Read the role playbook's `preferred_subagent_types: [...]` list from frontmatter (validated by [schemas/role-frontmatter.schema.json](schemas/role-frontmatter.schema.json)).
2. Walk the list left-to-right. Pick the **first** slug that is:
   - registered in the host environment (resolvable by `Task`), AND
   - not contradicted by a stack rule below (e.g. don't pick `nextjs-developer` for a Django repo).
3. If none match, fall back to `general-purpose`.
4. Record the resolved slug in the trace span (`team_bootstrap.subagent_type`) so eval/replay sees the routing decision.

Roles **without** `preferred_subagent_types` (or with an empty list) run inline only — they are decision-making roles where private context fragments the run document (see [subagent-dispatch.md](subagent-dispatch.md) anti-patterns). Even if the orchestrator decides to dispatch them, fallback is `general-purpose`.

The harness — not the LLM — enforces `tool_surface` and `permission_mode` from the role frontmatter on top of whatever the chosen specialist's own defaults are; the specialist's expertise is used, but the team-bootstrap guardrails win on tools and permissions.

## Mapping table

`primary` is the first choice when the project stack matches a generic agent. `stack_overrides` let the orchestrator pick a more specialized agent based on `AGENTS.md > ## Stack`. Fallbacks are ordered; `general-purpose` is the implicit final fallback.

| Role | Primary | Stack overrides (when applicable) | Fallbacks |
| --- | --- | --- | --- |
| `discovery-research` | `trend-researcher` | — | `general-purpose` |
| `product-manager` | `sprint-prioritizer` | — | `general-purpose` |
| `product-ba` | `sprint-prioritizer` | — | `business-analyst`, `general-purpose` |
| `business-analyst` | `business-analyst` | — | `feedback-synthesizer`, `general-purpose` |
| `delivery-manager` | `studio-producer` | — | `sprint-prioritizer`, `general-purpose` |
| `cto-architect` | `backend-architect` | — | `architect-reviewer`, `architect-review`, `general-purpose` |
| `cto-tech-lead` | `architect-reviewer` | — | `architect-review`, `backend-architect`, `general-purpose` |
| `solution-architect` | `backend-architect` | `microservices → microservices-architect`; `graphql → graphql-architect`; `websocket/realtime → websocket-engineer`; `event-sourced → event-sourcing-architect` | `api-designer`, `architect-reviewer`, `general-purpose` |
| `test-designer` | `tdd-orchestrator` | — | `test-engineer`, `qa-expert`, `test-automator`, `general-purpose` |
| `backend-engineer` | `backend-developer` | `nestjs/node/express → node-specialist`; `fastapi → fastapi-developer`; `django → django-developer`; `rails → rails-expert`; `laravel → laravel-specialist`; `spring-boot → spring-boot-engineer`; `csharp/.net → csharp-developer` or `dotnet-core-expert`; `go → golang-pro`; `rust → rust-engineer`; `python (general) → python-pro`; `typescript (general) → typescript-pro`; `php → php-pro` | `fullstack-developer`, `backend-architect`, `general-purpose` |
| `frontend-engineer` | `frontend-developer` | `next.js → nextjs-developer`; `react (no next) → react-specialist`; `vue/nuxt → vue-expert`; `angular → angular-architect`; `react-native → expo-react-native-expert` or `mobile-developer`; `flutter → flutter-expert`; `electron → electron-pro` | `fullstack-developer`, `ui-designer`, `general-purpose` |
| `devops-platform` | `devops-engineer` | `kubernetes → kubernetes-specialist` or `kubernetes-architect`; `terraform → terraform-specialist` or `terraform-engineer`; `terragrunt → terragrunt-expert`; `docker-heavy → docker-expert`; `azure → azure-infra-engineer`; `aws/gcp/multi-cloud → cloud-architect`; `windows → windows-infra-admin`; `platform/IDP work → platform-engineer` | `deployment-engineer`, `devops-automator`, `sre-engineer`, `general-purpose` |
| `data-schema-reviewer` | `database-administrator` | `complex schema design → database-architect`; `query/perf focus → database-optimizer`; `pure SQL → sql-pro` | `general-purpose` |
| `accessibility-reviewer` | `accessibility-tester` | — | `ui-ux-tester`, `general-purpose` |
| `performance-reviewer` | `performance-engineer` | — | `performance-benchmarker`, `general-purpose` |
| `security-reviewer` | `security-auditor` | `infra/cloud-heavy → security-engineer`; `backend code → backend-security-coder`; `active exploitation/CTF context → penetration-tester`; `compliance frameworks → compliance-auditor` | `ad-security-reviewer`, `general-purpose` |
| `qa-test-engineer` | `qa-expert` | `e2e/browser → ui-ux-tester`; `automation suites → test-automator`; `existing-code fix-ups → test-writer-fixer` | `test-engineer`, `general-purpose` |
| `overengineering-reviewer` | `architect-reviewer` | — | `code-reviewer`, `architect-review`, `general-purpose` |
| `code-reviewer` | `code-reviewer` | — | `architect-review`, `architect-reviewer`, `general-purpose` |
| `release-manager` | `deployment-engineer` | — | `project-shipper`, `release-manager`, `general-purpose` |
| `release-docs` | `project-shipper` | — | `deployment-engineer`, `docs-architect`, `general-purpose` |
| `stakeholder-communicator` | `content-creator` | `customer-facing → support-responder` | `general-purpose` |
| `documentation-agent` | `docs-architect` | `API reference → api-documenter`; `tutorials/learning paths → tutorial-engineer`; `exhaustive config refs → reference-builder`; `diagrams → mermaid-expert` | `general-purpose` |
| `incident-responder` | `incident-responder` | `infra/k8s-heavy → devops-incident-responder`; `troubleshooting before resolution → devops-troubleshooter` | `error-detective`, `general-purpose` |

## New roles added in v1.1 (item 5 from the upgrade plan)

| Role | Primary | Stack overrides | Fallbacks |
| --- | --- | --- | --- |
| `ai-engineer` | `ai-engineer` | `vector-search/RAG → vector-database-engineer`; `prompt-tuning → prompt-engineer` | `general-purpose` |
| `ux-researcher` | `ux-researcher` | — | `feedback-synthesizer`, `general-purpose` |
| `whimsy-injector` | `whimsy-injector` | — | `ui-designer`, `general-purpose` |
| `chaos-engineer` | `chaos-engineer` | — | `sre-engineer`, `general-purpose` |
| `legal-compliance-checker` | `legal-compliance-checker` | `regulated framework audit (HIPAA/PCI/SOC2/GDPR) → compliance-auditor` | `general-purpose` |

## Audit-DD roles (v1.2 — commercial / financial DD)

These six roles are exclusive to the `audit-dd` pipeline. None have a perfect-fit specialist subagent (DD is a generalist task crossing finance, market research, legal, and HR domains), so most route through `general-purpose` with at least one narrower fallback for partial coverage.

| Role | Primary | Stack overrides | Fallbacks |
| --- | --- | --- | --- |
| `financial-analyst` | `business-analyst` | — | `general-purpose` |
| `market-analyst` | `trend-researcher` | — | `general-purpose` |
| `customer-health-analyst` | `feedback-synthesizer` | — | `business-analyst`, `general-purpose` |
| `ip-contracts-reviewer` | `compliance-auditor` | `pure regulatory audit → legal-compliance-checker` | `general-purpose` |
| `culture-team-dd` | `feedback-synthesizer` | — | `general-purpose` |
| `investment-thesis-author` | `general-purpose` | — | (terminal — no fallback chain needed; orchestrator always runs inline as final synthesizer) |

**Inline-only:** All six roles should generally run **inline** (not dispatched as subagents) because each one's findings feed into `investment-thesis-author`'s synthesis — fragmenting them across subagent contexts risks the synthesizer missing cross-axis correlations (e.g. a financial red flag that explains a customer-health pattern). Dispatch only with explicit `--isolate` for compliance-separation reasons.

## Stack-detection rule

The orchestrator reads `AGENTS.md > ## Stack` (or, missing that, infers from package manifests: `package.json`, `pyproject.toml`, `go.mod`, `Cargo.toml`, `Gemfile`, `composer.json`, `*.csproj`). Detection happens **once** at run start; the resolved stack vector is recorded in the run metadata so subsequent role dispatches use it deterministically.

If detection is ambiguous, fall through to the role's `primary` slug — never silently swap.

## Inline-only roles

These roles **must not** be dispatched as subagents (see [subagent-dispatch.md](subagent-dispatch.md#do-not-dispatch)):

- `product-ba`, `product-manager`, `business-analyst` — planning decisions the next role inherits
- `delivery-manager` — same
- `cto-architect`, `cto-tech-lead`, `solution-architect` — architectural decisions the next role inherits
- `backend-engineer`, `frontend-engineer` — edit + verify must stay coherent in the main thread
- `release-manager`, `release-docs` — final go/no-go decision needs full blackboard
- `stakeholder-communicator` — depends on release decision context
- `investment-thesis-author` — final synthesizer for `audit-dd`; must read all prior DD blackboard
- All other `audit-dd` roles — see Audit-DD section above; cross-axis correlations need shared context

Their `preferred_subagent_types` is still set (for the rare override case: e.g. user explicitly requests `--isolate` on an architect role for compliance separation). The default is inline.

## Cases where dispatch is encouraged

- `discovery-research` (web fetches are bulky)
- All four reviewers: `data-schema-reviewer`, `accessibility-reviewer`, `performance-reviewer`, `security-reviewer` (parallel reviewer fan-out, see [subagent-dispatch.md](subagent-dispatch.md#parallel-dispatch-reviewers))
- `qa-test-engineer` when running long test suites
- `documentation-agent` when generating large reference output
- `incident-responder` for cross-system log gathering
- `test-designer` when surveying existing tests across many files

## Maintenance

When adding a new role:

1. Append a row here.
2. Add `preferred_subagent_types: [...]` to the role's frontmatter.
3. Register the role in [schemas/role-output.schema.json](schemas/role-output.schema.json) and the relevant pipeline file under [pipelines/](pipelines/).
4. Bump the role's `version` and append an entry to [../CHANGELOG.md](../CHANGELOG.md).

When a new specialist subagent becomes available system-wide, prefer adding it to **fallbacks** first. Only promote it to `primary` after at least one full pipeline run validates its handoff quality (see [trace-evals.md](trace-evals.md)).

## See also

- [subagent-dispatch.md](subagent-dispatch.md) — when to dispatch at all
- [orchestrator.md](orchestrator.md) — execution loop integration
- [role-matrix.md](role-matrix.md) — role catalog
- [schemas/role-frontmatter.schema.json](schemas/role-frontmatter.schema.json) — frontmatter validation
