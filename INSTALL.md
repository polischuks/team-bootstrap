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

## Uninstall

```bash
rm -rf ~/.claude/plugins/team-bootstrap
rm -rf ~/.claude/skills/team-bootstrap
rm -rf .claude/skills/team-bootstrap
```

Project `AGENTS.md` and `evals/` directories remain.
