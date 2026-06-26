# Subagent Dispatch

When a role runs **inline** in the main thread vs. dispatched as a **subagent** via Claude Code's `Task` tool.

## Default

**Inline.** The orchestrator activates the role's instructions as the active output style and continues in the main thread. The role reads the shared blackboard ([shared-blackboard.md](shared-blackboard.md)) and emits its handoff. This preserves shared context — the central principle from Cognition's "Don't Build Multi-Agents."

## When to dispatch as subagent

Dispatch **only** when context isolation strictly outweighs the cost of summarization:

| Trigger | Rationale |
|---|---|
| Role will read >5 files of code in detail (e.g. security audit on a wide surface) | Subagent context fills with raw file content; main thread stays clean |
| Multiple reviewers can run in parallel (security + perf + a11y on the same diff) | Wall-clock speedup; outputs merged on return |
| Long-form research (discovery-research with web fetches) | Web content is bulky and rarely needed by downstream roles verbatim |
| User explicitly requests isolation for compliance reasons | Auditable separation of inputs |

### Do not dispatch

For these roles, inline execution is mandatory by default ([subagent-mapping.md](subagent-mapping.md#inline-only-roles) lists the same set):

- Planning roles (product-ba, delivery-manager, architects) — they need full context to make decisions
- Implementation roles (backend, frontend) — edits + verification are tightly coupled and must stay coherent
- Anything that produces decisions the next role inherits — Cognition's anti-pattern

## Dispatch contract

When the orchestrator dispatches a role to a subagent:

### Subagent input

```yaml
role: <role-name>
spec: <task brief, full text>
blackboard_slice:
  - <relevant prior-role section, full text>
  - <relevant prior-role section>
artifacts:
  - kind: <type>
    path: <repo-path>
relevant_files: [<paths>]
tool_surface: <from role frontmatter>
permission_mode: <from role frontmatter>
return_format: handoff_yaml
```

The slice is curated by the orchestrator: include sections the role will actually need, not the entire blackboard. Rule of thumb: ≤30% of the main-thread context, never the full transcript.

### Subagent return (enforced budget)

A subagent may burn tens of thousands of tokens internally, but only a **bounded, condensed**
result is allowed to cross back into the main thread. This is what separates a context-isolated
subagent from a naive one that dumps its whole working set into the shared blackboard. The return
budget is a **hard contract**, not a suggestion:

Exactly three things cross back:

1. the **structured handoff** (the role's object per [schemas/role-output.schema.json](schemas/role-output.schema.json)), whose `summary` is **capped at ≤~200 tokens (~1200 chars)** — the schema enforces `maxLength` on `summary`;
2. **artifact paths** — never artifact *bodies*. A security audit's full finding list, a research role's raw fetches, a reviewer's annotated diff all go to **files**; the handoff references their paths;
3. nothing else.

The main thread then:

1. Validates the handoff against schema (a summary over budget fails validation → counts against the role's retry budget);
2. Appends the handoff + the condensed summary to the blackboard;
3. Decides next role per pipeline.

Subagent thinking, intermediate file reads, and tool calls are **not** propagated to the main thread. They are captured in the trace ([tracing.md](tracing.md)) for replay, not forwarded inline. This budget matters most for deep-audit / research roles (`security-reviewer`, `discovery-research`, `performance-reviewer`) whose internal context is large and rarely needed verbatim downstream.

## Failure handling

- **Subagent crashes / no return:** orchestrator records `stop_reason: subagent_failed`, retries once with the same input, then escalates as `blocked`.
- **Subagent returns invalid handoff:** counts against the role's retry budget per [failure-policy.md](failure-policy.md). On exhausted budget, escalate.
- **Subagent timeout** (default: 10 minutes): treat as failure.

## Parallel dispatch (reviewers)

When multiple reviewer roles can run in parallel (data-schema, accessibility, performance, security on the same implementation snapshot), the orchestrator dispatches them as concurrent subagents and collects all returns before continuing.

```text
[main thread] frontend-engineer completed
              ↓
              ├─→ subagent: data-schema-reviewer
              ├─→ subagent: accessibility-reviewer
              ├─→ subagent: performance-reviewer
              └─→ subagent: security-reviewer
              (parallel)
              ↓ (all complete)
[main thread] qa-test-engineer (sees all four review handoffs in blackboard)
```

This is the only place team-bootstrap intentionally fans out. The `full` pipeline accommodates this when the orchestrator decides to parallelize step 11-14; sequential execution remains the conservative default.

## Anti-patterns

- **Dispatching to "save context" without need.** If the role doesn't read a lot or run long, inline is cheaper.
- **Dispatching planning roles.** They make decisions downstream roles inherit; private context fragments those decisions.
- **Forwarding subagent transcript to main thread.** Use the structured handoff and a brief summary; the transcript lives in the trace.
- **Chaining subagents (subagent dispatches another subagent).** team-bootstrap supports one level of dispatch from the main thread. Deeper trees produce the fragmentation Cognition warned about.

## Implementation note for orchestrator

Use Claude Code's `Task` tool. **Resolve `subagent_type` from the role's `preferred_subagent_types` frontmatter** per [subagent-mapping.md](subagent-mapping.md):

1. Read `preferred_subagent_types: [...]` from `references/roles/<role>.md` frontmatter.
2. Apply stack overrides from [subagent-mapping.md](subagent-mapping.md) — e.g. `nextjs-developer` when `AGENTS.md > ## Stack` lists Next.js, `fastapi-developer` for FastAPI, etc. Stack vector is resolved **once** at run start and cached in run metadata.
3. Walk the (possibly stack-overridden) list left-to-right; pick the first slug that resolves in the host environment.
4. If none resolve, fall back to `subagent_type: general-purpose`.
5. Record the resolved slug as `team_bootstrap.subagent_type` on the role span ([tracing.md](tracing.md)) so eval/replay sees the routing decision.

The orchestrator's own guardrails (`tool_surface`, `permission_mode`, irreversibility class) are applied on top of the specialist's defaults — the specialist's expertise is used, but team-bootstrap wins on tools and permissions.

The orchestrator must include explicit instructions to return the handoff YAML — the `Task` tool returns one final string, so the prompt must direct the subagent to emit valid YAML.

See [orchestrator.md](orchestrator.md) for the dispatch decision point in the execution loop, and [subagent-mapping.md](subagent-mapping.md) for the role→specialist mapping table.
