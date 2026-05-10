# MCP Integration

team-bootstrap roles can use MCP servers (GitHub, Linear, Slack, custom) by declaring them in `tool_surface.mcp` in role frontmatter. The skill itself **does not bundle** MCP servers — it consumes whatever the harness (Claude Code) makes available.

## Declaration

In role frontmatter:

```yaml
tool_surface:
  allow: [Read, Grep, Glob]
  deny: []
  mcp: [github, linear]
```

The values are MCP **server names** as registered in Claude Code's MCP configuration. Claude Code exposes that server's tools as `mcp__<server>__<tool>` (e.g., `mcp__github__create_issue`). The role's `tool_surface.allow` implicitly includes all tools from listed MCP servers; explicit allowlists per MCP tool are also supported:

```yaml
tool_surface:
  allow: [Read, Grep, mcp__github__create_issue, mcp__github__list_issues]
  deny: [mcp__github__delete_repository]
  mcp: [github]
```

When in doubt, list the server in `mcp:` and rely on harness-level permission prompts for individual destructive tools.

## Per-role typical MCP usage

| Role | Typical MCP servers |
|---|---|
| `discovery-research` | `web` (if a web-research MCP exists), `linear`, `notion` |
| `product-manager`, `business-analyst` | `linear`, `notion`, `confluence` |
| `delivery-manager` | `linear`, `github` (for issue/PR linkage) |
| `backend-engineer`, `frontend-engineer` | None typical (file ops + Bash) |
| `devops-platform` | `github` (for Actions), `pagerduty` |
| `release-manager`, `release-docs` | `github` (PR/release management) |
| `stakeholder-communicator` | `slack`, `email` |
| `documentation-agent` | `notion`, `confluence` |
| `incident-responder` | `pagerduty`, `slack`, `github` |

These are defaults; project-specific overrides come from per-project role customization.

## Capability discovery

At run start, the orchestrator queries each declared MCP server's `list_tools` capability. If a role declares `mcp: [linear]` but the `linear` server is not configured in Claude Code:

- **Strict mode** (default): orchestrator emits `needs_input` with `stop_reason: missing_user_input` and lists the missing server. The user configures it and re-runs.
- **Lenient mode** (`--mcp-optional`): orchestrator records the missing server in the run document and lets the role decide whether to handoff `blocked` or proceed without it.

## Authentication

team-bootstrap **does not handle MCP authentication.** All auth (OAuth tokens, API keys) is configured via Claude Code's MCP setup. The skill assumes that if a server is "available" in the harness, the harness has resolved auth.

If the user's MCP setup expires or fails mid-run, the role's tool call fails with the harness's error; the role surfaces this as a blocker.

## Irreversibility class for MCP tools

MCP tools should declare `x-irreversibility-class` in their tool metadata (an MCP spec extension that has been gaining adoption through 2025). team-bootstrap reads this and applies the gate per [irreversibility.md](irreversibility.md).

If the metadata is absent, defaults are:

| MCP tool name pattern | Default class |
|---|---|
| `*read*`, `*get*`, `*list*`, `*search*`, `*query*` | `read_only` |
| `*create*`, `*add*`, `*post*`, `*comment*`, `*update*` | `stateful_remote` |
| `*delete*`, `*remove*`, `*destroy*`, `*purge*` | `irreversible` |
| anything else | `stateful_remote` |

Project-level overrides go in `AGENTS.md` under `## Destructive Scripts` (extended to cover MCP tools).

## Custom MCP servers for project-specific tools

If your project has internal CLIs, deployment scripts, or data pipelines that team-bootstrap should drive, the right pattern is to expose them as a project-local MCP server. Don't bake project-specific tool calls into role playbooks — keep roles portable.

Example: if your team uses `bin/deploy <env>`, expose it as a `deploy` MCP server with tools `deploy_staging`, `deploy_canary`, `deploy_prod`, each with appropriate irreversibility classes. Then `devops-platform` declares `mcp: [deploy]`.

## Trace integration

Every MCP tool call emits a tool span ([tracing.md](tracing.md)) with:

- `gen_ai.tool.name = "mcp__<server>__<tool>"`
- `mcp.server = "<server>"`
- `mcp.tool = "<tool>"`
- `irreversibility.class` (resolved at call time)

Useful for "which Slack messages did this run send?" replay queries.

## Anti-patterns

- **Hardcoding tool calls in role markdown.** Role playbooks should describe what to do, not which exact tool name to call. The tool surface lives in frontmatter; the body uses general language ("create a tracking issue").
- **Adding all MCP servers to every role.** Tool-surface bloat = bigger attack surface and noisier permission prompts. Declare only what the role actually needs.
- **Treating MCP server availability as guaranteed.** It's user-configured; assume it can be missing. Roles should handle "tool not available" gracefully (handoff with `needs_input` listing the missing capability).
- **Storing secrets in MCP server names or config that lives in the repo.** MCP auth is a harness-level concern; project repo should reference the server by name, not embed credentials.

## See also

- [irreversibility.md](irreversibility.md) — class assignment for MCP tools
- [agents-md-contract.md](agents-md-contract.md) — `## Destructive Scripts` extension for project-specific MCP overrides
- [tracing.md](tracing.md) — MCP span attributes
- Claude Code's MCP documentation for harness-side server configuration
