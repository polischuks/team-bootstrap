# Security Policy

team-bootstrap orchestrates AI agents that can read, write, and execute against
your repositories. Security is a first-class concern of the design, not an
afterthought — see [references/irreversibility.md](references/irreversibility.md)
and [references/guardrails.md](references/guardrails.md).

## Supported versions

The latest released version receives security fixes. Older versions do not.

## Reporting a vulnerability

**Do not open a public issue for security problems.**

Use GitHub's private vulnerability reporting:
**Security → Report a vulnerability** on this repository. This opens a private
advisory visible only to the maintainer.

Please include:

- The affected file(s), role, or pipeline.
- A description of the issue and its impact (e.g. a role's `tool_surface` allowing
  an irreversible action it shouldn't, a guardrail that can be bypassed, a prompt-
  injection path that escalates tool access).
- Steps to reproduce, and a suggested fix if you have one.

You can expect an initial response within a few days. Coordinated disclosure is
appreciated: please give a reasonable window to ship a fix before public discussion.

## Scope and threat model

Because the project ships **no runtime of its own** — execution happens inside the
user's Claude Code harness against the user's own credentials and repository — the
relevant security surface is:

- **Guardrail / irreversibility correctness** — a role permitted to take a
  destructive or irreversible action without the documented approval gate.
- **Tool-surface declarations** — a role frontmatter `tool_surface` that grants more
  than the role needs.
- **Prompt-injection resistance** — content in a target repo or data room that could
  subvert a role's instructions or escalate its tool access.
- **Data handling guidance** — incorrect advice about where customer/repo data flows
  (it reaches the foundation-model provider during inference).

Out of scope: vulnerabilities in Claude Code itself, the Anthropic API, or
third-party MCP servers — report those to their respective maintainers.
