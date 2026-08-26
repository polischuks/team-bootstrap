# team-bootstrap

A role-based AI delivery framework for Claude Code. Run a software-engineering task through Product, Architecture, Implementation, Review, and Release roles — with structured handoffs, validation, and observability.

**Status:** ready for use; see [USAGE.md](USAGE.md) for invocation patterns. Current version: [VERSION](VERSION) · [CHANGELOG.md](CHANGELOG.md).

## What this is, precisely

Spec-driven development tools take an idea to code. GitHub Spec Kit is the closest analogue and is
explicit about where it stops: it produces the artefacts and **does not verify that the implementation
satisfies the specification**.

team-bootstrap is that missing half — a **proof-of-delivery layer over SDD**, not another SDD tool. Its
subject is closure-time verification: which roles a change earned, whether they actually ran as
independent minds, and whether a batch may be called done. It runs the pre-implementation flow through
Spec Kit's own commands rather than replacing them.

It is also **not a harness**. Claude Code is the harness; this is a policy layer on top of one, which
is why every lever it needs is requested through the host's hook API rather than asked for in prose.

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

For a spec-driven milestone — one command runs the pre-implementation flow (spec → plan → tasks), then drives implementation batches step-by-step:

```text
/deliver "Add OAuth login to /api/auth"          # no spec yet — Phase A produces it
/deliver specs/042-oauth-login/spec.md            # the milestone already exists
```

**Do not pass a tier unless you mean to override the harness.** With no `mvp`/`full` token the harness
sizes the run itself: when the milestone is on disk it reads `tasks.md`/`plan.md` before the first
dispatch and derives a per-work-stream role plan, so a documentation stream and an auth stream get
different role sets inside one milestone. `/deliver mvp …` and `/deliver full …` still pin the tier —
the operator decides, but now by saying so rather than by default. See
[ADR-0018](docs/adr/0018-spec-sourced-role-plan.md).

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
