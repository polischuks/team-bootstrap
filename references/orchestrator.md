# Orchestrator Playbook

Use this playbook when Claude should drive the team workflow from the first role to the last role (multi-role pipelines) or phase to phase (single-thread).

## Goal

Run a pipeline entirely inside Claude by:

1. loading the active pipeline definition and AGENTS.md
2. initializing the shared blackboard (run document)
3. for each role: load playbook, decide inline vs subagent, execute, validate handoff, append to blackboard
4. apply failure-policy on validation/blocked/needs_input
5. emit OpenTelemetry spans throughout
6. continue until pipeline completes or blocks

## Inputs

- Project spec or task brief
- Repository `AGENTS.md` (or `CLAUDE.md`) — required-field check per [agents-md-contract.md](agents-md-contract.md); missing fields → `needs_input` and stop
- Selected pipeline: `single-thread` (default) | `mvp` | `full` | `incident` (for incident response)
- Optional explicit stop point ("run until QA")
- Optional resume token (run_id from a prior run; see [memory.md](memory.md))

## Execution Loop

### Step 0 — Initialize

- Generate `run_id` (UUID).
- Read AGENTS.md and validate required fields ([agents-md-contract.md](agents-md-contract.md)). On missing → `needs_input`, stop.
- Discover available MCP servers ([mcp-integration.md](mcp-integration.md)). On missing strict-required server → `needs_input`, stop.
- Resolve the **stack vector** from `AGENTS.md > ## Stack` (or infer from manifests when missing); cache it in run metadata so all later subagent dispatches see the same stack ([subagent-mapping.md](subagent-mapping.md#stack-detection-rule)).
- Initialize shared blackboard (run document) with metadata, spec, stack vector, AGENTS.md hash ([shared-blackboard.md](shared-blackboard.md)).
- Open the run-level OpenTelemetry span ([tracing.md](tracing.md)).

### Step 1 — Pick the pipeline

Read the active pipeline:

- [pipelines/single-thread.md](pipelines/single-thread.md) — default
- [pipelines/mvp.md](pipelines/mvp.md) — 7 roles
- [pipelines/full.md](pipelines/full.md) — 20 roles

For multi-role pipelines, pipeline = ordered role list. For single-thread, pipeline = three logical phases (plan → implement → verify).

### Step 2 — Load the next role

Read `references/roles/<role>.md`. Validate the frontmatter against [schemas/role-frontmatter.schema.json](schemas/role-frontmatter.schema.json). Verify `compatible_pipelines` includes the active pipeline; if not, refuse to run and emit `stop_reason: unexpected_next_role`.

### Step 3 — Decide inline vs subagent (and resolve subagent_type)

Per [subagent-dispatch.md](subagent-dispatch.md):

- Default: **inline** — activate the role's instructions and proceed in the main thread.
- Dispatch as subagent (Task tool) only for context-isolation triggers: research-heavy roles, parallel reviewers, deep audits.

When the dispatch decision is "subagent", resolve the concrete `subagent_type` from the role's `preferred_subagent_types` frontmatter per [subagent-mapping.md](subagent-mapping.md):

1. Read `preferred_subagent_types: [...]` from the role file.
2. Apply stack overrides (resolved once in Step 0 from `AGENTS.md > ## Stack`).
3. Walk left-to-right, pick the first slug the host can resolve.
4. Fallback: `general-purpose`.
5. Record the resolved slug as `team_bootstrap.subagent_type` on the role span.

### Step 4 — Execute the role

The role:

- Reads the **full prior blackboard** ([shared-blackboard.md](shared-blackboard.md)) — not just the prior handoff.
- Operates within `tool_surface` and `permission_mode` declared in frontmatter.
- Destructive actions gated by [irreversibility.md](irreversibility.md) — harness, not LLM, enforces.
- For implementation roles, runs the verification loop (edit → typecheck → lint → unit tests → repair, max 3 cycles).
- Produces:
  - Role output (per the role's template body)
  - YAML handoff (per [schemas/role-output.schema.json](schemas/role-output.schema.json))

### Step 5 — Validate handoff

- Validate against the schema (oneOf discriminator on `role`, `unevaluatedProperties: false`).
- Resolve `next_role: <determined-by-pipeline>` from the active pipeline. Never leave the placeholder in the emitted handoff.
- Validation failure → bounded retry per [failure-policy.md](failure-policy.md). On exhausted budget → `stop_reason: schema_validation_failed`.

### Step 6 — Append to blackboard, emit span, decide next

- Append the role section + handoff to the run document.
- Close the role-level OpenTelemetry span.
- If status is:
  - `completed`: continue to the resolved `next_role` (or `next_phase` for single-thread).
  - `blocked`: stop, surface blockers from `risks_or_blockers`.
  - `needs_input`: stop, ask only for the missing input.

### Step 7 — Compaction (when needed)

If the blackboard exceeds ~50% of context window before activating the next role:

- Compact prior role narratives to ~200-token summaries each.
- Keep all handoffs and artifact references verbatim.
- Mark the compaction in the document.

### Step 8 — Final

When the last role completes, close the run-level span, persist the final run document, and report verdict (release decision or blocker list).

## Rules

- Do not skip roles silently.
- Do not fabricate artifacts that were not produced.
- Do not proceed past a `blocked` handoff.
- If implementation roles modify a repository, use real commands and file paths from that repository.
- If the user asked for automatic execution, keep going without asking for confirmation between roles unless `blocked`/`needs_input` or an `irreversible` action requires per-call approval.
- Role templates declare `next_role: <determined-by-pipeline>` with an inline comment listing per-pipeline targets. The orchestrator MUST resolve this placeholder from the active pipeline before emitting the handoff.
- Never leave the placeholder string in a final handoff object.
- Subagents are dispatched only per [subagent-dispatch.md](subagent-dispatch.md); never to delegate decisions, only for context isolation.

## Minimal Orchestrator Prompt

```text
Use /team-bootstrap.
Act as the orchestrator defined in references/orchestrator.md.
Pipeline: single-thread (or mvp / full).
Spec: <path-or-text>.
Repository: <repo-path>.
Validate AGENTS.md, initialize the shared blackboard, then execute each role/phase
inline (or as a subagent per references/subagent-dispatch.md). After each role,
validate the handoff against references/schemas/role-output.schema.json and append
to the run document. Continue automatically until the pipeline finishes or blocks.
```

## Output Document Format

Single markdown document; format defined in [shared-blackboard.md](shared-blackboard.md).

```markdown
# <Task Name> — <ISO date>

## Run Metadata

- run_id: <uuid>
- workflow: team-bootstrap
- pipeline: single-thread | mvp | full | incident
- spec: <path-to-spec>
- repository: <repo-path>
- started_at: <ISO timestamp>
- agents_md: <hash of AGENTS.md>

## Spec

<verbatim copy of the task brief>

## Role 1 — <role-name>

<full role output>

### Handoff

```yaml
status: completed
role: <role-name>
...
```

## Role 2 — <role-name>

...
```

## See also

- [shared-blackboard.md](shared-blackboard.md) — how context propagates
- [subagent-dispatch.md](subagent-dispatch.md) — when to dispatch
- [subagent-mapping.md](subagent-mapping.md) — role → `subagent_type` slug routing
- [failure-policy.md](failure-policy.md) — retries, stop reasons, approvals
- [irreversibility.md](irreversibility.md) — action gating
- [tracing.md](tracing.md) — observability
