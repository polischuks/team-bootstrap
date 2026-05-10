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

## Uninstall

```bash
rm -rf ~/.claude/plugins/team-bootstrap
rm -rf ~/.claude/skills/team-bootstrap
rm -rf .claude/skills/team-bootstrap
```

Project `AGENTS.md` and `evals/` directories remain.
