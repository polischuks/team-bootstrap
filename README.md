# team-bootstrap

A role-based AI delivery framework for Claude Code. Run a software-engineering task through Product, Architecture, Implementation, Review, and Release roles — with structured handoffs, validation, and observability.

**Status:** v2.1.0. Ready for use; see [USAGE.md](USAGE.md) for invocation patterns.

## When to use

- You want a multi-step delivery workflow (research → implement → verify → release) inside Claude Code, not just single-shot prompting.
- You need an explicit audit trail: who decided what, what was tested, what was approved.
- You're running on tasks long enough that context fragmentation matters.

## When NOT to use

- One-line bug fixes — single-thread agentic mode handles these without orchestration.
- Highly interactive UI work where the human is the loop.
- Tasks where the role boundaries don't match your actual workflow.

## Quick start

After [installing](INSTALL.md) and adding an `AGENTS.md` to your project root ([template](examples/AGENTS.md.template)):

```text
/team-bootstrap single-thread "Add OAuth login to /api/auth"
```

For multi-role with audit trail:

```text
/team-bootstrap mvp "Add OAuth login to /api/auth"
/team-bootstrap full "Migrate user table to UUID primary keys"
```

For a single targeted role:

```text
/team-bootstrap role security-reviewer "Audit the OAuth changes"
```

For a read-only audit that produces an implementation backlog (technical, or landing↔platform↔docs conversion gaps):

```text
/team-bootstrap audit "Production-readiness review of the billing module"
/team-bootstrap l2p "landing: https://… · platform: <routes/screens> · docs: ./docs"
```

For a full spec-driven milestone — one command runs the pre-implementation flow (spec → plan → tasks), then drives implementation batches step-by-step through `mvp`/`full`:

```text
/deliver full "Add OAuth login to /api/auth"
```

## Architecture in three sentences

team-bootstrap is **single-thread by default**: roles are output styles activated for distinct phases of one Claude session, sharing a run document as blackboard. **Subagents are dispatched only for context isolation** (research, security audit, parallel reviews) — never for delegation of decisions. The multi-role pipelines (`mvp`, `full`) remain available for tasks that require formal phase gates and audit evidence.

This design follows Cognition's "Don't Build Multi-Agents" principle: shared context broadly, subagents narrowly. See [ARCHITECTURE.md](ARCHITECTURE.md) for full rationale.

## Documentation

| Document | Purpose |
|---|---|
| [INSTALL.md](INSTALL.md) | Installation methods |
| [USAGE.md](USAGE.md) | How to invoke pipelines and roles |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Design rationale and trade-offs |
| [CHANGELOG.md](CHANGELOG.md) | Version history |
| [SKILL.md](SKILL.md) | Claude Code skill entry point |
| [references/speckit-preimpl-flow.md](references/speckit-preimpl-flow.md) | Pre-implementation flow — the recommended **first step**: spec → plan → tasks → dispatch before pipelines run |
| [constitution.md](constitution.md) | Versioned architectural invariants (P1–P8) every milestone must respect |
| [specs/](specs/) | One directory per milestone (spec → plan → tasks); [`TEMPLATE/`](specs/TEMPLATE/) to start one |
| [docs/adr/](docs/adr/) | Architecture Decision Records |
| [references/](references/) | Orchestration, pipelines, schemas, role playbooks |

## Project requirements

team-bootstrap reads `AGENTS.md` (or `CLAUDE.md`) from your repository root. Required fields and a template: [references/agents-md-contract.md](references/agents-md-contract.md).

## License

MIT
