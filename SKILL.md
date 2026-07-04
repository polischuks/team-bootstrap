---
name: team-bootstrap
description: Run a role-based AI delivery workflow inside Claude Code using bundled role playbooks, handoff rules, and orchestration patterns. Use when Claude should act as Product Manager, Business Analyst, Delivery Manager, Architect, Backend Engineer, Frontend Engineer, QA, Release, or other delivery role; when you want Claude to execute a full multi-role pipeline from a project spec.
---

# team-bootstrap

Skill entry point. The product overview, install steps, usage, and architecture rationale live in dedicated top-level docs:

| For | Read |
|---|---|
| Product overview & quick start | [README.md](README.md) |
| Installation methods | [INSTALL.md](INSTALL.md) |
| How to invoke pipelines and roles | [USAGE.md](USAGE.md) |
| Design rationale (Cognition, single-thread, etc.) | [ARCHITECTURE.md](ARCHITECTURE.md) |
| Version history | [CHANGELOG.md](CHANGELOG.md) |

## When this skill is invoked

team-bootstrap activates when the user types `/team-bootstrap <args>` or asks Claude to run a multi-role engineering workflow. Three invocation patterns:

```text
/team-bootstrap single-thread <task>    # recommended default for implementation
/team-bootstrap mvp <task>               # 7-role implementation pipeline
/team-bootstrap full <task>              # 20-role implementation pipeline
/team-bootstrap audit <spec>             # 15-role read-only assessment, outputs prioritized backlog
/team-bootstrap l2p <spec>               # 6-role landing↔platform↔docs gap audit, outputs backlog
/team-bootstrap role <name> <task>       # single role
/team-bootstrap resume <run_id>          # resume from checkpoint
/team-bootstrap replay <run_id>          # re-run from trace
```

The `audit` and `l2p` pipelines are read-only: they assess against a reference and output a prioritized backlog. `audit` = technical/operational readiness; `l2p` = landing↔platform↔docs gaps (conversion). Each backlog item then becomes a separate `single-thread` / `mvp` / `full` run (or feed the whole backlog to `/deliver`).

See [USAGE.md](USAGE.md) for full semantics.

## Execution model

1. Read [references/orchestrator.md](references/orchestrator.md) — drives the run loop.
2. Pick the active pipeline at [references/pipelines/](references/pipelines/):
   - [single-thread.md](references/pipelines/single-thread.md) — default for implementation
   - [mvp.md](references/pipelines/mvp.md) — 7 roles
   - [full.md](references/pipelines/full.md) — 20 roles
   - [audit.md](references/pipelines/audit.md) — 15 roles, read-only assessment → backlog
   - [l2p.md](references/pipelines/l2p.md) — 6 roles, read-only landing↔platform↔docs gap audit → backlog
3. For each role, load its playbook from [references/roles/](references/roles/), enforce the declared `tool_surface` and `permission_mode`, run inline or as subagent per [references/subagent-dispatch.md](references/subagent-dispatch.md). When dispatching, resolve the concrete `subagent_type` from the role's `preferred_subagent_types` frontmatter per [references/subagent-mapping.md](references/subagent-mapping.md) (fallback: `general-purpose`).
4. After each role, validate the handoff against [references/schemas/role-output.schema.json](references/schemas/role-output.schema.json) and append to the run document ([references/shared-blackboard.md](references/shared-blackboard.md)).
5. For evaluated roles, run the independent evaluator gate ([references/evaluator.md](references/evaluator.md)) as a context-reset subagent before accepting the handoff.
6. Apply [references/failure-policy.md](references/failure-policy.md) on validation/blocked/needs_input.
7. Apply [references/irreversibility.md](references/irreversibility.md) to gate destructive actions.
8. Apply [references/guardrails.md](references/guardrails.md) — input guardrail before fan-out (Step 0.5), output guardrail before writes, circuit breaker per role.
9. Emit OpenTelemetry GenAI spans per [references/tracing.md](references/tracing.md).

## Handoff contract (base)

```yaml
status: completed | blocked | needs_input
role: current-role
summary: short summary of what was done
artifacts:
  - kind: <artifact-type>
    path: <file-path>
    description: <what it is>
checks:
  - name: <check-name>
    status: passed | failed | skipped
    details: <details>
next_role: role-name-or-null
risks_or_blockers: [concrete blocker or empty list]
manual_approval_requested: false
stop_reason: null
rollback_recommended: false
rollback_scope: null
```

Roles add required per-role fields (e.g. `release_decision: go|no_go` for `release-manager`, `severity_counts: {critical, high, medium, low}` for the four reviewer roles). Authoritative contract: [references/schemas/role-output.schema.json](references/schemas/role-output.schema.json) (`oneOf` on `role`, `unevaluatedProperties: false`). Each role's playbook shows its exact shape.

## Project preconditions

- `AGENTS.md` (or `CLAUDE.md`) at repo root with the required fields per [references/agents-md-contract.md](references/agents-md-contract.md). Missing required fields → run returns `needs_input` and stops.
- Test commands declared in `AGENTS.md > ## Test` actually work locally; QA roles run them.
- Project `.claude/settings.json` permissions allow what roles need; see [references/irreversibility.md](references/irreversibility.md) and [references/mcp-integration.md](references/mcp-integration.md).

## Reference index

Planning (run first):

- [speckit-preimpl-flow.md](references/speckit-preimpl-flow.md) — the recommended first step: a 6-step spec → plan → tasks → dispatch flow that produces the artifacts the pipelines consume (implemented by the bundled `speckit-*` skills)

Operational:

- [orchestrator.md](references/orchestrator.md) — execution loop
- [shared-blackboard.md](references/shared-blackboard.md) — context propagation
- [subagent-dispatch.md](references/subagent-dispatch.md) — when to spawn a subagent
- [subagent-mapping.md](references/subagent-mapping.md) — role → specialist `subagent_type` routing table (v1.1)
- [failure-policy.md](references/failure-policy.md) — retries, stop reasons, approvals
- [irreversibility.md](references/irreversibility.md) — action class taxonomy

Persistent state & I/O:

- [agents-md-contract.md](references/agents-md-contract.md) — project memory
- [memory.md](references/memory.md) — three-tier memory model
- [mcp-integration.md](references/mcp-integration.md) — MCP servers per role
- [tracing.md](references/tracing.md) — OpenTelemetry capture
- [trace-evals.md](references/trace-evals.md) — grader catalog and rubric
- [versioning.md](references/versioning.md) — role semver and eval-gate

Catalogs:

- [role-matrix.md](references/role-matrix.md) — all 48 roles, when to use which
- [invocation-examples.md](references/invocation-examples.md) — copy-paste prompts
- [roles/](references/roles/) — per-role playbooks
- [pipelines/](references/pipelines/) — pipeline definitions
- [schemas/role-output.schema.json](references/schemas/role-output.schema.json) — handoff schema
- [schemas/role-frontmatter.schema.json](references/schemas/role-frontmatter.schema.json) — role frontmatter schema

## Guardrails

- Single-thread is the default; multi-role is opt-in for audit-required tasks.
- Shared-blackboard is mandatory: every role reads the full prior run document, not just the immediate handoff.
- Subagents only for context isolation, never to delegate decisions ([subagent-dispatch.md](references/subagent-dispatch.md)).
- Tool surface and irreversibility class are harness-enforced; the LLM never decides whether an action is safe.
- Do not claim `status: completed` if validation/checks failed; emit `blocked` with concrete failures in `risks_or_blockers`.
- No `git push --force`, no prod deploy, no destructive Bash without explicit per-call approval ([irreversibility.md](references/irreversibility.md)).
