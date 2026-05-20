# Changelog

All notable changes to team-bootstrap. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.4.0] - 2026-05-20

### Added

Dedicated GTM + ongoing growth stages for the `full` and `single-thread` pipelines. Closes a gap from v1.0–v1.3 where the pipeline shipped products but had no role responsible for positioning, ICP selection, pricing strategy, launch sequencing, channel strategy, content engine, or AI search posture. Existing `stakeholder-communicator` produced release notes one-shot; nothing built the ongoing growth motion.

- **`product-marketer` role** ([references/roles/product-marketer.md](references/roles/product-marketer.md)) — Canonical Product Marketing Manager (PMM) function. Owns ICP definition, positioning statement, category framing, messaging hierarchy, pricing strategy, launch sequencing (alpha/beta/GA), sales enablement (discovery questions + objection handling + ROI calculator inputs), competitive battle cards. Position: after `product-manager`, before `business-analyst` — positioning shapes downstream requirements rather than arriving post-release. Inline-only by default.

- **`growth-marketer` role** ([references/roles/growth-marketer.md](references/roles/growth-marketer.md)) — Strategic growth function (CMO-equivalent, named for work not title). Owns channel strategy (mix + CAC + ramp + kill criteria), content engine (cadence + topic clusters + SEO/AEO posture), brand-as-moat (category-defining terminology, recognized-metric play, community positioning), growth loops (with k-factor / payback), attribution model, AI search posture per platform (ChatGPT / Perplexity / Claude / Gemini / Google AI Overview), growth experiments backlog (ICE-ranked), 30/60/90 day plan. Position: after `release-manager`, before `stakeholder-communicator` — translates ship event into compounding growth motion. Inline-only by default.

- **Skill ecosystem integration for both roles** — `Skill` in `tool_surface.allow`; `## Recommended skills` section per role; all referenced skills present in canonical local installs (`~/.claude/skills/<name>/SKILL.md`):
  - `product-marketer` core: `competitor-analysis` (non-negotiable for positioning), `copywriter`, `brief`, `tavily-research`, `idea-refine`, `persona-customer-support`
  - `growth-marketer` core: `30x-seo-ai-visibility` (highest leverage in 2026), `ai-seo`, `seo-aeo-best-practices`, `seo-audit`, `seo-geo`, `find-keywords`, `programmatic-seo`, `backlink-analyzer`, `competitor-analysis`, `tavily-research`, `social-media-posts`, `copywriter`, `brief`, `data-storyteller`, `idea-refine`

- **`skills-manifest.json`** v1.2.0 — extends `full` pipeline section with 14 additional marketing-specific optional skills. Total `full` pipeline now: 4 recommended + 18 optional skills. `bin/check-skills.sh full` resolves all 22 against local installs.

- **`pipelines/full.md`** updated — `product-marketer` inserted after `product-manager` (before `business-analyst`); `growth-marketer` inserted after `release-manager` (before `stakeholder-communicator`); updated role flow diagram + new "Marketing stages — when to include" decision matrix (greenfield launch / pricing change / repositioning / growth plateau / AEO shift / internal tool / patch).

- **`subagent-mapping.md`** updated — new "Marketing roles (v1.4)" section with primary + fallback subagent types; both roles added to inline-only list.

- **`role-matrix.md`** updated — both roles in Optional Roles table with triggers + "Inserts after" position; new selection-rule entries (with product-marketer / with growth-marketer).

- **`role-output.schema.json`** updated — `product-marketer` + `growth-marketer` added to root `oneOf`; new per-role definitions with role-specific required fields (`positioning_confidence`, `pricing_confidence`, `primary_channel_thesis`, `ai_search_priority`).

- **`INSTALL.md`** updated with new "Full pipeline — install referenced skills for marketing roles" section. Per-skill table + install priority by product type (greenfield launch / pricing change / growth plateau / content scaling / internal tool / patch).

### Why dedicated marketing stages

The pipeline previously assumed products would just "ship" — `release-manager` made go/no-go, `stakeholder-communicator` wrote business-language release notes, done. But the gap between "shipping" and "growing" is where most products die — `product-marketer` answers "who buys this and what do we say" before development, and `growth-marketer` answers "how does this compound week-over-week" after launch. Without these roles, GTM decisions are made by founders at runtime under pressure, which is the wrong cognitive context (focus on shipping, not market motion).

For products entering markets where AI search visibility (AEO / GEO) is now the primary growth surface — every consumer / prosumer / B2B product launching in 2026 — `growth-marketer` is the role that owns the AI search posture explicitly. Without it, AEO/GEO defaults to "we'll figure it out post-launch," which is too late.

### Total role count

team-bootstrap v1.4.0 now ships **38 roles** total (up from 36 in v1.3): 14 implementation roles + 8 review roles + 6 audit-DD roles + 4 strategic roles (discovery / product-manager / product-ba / business-analyst) + 2 design roles + 2 marketing roles + 2 release roles + others.

### Migration

Backwards compatible — no breaking changes to existing roles or pipelines. Existing `mvp` / `full` / `single-thread` / `audit` / `audit-dd` runs continue unchanged when marketing roles are not opted in. Opt into marketing stages by inserting `product-marketer` and/or `growth-marketer` in the pipeline per the [pipelines/full.md](references/pipelines/full.md) "Marketing stages — when to include" decision matrix.

### Inline-only rationale

Both `product-marketer` and `growth-marketer` run inline by default — their strategic artifacts (positioning / pricing / channel mix / content cadence / launch sequencing) are inherited by downstream release + communication roles. Fragmenting them across subagent contexts risks `release-manager` missing the launch sequencing or `stakeholder-communicator` missing the brand narrative. Dispatch only with explicit `--isolate` when running a marketing-only audit with no release decision downstream.

## [1.3.0] - 2026-05-20

### Added

Dedicated UX/UI design stages for the `full` and `single-thread` pipelines. Closes a gap from v1.0–v1.2 where `frontend-engineer` was expected to consume "UI specs" that no upstream role produced — design decisions defaulted to runtime intuition, which is the root cause of generic AI-aesthetic output across the pipeline.

- **`ux-designer` role** ([references/roles/ux-designer.md](references/roles/ux-designer.md)) — Translates research into interaction architecture: information architecture, user flows, screen-by-screen wireframes (structural only, no visual styling), interaction patterns, mental-model mapping, UX writing guidelines. Position: after `ux-researcher` (or `product-manager` if research skipped), before `ui-designer`. Inline-only by default (downstream roles inherit component inventory + mental model).

- **`ui-designer` role** ([references/roles/ui-designer.md](references/roles/ui-designer.md)) — Translates UX architecture into visual design: design tokens (color/type/spacing/motion/radii), component library spec (variants/states/a11y contract), screen-by-screen reference prototype in HTML + Tailwind, implementation mapping (component → primitive → token usage). Position: after `ux-designer`, before `frontend-engineer`. Inline-only by default.

- **Skill ecosystem integration for both roles** — `Skill` in `tool_surface.allow`; `## Recommended skills` section per role with skill-name → when-to-invoke → what-it-gives mapping:
  - `ux-designer`: `research-synthesis`, `idea-refine`, `competitor-analysis`, `tavily-research`, `persona-customer-support`
  - `ui-designer`: `frontend-ui-engineering` (highest-leverage), `api-and-interface-design`, `image-generation`, `competitor-analysis`, `documentation-and-adrs`, `idea-refine`
  - All recommended skills present in canonical local skill installs (`~/.claude/skills/<name>/SKILL.md`)

- **`skills-manifest.json`** v1.1.0 — added `full` pipeline section with 4 recommended + 5 optional skills per design role. `bin/check-skills.sh full` now verifies install state for design stages.

- **`pipelines/full.md`** updated — new "Optional Roles" section explicitly lists `ux-designer` + `ui-designer` insertion points; new "Design stages — when to include" decision matrix; updated role flow diagram with optional design stage branches.

- **`subagent-mapping.md`** updated — new "Design roles (v1.3 — dedicated UX + UI design stages)" section with primary + fallback subagent types; both roles added to inline-only list.

- **`role-matrix.md`** updated — both roles in Optional Roles table with triggers + "Inserts after" position; new selection-rule entries.

- **`role-output.schema.json`** updated — `ux-designer` + `ui-designer` added to root `oneOf`; new per-role definitions extending `base`.

- **`INSTALL.md`** updated with new "Full pipeline — install referenced skills for design roles" section. Includes per-skill table + "When to actually install these" decision matrix (greenfield consumer / B2B / internal tool / iteration).

### Why dedicated design stages

The pipeline previously assumed UI specs would arrive from somewhere — `product-manager` produces requirements (the *what*), but neither requirements nor research produce IA/flows/wireframes/tokens (the *how*). Without dedicated design roles, `frontend-engineer` makes visual decisions at implementation time, which is the wrong cognitive context (focus on code correctness, not design coherence). Result: generic AI-aesthetic interfaces that look obviously LLM-generated.

For products where UX = differentiation moat (operator-first tools, prosumer apps, AI-native workflows, anything consumer-facing), this is the difference between shippable and shippable-by-a-top-company.

### Migration

Backwards compatible — no breaking changes to existing roles or pipelines. Existing `mvp` / `full` / `single-thread` / `audit` / `audit-dd` runs continue unchanged when design roles are not opted in. Opt into design stages by inserting `ux-designer` and/or `ui-designer` in the pipeline per the [pipelines/full.md](references/pipelines/full.md) "Design stages — when to include" decision matrix.

### Inline-only rationale

Both `ux-designer` and `ui-designer` run inline by default — their artifacts (IA / wireframes / tokens / reference prototype) are inherited by `frontend-engineer` as the foundation for implementation. Fragmenting them across subagent contexts risks design-token-to-implementation mismatches that produce visual inconsistency in the shipped UI. Dispatch only with explicit `--isolate` when running an audit-only design review with no implementation downstream.

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
