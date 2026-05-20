# Changelog

All notable changes to team-bootstrap. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.2.1] - 2026-05-20

### Added

Skill ecosystem integration for `audit-dd` pipeline (gap closed from v1.2.0 — roles referenced skills in prose but `tool_surface` didn't permit the `Skill` tool, and there was no install verification).

- **`Skill` tool** added to all 6 audit-dd role `tool_surface.allow` lists (financial-analyst, market-analyst, customer-health-analyst, ip-contracts-reviewer, culture-team-dd, investment-thesis-author). Roles can now invoke skills at runtime.
- **`## Recommended skills` section** in each of the 6 role playbooks — explicit skill-name → when-to-invoke → what-it-gives mapping per role. Highest-leverage skills called out (e.g. `30x-seo-ai-visibility` for market-analyst's AI-displacement assessment; `data-storyteller` for investment-thesis-author's memo synthesis).
- **`skills-manifest.json`** at repo root — declarative list of required / recommended / optional skills per pipeline. Includes per-skill `purpose` + `fallback` so users know what's lost if a skill is missing.
- **`bin/check-skills.sh`** — verification script. Reads manifest, checks `~/.claude/skills/<name>/SKILL.md` for each, reports installed / missing. JSON output (`--json`) for CI gating. Exit codes: 0 = all recommended present, 1 = required missing, 2 = recommended missing (pipeline runs with fallbacks).
- **INSTALL.md** updated with new "Audit-DD pipeline — install referenced skills" section. Documents that team-bootstrap does NOT auto-fetch skills (no canonical marketplace registry across users); provides install paths via `/plugin install`, manual git clone, or scp from another machine. Includes per-skill table with fallback behavior.

### Why no auto-fetch

Skills live in disparate sources: some come from `addyosmani/agent-skills`, some from 30x.dev / Anthropic bundles, some are personal / community packs. License terms vary; canonical URLs aren't tracked across installs. Auto-fetching would either pin upstream sources (fragile when they move) or vendor copies in this repo (license risk). Manifest + verification is the safer default; users opt-in to fetching.

### Migration

All 6 audit-dd roles bump to `version: 1.1.0`. Backwards compatible — fallback paths preserve the v1.0.0 behavior (WebSearch/WebFetch only) when skills aren't installed.

## [1.2.0] - 2026-05-20

### Added

Commercial / financial due-diligence support. Six new roles + one new pipeline targeting the **`audit-dd`** use case (pre-fundraise / M&A / board prep), distinct from the existing technical `audit` pipeline.

- **`audit-dd` pipeline** ([references/pipelines/audit-dd.md](references/pipelines/audit-dd.md)) — six-role read-only DD run; output is an investor-grade memo (1-pager + 10-page deep dive), not a backlog. Composes with `audit` (run technical audit first, then DD on top).
- **`financial-analyst` role** — ARR build with cohort retention, unit economics (LTV/CAC, CAC payback, Burn Multiple, Magic Number, Rule of 40, NRR), valuation triangulation against 2026 SaaS / AI comps (Bull/Base/Bear).
- **`market-analyst` role** — TAM/SAM/SOM triangulated top-down × bottoms-up, 5-vector moat scoring, **AI-search displacement risk** assessment (can ChatGPT/Perplexity/Claude/Gemini answer the JTBD directly?).
- **`customer-health-analyst` role** — cohort retention curves (logo + GRR + NRR all separate, never aggregated), concentration table (top-customer > 20% = red flag), AI-product-specific signals (API usage retention, model-call cohort behavior, prompt-engineering education curve).
- **`ip-contracts-reviewer` role** — OSS license audit (AGPL / SSPL / Elastic-2.0 contamination detection), **foundation-model TOS** verification (OpenAI / Anthropic / Google — terms change quarterly), customer-contract red flags (AI accuracy warranties, training-data rights, uncapped indemnities), data residency (GDPR + Schrems II SCC, CCPA / CPRA, India DPDPA, China PIPL).
- **`culture-team-dd` role** — org depth + bus factor, retention signals, compensation posture (Levels.fyi / Pave / Carta benchmarks), public sentiment (Glassdoor / LinkedIn / Blind — ethically gathered), founder dynamics.
- **`investment-thesis-author` role** — terminal synthesizer; produces 1-page memo + 10-page deep dive + invest/pass/conditional verdict with probability-weighted MOIC and explicit Bull/Base/Bear scenario weights.
- Schema updates: `audit-dd` added to `compatible_pipelines` enum; six new role consts in `role-output.schema.json` `oneOf` with role-specific required fields (e.g. `investment_recommendation`, `probability_weighted_moic`).
- `role-matrix.md` + `subagent-mapping.md` updated to surface the new DD team and inline-only constraints.

### Migration

Backwards compatible — no breaking changes to existing roles or pipelines. Existing audit / mvp / full / single-thread runs continue unchanged. Opt into the new commercial DD by invoking `/team-bootstrap audit-dd <spec>`.

## [1.0.0] - 2026-05-10

Initial productized release. Distribution structure, full P0 + P1 implementation, top-level docs.

### Added

- **Subagent dispatch model** ([references/subagent-dispatch.md](references/subagent-dispatch.md)) — when roles run inline vs. as Task-tool subagents.
- **Shared blackboard** ([references/shared-blackboard.md](references/shared-blackboard.md)) — full run document available to every role.
- **Irreversibility taxonomy** ([references/irreversibility.md](references/irreversibility.md)) — four-class action gating replaces role-level approval booleans.
- **Tracing spec** ([references/tracing.md](references/tracing.md)) — OpenTelemetry GenAI semantic conventions, run/role/tool span hierarchy, replay format.
- **Role versioning** ([references/versioning.md](references/versioning.md)) — semver per role, eval-gate convention.
- **Memory model** ([references/memory.md](references/memory.md)) — three-tier (persistent / per-run / per-role), checkpoint and resume.
- **AGENTS.md contract** ([references/agents-md-contract.md](references/agents-md-contract.md)) — required fields, per-role consumption.
- **MCP integration** ([references/mcp-integration.md](references/mcp-integration.md)) — tool-surface mapping to MCP servers.
- **Tool surface** in every role frontmatter — allow/deny lists, MCP servers, permission mode.
- **Verification loops** in `backend-engineer` and `frontend-engineer` — explicit edit→verify→repair with bounded attempts.
- **Single-thread pipeline** ([references/pipelines/single-thread.md](references/pipelines/single-thread.md)) — recommended default.
- **Role frontmatter schema** ([references/schemas/role-frontmatter.schema.json](references/schemas/role-frontmatter.schema.json)).
- Top-level docs: [README.md](README.md), [INSTALL.md](INSTALL.md), [USAGE.md](USAGE.md), [ARCHITECTURE.md](ARCHITECTURE.md).
- Plugin manifest at [.claude-plugin/plugin.json](.claude-plugin/plugin.json).
- Examples: [examples/AGENTS.md.template](examples/AGENTS.md.template), [examples/quickstart-spec.md](examples/quickstart-spec.md).
- Eval suite skeleton at [evals/](evals/).

### Changed

- `next_role` in role templates uses `<determined-by-pipeline>` placeholder; orchestrator resolves from active pipeline.
- `role-output.schema.json` — root `oneOf` discriminator on `role`; `unevaluatedProperties: false` per role; per-role required fields for 12 roles (release_decision, severity_counts, verdict, ci_status, etc.).
- [failure-policy.md](references/failure-policy.md) — irreversibility classes drive approval gates instead of role-level booleans.
- [orchestrator.md](references/orchestrator.md) — incorporates shared-blackboard load step and subagent-dispatch decision point.
- [trace-evals.md](references/trace-evals.md) — cross-links to tracing.md (capture) and versioning.md (regression gate).
- [SKILL.md](SKILL.md) — points to README/USAGE/ARCHITECTURE as primary entry; retains handoff contract reference.

### Migration from pre-1.0

- Hardcoded `next_role` values were replaced with placeholders. No action needed if you used the bundled orchestrator.
- Role files now require frontmatter (`version`, `tool_surface`, `permission_mode`). Custom roles must be updated.
- Per-role required handoff fields are enforced. Custom handoffs that omit them will fail validation.
- `manual_approval_requested` at role level still works but is deprecated. Use `irreversibility_class` per action ([references/irreversibility.md](references/irreversibility.md)).

## Pre-1.0

Earlier versions used hardcoded `next_role` per role and a JSON Schema with `$defs` only (no root discriminator). See git history for details.
