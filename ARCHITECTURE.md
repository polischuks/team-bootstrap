# Architecture

## Design philosophy

team-bootstrap is built on three commitments:

1. **Single-thread by default; multi-role for audit.** Most engineering tasks run as one Claude session, with roles as output styles for distinct phases. The multi-role pipelines (`mvp`, `full`) are available for tasks that require formal phase gates and explicit audit trail (compliance, production releases, regulated work).

2. **Shared context broadly; subagents narrowly.** Following Cognition's "Don't Build Multi-Agents" (June 2025), the full run document is the shared blackboard — every role reads the complete state, not just the prior handoff. Subagents are dispatched only for context isolation (research, security audit, parallel reviews), never to delegate decisions.

3. **Harness-enforced policy; LLM-out-of-security-loop.** Tool surfaces and irreversibility classes are declared in role frontmatter and enforced by Claude Code permissions and hooks. The model never decides whether an action is safe — the harness does.

## Why not pure multi-agent

Cognition's analysis (and SOTA agent benchmarks through 2025-2026) showed that multi-agent systems with private per-role context produce:

- Contradictory edits (two roles independently modify the same file)
- Lost decisions (role N can't see role M's reasoning, only the summary)
- Re-litigation of settled questions in later roles
- Fragility under long horizons (10+ tool calls)

Frameworks that survived 2025 (LangGraph, OpenAI Agents SDK, Claude Agent SDK, AutoGen v0.4) converged on: typed structured outputs + handoff-as-tool-call + checkpoint/resume + isolated subagents for narrow tasks. team-bootstrap follows this convergence rather than the older MetaGPT-style SOP-pipeline pattern.

## The four primitives

### 1. Roles

Declarative markdown playbooks at [references/roles/](references/roles/). Each role has:

- **Frontmatter:** `name`, `version`, `model`, `compatible_pipelines`, `tool_surface`, `permission_mode` (validated by [references/schemas/role-frontmatter.schema.json](references/schemas/role-frontmatter.schema.json))
- **Mission, inputs, outputs** (markdown body)
- **Output template** with YAML handoff
- **Rules**

Tool surface declares what tools the role may use; permission mode declares how Claude Code handles tool calls. See [references/versioning.md](references/versioning.md).

### 2. Pipelines

Ordered role lists at [references/pipelines/](references/pipelines/):

- [`single-thread.md`](references/pipelines/single-thread.md) — default, one session with phase boundaries
- [`mvp.md`](references/pipelines/mvp.md) — 7-role multi-phase pipeline
- [`full.md`](references/pipelines/full.md) — 20-role pipeline with specialized reviewers

The orchestrator selects a pipeline; pipelines select roles.

### 3. Handoffs

Typed YAML emitted at the end of each role. Schema: [references/schemas/role-output.schema.json](references/schemas/role-output.schema.json). Every handoff has:

- Status, summary, artifacts, checks, next_role, risks_or_blockers
- Approval and rollback flags
- Per-role required fields (e.g. `release_decision: go|no_go` for `release-manager`)

Validated against the schema before the orchestrator continues. Validation failure → bounded retry per [references/failure-policy.md](references/failure-policy.md).

### 4. Shared blackboard

The run document. Every role reads the complete prior document — full handoffs and full role outputs, not just the immediate predecessor's summary. See [references/shared-blackboard.md](references/shared-blackboard.md).

## Failure model

| Trigger | Action |
|---|---|
| Schema validation failure | Bounded retry (default 2). On exhausted: `stop_reason: schema_validation_failed` |
| `blocked` status | Stop, surface blocker |
| `needs_input` status | Stop, ask only for missing input |
| Destructive action | Manual approval gate per [references/irreversibility.md](references/irreversibility.md) |
| Subagent failure | Re-dispatch fresh; if exhausted, escalate as blocker |
| Verification loop exhausted | Implementation role hands off `blocked`; not silently passing failed checks |

## Observability

- Each LLM call and tool call emits OpenTelemetry GenAI spans (see [references/tracing.md](references/tracing.md))
- Run ID propagates across all spans
- Run document is the canonical artifact for grading
- Trace replay supports prompt-regression evals: re-run a captured trace and diff outputs

## Why this is portable

- Roles are markdown — readable by any agent runtime, not just Claude Code
- Schemas are JSON Schema 2020-12 — validated by any JSON Schema validator
- Tracing is OpenTelemetry — consumed by Langfuse, Phoenix, Datadog, Honeycomb, etc.
- Tool surface naming aligns with Claude Code defaults but maps cleanly to MCP server names

If Claude Code goes away, you keep the spec.

## What this is not

- Not a hypothetical future framework. Works today, no extra runtime.
- Not vendor-locked. Markdown + JSON Schema + OTel.
- Not a multi-agent orchestrator in the LangGraph/AutoGen sense. The orchestrator is Claude itself reading the playbooks.
- Not a replacement for thinking. Bad inputs (vague spec, no AGENTS.md) produce bad runs — garbage in, garbage out.
- Not a substitute for real review. The release decision is authored by the model; humans should still inspect the diff.

## Trade-offs we accepted

- **Verbose role files vs. compact orchestrator code.** We optimize for readability and modifiability over runtime efficiency. The orchestrator runs once; the role files are read by humans repeatedly.
- **Single-thread default makes multi-role audit slower.** When you ask for `full`, you pay the cost of 20 distinct phases. That's the point of the audit trail.
- **Schema strictness can break bespoke handoffs.** `unevaluatedProperties: false` rejects unknown fields. Custom roles must declare their per-role fields explicitly. This is the right default — silent extras are a footgun.

## Where to read next

- [references/shared-blackboard.md](references/shared-blackboard.md) — how context propagates
- [references/subagent-dispatch.md](references/subagent-dispatch.md) — when to spawn a subagent
- [references/irreversibility.md](references/irreversibility.md) — action gating
- [references/tracing.md](references/tracing.md) — observability
- [references/versioning.md](references/versioning.md) — role evolution
