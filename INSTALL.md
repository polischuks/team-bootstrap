# Installation

team-bootstrap is a Claude Code skill. Three install methods, in order of preference.

## Method 1: Claude Code plugin

If using Claude Code's plugin system, install the bundled plugin:

```bash
git clone https://github.com/polischuks/team-bootstrap ~/.claude/plugins/team-bootstrap
```

Plugin manifest: [.claude-plugin/plugin.json](.claude-plugin/plugin.json).

Verify in Claude Code:

```text
/team-bootstrap role product-ba "Stub: write a one-line requirement for a no-op endpoint"
```

If you see a structured handoff with `status: completed`, the install is correct.

## Method 2: User-level skill (no plugin system)

Copy the directory to your user skills:

```bash
git clone https://github.com/polischuks/team-bootstrap /tmp/team-bootstrap
mkdir -p ~/.claude/skills
cp -r /tmp/team-bootstrap ~/.claude/skills/team-bootstrap
```

The skill becomes available in any Claude Code session as `/team-bootstrap`.

## Method 3: Project-local skill

For a single repository:

```bash
git clone https://github.com/polischuks/team-bootstrap /tmp/team-bootstrap
mkdir -p .claude/skills
cp -r /tmp/team-bootstrap .claude/skills/team-bootstrap
```

The skill is then available only in that repository's Claude Code sessions.

## Project setup

For each project where you'll use team-bootstrap, add an `AGENTS.md` to the repository root.

1. Copy the template:
   ```bash
   cp ~/.claude/skills/team-bootstrap/examples/AGENTS.md.template ./AGENTS.md
   ```
2. Fill in build/test/style/security/scoping fields. See [references/agents-md-contract.md](references/agents-md-contract.md) for required fields and per-role consumption.

If your project already uses `CLAUDE.md`, team-bootstrap will read that as a fallback. The contract is the same.

## Optional: MCP servers

team-bootstrap roles can integrate with MCP servers for GitHub, Linear, Slack, etc. The skill itself does not bundle MCP servers — it only declares which servers each role uses in its frontmatter. Configure servers separately in Claude Code's MCP settings. See [references/mcp-integration.md](references/mcp-integration.md).

## Optional: Tracing backend

For production runs with replay and grading, configure an OpenTelemetry-compatible backend (Langfuse, Phoenix, Datadog, Honeycomb). The skill emits OTel GenAI semantic-convention spans; backend is your choice. See [references/tracing.md](references/tracing.md).

## Optional: Eval suite

For prompt-regression gating on role edits, scaffold the eval directory:

```bash
cp -r ~/.claude/skills/team-bootstrap/evals ./evals
```

See [evals/README.md](evals/README.md) for format.

## Optional: Audit-DD pipeline — install referenced skills

The `audit-dd` pipeline (commercial due diligence — pre-fundraise, M&A, board prep) is **functional without any extra skills** — every role declares fallbacks using `WebSearch` / `WebFetch`. But six skills materially improve output quality and reduce token cost. They are listed as `recommended` (not required) in [`skills-manifest.json`](skills-manifest.json).

### Verify what's already installed

```bash
bin/check-skills.sh audit-dd
```

Output legend:
- `✓ installed` — skill found in `~/.claude/skills/<name>/SKILL.md`
- `⚠ missing [recommended]` — pipeline still runs via fallback, but quality drops
- `○ missing [optional]` — only matters for specific input formats (.xlsx / .pdf / .docx)

### Install the recommended skills

team-bootstrap **does not auto-fetch** skills (different users source from different marketplaces, license variation, no canonical registry). Install each from your preferred source:

```bash
# 1. Via Claude Code's plugin manager (if your marketplace is registered):
/plugin marketplace add <marketplace-url>
/plugin install <skill-name>

# 2. Manual git clone (skills must end up at ~/.claude/skills/<name>/SKILL.md):
git clone https://github.com/<owner>/<repo> ~/.claude/skills/<skill-name>

# 3. Copy from another machine that has it:
scp -r other-machine:~/.claude/skills/<skill-name> ~/.claude/skills/
```

### Skill catalog for audit-dd

| Skill | Role(s) | Purpose | Fallback if missing |
|---|---|---|---|
| `tavily-research` | financial / market / ip / culture | Multi-source cited research — 2026 comps, patent landscape, Glassdoor / Levels.fyi, foundation-model TOS | `WebSearch` + `WebFetch` (more tokens, manual triangulation) |
| `competitor-analysis` | market | SWOT, positioning, differentiation | `WebSearch` + manual analysis |
| `30x-seo-ai-visibility` | market | Empirically measures brand visibility across ChatGPT / Claude / Perplexity / Gemini / Google AI Overview | `WebSearch` each LLM platform manually (very token-expensive) |
| `data-storyteller` | financial / customer-health / thesis | Narrative reports + charts + statistical summaries → executive output | Raw markdown tables |
| `research-synthesis` | customer-health / culture | Bucket interview transcripts, NPS, exit surveys into themes | Read + summarize manually |
| `web-scraper` | market / culture / ip | Structured extraction from competitor pricing, Glassdoor, OSS license pages | `WebFetch` + parse manually |
| `find-keywords` *(optional)* | market | Search-volume signal for segment | skip — most DD doesn't need it |
| `anthropic-skills:xlsx` *(optional)* | financial / customer-health | Parse .xlsx / .csv financial models, cohort tables | Convert to CSV first |
| `anthropic-skills:pdf` *(optional)* | financial / ip / thesis | Parse audited financials, contract PDFs; produce memo PDF | OCR + manual paste |
| `anthropic-skills:docx` *(optional)* | ip / thesis | Parse Word contracts; produce memo .docx | Convert to markdown |

The `anthropic-skills:*` namespace is Anthropic's bundled skill pack — available via Claude Code's built-in plugin sources.

### CI integration

```bash
# Exit codes:
#   0 = all recommended installed
#   1 = required missing (audit-dd has none today)
#   2 = recommended missing (pipeline runs with fallbacks)
bin/check-skills.sh audit-dd --json | jq '.recommended_missing'
```

## Optional: Full pipeline — install referenced skills for design roles

The `full` pipeline becomes meaningfully stronger when `ux-designer` and `ui-designer` are inserted between research/product and frontend implementation. Both roles **gracefully degrade** without their recommended skills (output drops in quality but role still runs), but the design system + reference prototype is materially weaker.

### Verify what's already installed

```bash
bin/check-skills.sh full
```

Same output legend as `audit-dd`.

### Skill catalog for ux-designer + ui-designer (full pipeline)

| Skill | Role(s) | Purpose | Fallback if missing |
|---|---|---|---|
| `frontend-ui-engineering` | ui-designer | Production-quality UI patterns, design-system adherence, anti-AI-aesthetic principles | Manual shadcn/ui + Tailwind reference (less coherent system) |
| `research-synthesis` | ux-designer | Synthesize raw user research into themes before flow design | Read transcripts directly, summarize manually |
| `idea-refine` | ux-designer / ui-designer | Divergent → convergent thinking for greenfield design space | Manual brainstorm + critique (more passes) |
| `competitor-analysis` | ux-designer / ui-designer | Specific UX/UI patterns from named reference products with rationale | WebFetch + manual extraction |
| `api-and-interface-design` *(optional)* | ui-designer | Component prop contracts — composition vs configuration, slot patterns | Reference shadcn/ui patterns; less rigorous |
| `image-generation` *(optional)* | ui-designer | Custom iconography / illustration reference before commissioning | Existing icon libraries (Phosphor, Lucide); commission separately |
| `documentation-and-adrs` *(optional)* | ui-designer | Design-system ADRs (token rationale, motion decisions) | Inline rationale in tokens file |
| `tavily-research` *(optional)* | ux-designer | Cited examples of established UX patterns for novel interactions | WebSearch + manual pattern collection |
| `persona-customer-support` *(optional)* | ux-designer | Persona + ticket triage flow patterns for operator interfaces | Manual persona modeling from product brief |

### When to actually install these

The full pipeline's design stages are **opt-in** (see [pipelines/full.md](references/pipelines/full.md) — "Design stages — when to include"). Skill install priority follows the same logic:

- **Greenfield consumer / prosumer product** — install all 4 recommended (`frontend-ui-engineering`, `research-synthesis`, `idea-refine`, `competitor-analysis`); strongly consider `image-generation` + `documentation-and-adrs`
- **B2B product where UX = core moat** — install all 4 recommended; `tavily-research` if novel interaction patterns
- **Internal admin tool / dashboard** — skip design stages entirely; no design skills needed
- **Iteration on existing design system** — install `frontend-ui-engineering` only (visual coherence with existing tokens)

### CI integration

```bash
bin/check-skills.sh full --json | jq '.recommended_missing'
```

## Optional: Full pipeline — install referenced skills for marketing roles

The `full` pipeline also gains `product-marketer` (GTM, positioning, launches, sales enablement) and `growth-marketer` (channels, content, brand-as-moat, AI search posture) as opt-in stages — added in v1.4.0. Both roles **gracefully degrade** without their skills (output drops in quality but role still runs); the strategy artifacts and content engine are materially weaker without the SEO/AEO toolchain.

### Skill catalog for product-marketer + growth-marketer (full pipeline)

| Skill | Role(s) | Purpose | Fallback if missing |
|---|---|---|---|
| `competitor-analysis` | product-marketer / growth-marketer | SWOT + positioning differentials + channel benchmarks | Manual WebSearch + analysis (more tokens) |
| `copywriter` | product-marketer / growth-marketer | Compelling marketing/product copy — landing pages, ads, email, launch announcements | Manual copywriting (acceptable, less converting) |
| `brief` | product-marketer / growth-marketer | Editor-ready content brief with SEO + AEO structure | Manual brief composition |
| `30x-seo-ai-visibility` | growth-marketer | Empirical AI visibility measurement across ChatGPT/Claude/Perplexity/Gemini/Google AI Overview — **highest leverage for growth-marketer in 2026** | WebSearch each LLM platform manually (very token-expensive) |
| `ai-seo` | growth-marketer | AEO / GEO content strategy + LLM citation optimization patterns | Manual research (rapidly evolving knowledge) |
| `seo-aeo-best-practices` | growth-marketer | Schema, structured data, JSON-LD, answer-first content blocks | Manual research per pattern |
| `seo-audit` | growth-marketer | Technical SEO baseline audit + issue prioritization | Manual technical SEO audit |
| `seo-geo` | growth-marketer | Generative Engine Optimization across regions + engines | Run classical SEO + AEO separately |
| `find-keywords` | growth-marketer | Prioritized keyword list with demand + intent mapping | Manual keyword brainstorm |
| `programmatic-seo` | growth-marketer | Template-driven page generation for 100s/1000s of pages | Manual page-by-page creation (doesn't scale) |
| `backlink-analyzer` | growth-marketer | Authority gap analysis vs competitors | Manual backlink audit |
| `social-media-posts` | growth-marketer | Platform-specific content (LinkedIn / Twitter / Reddit / Facebook / Instagram) | Manual platform-by-platform |
| `data-storyteller` | growth-marketer | Growth metrics narrative (charts + cohort analysis) | Raw markdown tables |
| `tavily-research` *(see audit-dd table)* | product-marketer | Cited multi-source research on pricing comps + competitive moves | WebSearch + manual triangulation |
| `idea-refine` *(see design table)* | product-marketer | Divergent → convergent positioning narrowing | Manual brainstorm + critique |
| `persona-customer-support` *(see design table)* | product-marketer | ICP modeling from real support patterns | Manual persona modeling |

### When to actually install these

The full pipeline's marketing stages are **opt-in** (see [pipelines/full.md](references/pipelines/full.md) — "Marketing stages — when to include"). Skill install priority by product type:

- **Greenfield product launch with reach goals** — install entire growth-marketer SEO/AEO toolchain (`30x-seo-ai-visibility`, `ai-seo`, `seo-aeo-best-practices`, `find-keywords`, `competitor-analysis`) + product-marketer core (`competitor-analysis`, `copywriter`, `brief`)
- **Pricing change or repositioning** — install product-marketer core only (`competitor-analysis`, `tavily-research`, `idea-refine`, `copywriter`)
- **Growth plateau / AEO posture work** — install growth-marketer toolchain (`30x-seo-ai-visibility`, `ai-seo`, `seo-audit`, `backlink-analyzer`, `data-storyteller`)
- **Content scaling project** — add `programmatic-seo` + `brief` + `find-keywords`
- **Internal tool / private beta / dev-only feature** — skip both marketing roles; no skills needed
- **Patch / bug fix release** — skip both; use `stakeholder-communicator` for release notes only

### CI integration

```bash
bin/check-skills.sh full --json | jq '.recommended_missing, .optional_missing'
```

`full` now references 4 recommended + 18 optional skills total (design + marketing). Pipeline is functional with just the 4 recommended; quality compounds as optional skills land.

## Required: Full pipeline — install skills for v1.5 post-release roles

**v1.5 adds three new post-release roles** with **skill-blocking constraints** unlike any prior role: `customer-success-manager`, `partnerships-lead`, `community-manager`. The pipeline returns `status: blocked` if any blocking skill is missing — these roles cannot fall back to AI-detectable output because that destroys trust permanently in customer / partner / community contexts.

### Blocking skills (pipeline halts if missing)

| Skill | Required by role(s) | Why blocking | Install priority |
|---|---|---|---|
| `humanize` | partnerships-lead (outreach + co-launch comms), community-manager (every published post + moderation response) | AI-detected content in partner / community contexts has < 1% reply rate; communities reject AI-flagged posts within hours | **P0 — install first** |
| `humanize-ai-text` | customer-success-manager (renewal / expansion / at-risk sequences), community-manager (ambassador program copy) | Customer comms detected as AI-generated erode trust; ambassadors ghost transactional-feeling programs | **P0 — install first** |
| `persona-customer-support` | customer-success-manager (health framework + onboarding escalation triage) | Manual customer-management framework fails QA on triage rigor | **P0 — install first** |
| `research-synthesis` | customer-success-manager (VoC theme extraction) | Unstructured summary fails QA on theme density + segment correlation | **P0 — install first** |
| `idea-refine` | partnerships-lead (partnership thesis convergence) | Unstructured prioritization fails QA on convergence rigor; thesis without audit-trail = wishful thinking | **P0 — install first** |

These 5 skills are **required** in the v1.5 manifest (not just recommended). `bin/check-skills.sh full` will exit 1 if any is missing.

### Recommended skills (graceful fallback, but quality drops)

Reusing skills from v1.3 + v1.4 manifests (no new install needed if already present):

| Skill | Used by v1.5 roles | Fallback if missing |
|---|---|---|
| `tavily-research` | CSM (QBR industry context), partnerships-lead (partner landscape), community-manager (channel inventory) | WebFetch + manual research (10× token cost) |
| `competitor-analysis` | CSM (at-risk competitive threats), partnerships-lead (partner overlap), community-manager (community gap analysis) | Manual SWOT (less systematic) |
| `data-storyteller` | CSM (health dashboard), partnerships-lead (performance dashboard), community-manager (health dashboard) | Markdown tables (loses narrative + escalation framing) |
| `copywriter` | CSM (comm templates), partnerships-lead (outreach), community-manager (ambassador recruitment) | Manual copywriting (less converting) |
| `brief` | partnerships-lead (per-partner brief), community-manager (ambassador handbook) | Manual brief composition (less structured) |
| `social-media-posts` | partnerships-lead (co-launch), community-manager (daily engagement) | Manual platform-by-platform (slower, less converting) |
| `image-generation` | community-manager (ambassador badges + event banners + visuals) | Source from existing libraries; commission separately |
| `api-and-interface-design` | partnerships-lead (integration partner vetting — conditional) | Manual technical review (less rigorous) |
| `backlink-analyzer` | partnerships-lead (content/SEO partner scoring — conditional) | Manual third-party tool review (more friction) |

### Verify v1.5 skill availability

```bash
bin/check-skills.sh full
```

Output legend (v1.5 introduces `[required]` tier):
- `✓ [required]` — pipeline-blocking skill installed
- `✗ [required]` missing — pipeline halts on first role invocation needing this skill
- `✓ [recommended]` — quality skill installed
- `⚠ [recommended]` missing — pipeline runs via fallback with quality drop
- `✓ [optional]` — nice-to-have installed
- `○ [optional]` missing — fallback acceptable for specific use cases

### Install all v1.5 required skills (P0)

Standard install paths (skills land at `~/.claude/skills/<name>/SKILL.md`):

```bash
# Via Claude Code's plugin manager (if your marketplace is registered):
/plugin install humanize
/plugin install humanize-ai-text
/plugin install persona-customer-support
/plugin install research-synthesis
/plugin install idea-refine

# Or via manual git clone:
git clone https://github.com/<owner>/<repo> ~/.claude/skills/humanize
# ... etc per skill

# Or copy from another machine that has them:
scp -r other-machine:~/.claude/skills/{humanize,humanize-ai-text,persona-customer-support,research-synthesis,idea-refine} ~/.claude/skills/
```

After install, verify all 5 are blocking-tier resolved:

```bash
bin/check-skills.sh full --json | jq '.skills[] | select(.tier == "required") | .status'
# Expected: all "installed"
```

### When to skip v1.5 roles entirely (skip install of v1.5 blocking skills)

If you never run any of the three v1.5 post-release roles, you don't need their blocking skills. Match your install scope to your usage:

| Product context | CSM? | Partnerships? | Community? | Required v1.5 skills |
|---|:-:|:-:|:-:|---|
| SaaS / subscription with retention focus | ✓ | optional | optional | persona-customer-support, research-synthesis, humanize-ai-text |
| Developer tools / platform (community-driven) | optional | ✓ | ✓ | humanize, humanize-ai-text, idea-refine |
| B2B with ecosystem-first GTM | optional | ✓ | optional | humanize, idea-refine |
| Consumer product (broad community appeal) | optional | optional | ✓ | humanize, humanize-ai-text |
| Internal tool / private beta | — | — | — | none — skip all v1.5 |
| Patch / bug fix release | — | — | — | none — skip all v1.5 |

### CI integration (v1.5)

```bash
# Strict: fail CI if required skills missing
bin/check-skills.sh full --json | jq -e '.required_missing == 0'

# Soft: warn but proceed
bin/check-skills.sh full --json | jq '{required_missing, recommended_missing}'
```

`full` pipeline in v1.5: **5 required + 9 recommended + 18 optional skills**. Reference setup at this repo's maintainer environment has all 32 skills installed locally.

## Uninstall

```bash
rm -rf ~/.claude/plugins/team-bootstrap
rm -rf ~/.claude/skills/team-bootstrap
rm -rf .claude/skills/team-bootstrap
```

Project `AGENTS.md` and `evals/` directories remain.
