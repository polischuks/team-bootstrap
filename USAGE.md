# Usage

team-bootstrap can be invoked four ways: single-thread, multi-role pipeline, single role, or resume/replay.

## Single-thread (recommended default)

For most engineering tasks. One Claude session, three logical phases (plan → implement → verify), no role-by-role context fragmentation:

```text
/team-bootstrap single-thread <task-description>
```

This is the closest match to current SOTA autonomous coding agents and what Cognition's "Don't Build Multi-Agents" recommends. See [references/pipelines/single-thread.md](references/pipelines/single-thread.md).

## Multi-role pipeline

For tasks where you need explicit role-by-role audit trail (compliance, production releases, regulated work):

```text
/team-bootstrap mvp <task-description>
/team-bootstrap full <task-description>
```

| Pipeline | Roles | When |
|---|---|---|
| `mvp` | 7 (product-ba → delivery-manager → cto-architect → backend → frontend → qa → release-docs) | Internal, low-risk, quick iterations |
| `full` | 20 (adds discovery, formal product/business/test design, specialized reviewers, release manager, stakeholder communication, documentation) | Production releases, customer-facing, compliance-sensitive |

Pipeline definitions: [references/pipelines/](references/pipelines/).

## Single role

For targeted use when only one phase is needed:

```text
/team-bootstrap role <role-name> <task-description>
```

Examples:

```text
/team-bootstrap role security-reviewer "Audit the OAuth implementation in src/auth/"
/team-bootstrap role overengineering-reviewer "Audit complexity of src/orchestrator/"
/team-bootstrap role test-designer "Design tests for the new caching layer"
```

Available roles: [references/role-matrix.md](references/role-matrix.md).

## Stop early

Add `stop after <role>` to halt the pipeline:

```text
/team-bootstrap mvp "Add /health endpoint" stop after qa-test-engineer
```

## Resume from checkpoint

Each role's handoff is a checkpoint. To resume an interrupted run:

```text
/team-bootstrap resume <run-id>
```

The orchestrator loads the run document, finds the last `completed` handoff, and continues from the next role. See [references/memory.md](references/memory.md).

## Replay from trace

For grading or debugging:

```text
/team-bootstrap replay <run-id> [--role <role-name>]
```

Re-executes the pipeline (or a single role) with the same inputs. Useful for prompt-regression evals. See [references/tracing.md](references/tracing.md).

## What gets produced

Every run produces a single markdown run document with:

- Run metadata (pipeline, spec, repo, timestamp, run ID)
- Per-role section: role output + YAML handoff
- Final verdict (release decision or blocker list)

The run document is the canonical record and the input to grading evals.

## Project preconditions

Before invoking team-bootstrap on a project:

1. **`AGENTS.md` exists** at repo root with required fields. See [references/agents-md-contract.md](references/agents-md-contract.md). If missing required fields, the orchestrator returns `needs_input` listing them.
2. **Test commands work locally.** team-bootstrap runs them; if `npm run test` doesn't exist, QA gates can't pass.
3. **Tools are scoped.** team-bootstrap respects Claude Code permissions; configure project `.claude/settings.json` to allow what roles need. See [references/mcp-integration.md](references/mcp-integration.md) and [references/irreversibility.md](references/irreversibility.md).

## Examples

- [examples/quickstart-spec.md](examples/quickstart-spec.md) — annotated example task
- [references/invocation-examples.md](references/invocation-examples.md) — copy-paste invocation snippets

## Where things live

| Concept | File |
|---|---|
| Skill entry | [SKILL.md](SKILL.md) |
| Orchestration logic | [references/orchestrator.md](references/orchestrator.md) |
| Failure & retry policy | [references/failure-policy.md](references/failure-policy.md) |
| Role playbooks | [references/roles/](references/roles/) |
| Pipelines | [references/pipelines/](references/pipelines/) |
| Handoff schema | [references/schemas/role-output.schema.json](references/schemas/role-output.schema.json) |
| Role frontmatter schema | [references/schemas/role-frontmatter.schema.json](references/schemas/role-frontmatter.schema.json) |
