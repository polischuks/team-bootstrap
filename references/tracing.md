# Tracing

team-bootstrap emits OpenTelemetry GenAI semantic-convention spans for every LLM call, tool call, role boundary, and subagent dispatch. Traces are the canonical record for replay, regression eval, and post-incident debugging.

## Span hierarchy

```
run                                    span_kind=internal
├── role.<n>.<role-name>                span_kind=internal
│   ├── llm.<provider>.<model>          span_kind=client
│   │   gen_ai.system, gen_ai.usage.*
│   ├── tool.<tool-name>                span_kind=internal
│   │   gen_ai.tool.name, gen_ai.tool.call.id
│   │   irreversibility.class
│   ├── subagent.<role-name>            span_kind=internal
│   │   subagent.dispatch_reason
│   │   subagent.input_token_estimate
│   └── ...
└── role.<n+1>.<role-name>
    └── ...
```

## Required attributes

### Run span

| Attribute | Type | Example |
|---|---|---|
| `run.id` | string (UUID) | `01HJ7…` |
| `run.pipeline` | string | `mvp`, `full`, `single-thread` |
| `run.spec_path` | string | `./specs/oauth.md` |
| `run.repo_root` | string | `/path/to/repo` |
| `run.started_at` | RFC 3339 | `2026-05-10T14:23:00Z` |

### Role span

| Attribute | Type | Example |
|---|---|---|
| `role.name` | string | `security-reviewer` |
| `role.version` | string | `1.4.2` |
| `role.dispatch_mode` | enum | `inline`, `subagent` |
| `role.attempt` | integer | `1` (incremented on retry) |
| `role.outcome` | enum | `completed`, `blocked`, `needs_input`, `failed` |

### LLM call span (per OTel GenAI conventions)

| Attribute | Type |
|---|---|
| `gen_ai.system` | `anthropic` |
| `gen_ai.request.model` | `claude-opus-4-7` |
| `gen_ai.operation.name` | `chat` |
| `gen_ai.usage.input_tokens` | integer |
| `gen_ai.usage.output_tokens` | integer |
| `gen_ai.usage.cache_read_input_tokens` | integer (if cached) |
| `gen_ai.usage.cache_creation_input_tokens` | integer (if cached) |

Prompt and response capture as span events with names `gen_ai.user.message`, `gen_ai.assistant.message`, `gen_ai.tool.message` per the spec.

### Tool call span

| Attribute | Type |
|---|---|
| `gen_ai.tool.name` | `Edit`, `Bash`, `mcp__github__create_issue` |
| `gen_ai.tool.call.id` | string |
| `irreversibility.class` | `read_only` / `stateful_local` / `stateful_remote` / `irreversible` |
| `tool.approval_required` | boolean |
| `tool.approval_outcome` | `approved` / `rejected` / `auto` (if applicable) |
| `tool.target` | string (free-form: branch name, channel, file path; redacted per privacy policy) |

For `Bash`, also include `tool.bash.command_class` (the matched pattern from [irreversibility.md](irreversibility.md)).

### Subagent span

| Attribute | Type |
|---|---|
| `subagent.role` | string |
| `subagent.dispatch_reason` | enum: `context_isolation`, `parallel_review`, `user_request` |
| `subagent.input_token_estimate` | integer |
| `subagent.return_status` | enum (mirrors role.outcome) |

## Privacy & redaction

Default capture includes prompt and response content. Configure redaction per project:

- Patterns: regex list applied to span events before export
- Path-based: file content from listed paths is replaced with hash
- Tool-arg redaction: specific tool args (e.g. `Bash` command bodies for matched patterns) replaced with `<redacted>`

Run with `--no-content-capture` to skip prompt/response events entirely; structural attributes still recorded.

## Backends

team-bootstrap is backend-agnostic. Tested integrations:

| Backend | OTLP endpoint setup |
|---|---|
| **Langfuse** (OSS, self-hosted) | OTLP HTTP at `<langfuse>/api/public/otel`; configure `OTEL_EXPORTER_OTLP_ENDPOINT` |
| **Arize Phoenix** (OSS) | Same; `OTEL_EXPORTER_OTLP_ENDPOINT=http://<phoenix>:6006/v1/traces` |
| **Honeycomb** | `api-team-bootstrap.honeycomb.io`, `OTEL_EXPORTER_OTLP_HEADERS="x-honeycomb-team=…"` |
| **Datadog** | DD agent on localhost; OTLP receiver enabled |
| **Local file** | `OTEL_EXPORTER_OTLP_ENDPOINT=file:///<path>/traces.jsonl` (for offline replay) |

Configuration lives in Claude Code's environment, not in the skill. The skill assumes a tracer is available and emits spans; export is the harness's job.

## Replay

To replay a captured run for grading or debugging:

```text
/team-bootstrap replay <run-id> [--role <role-name>]
```

The orchestrator:

1. Loads the trace by `run.id`
2. Reconstructs role inputs (spec, blackboard slice at that role's start) from earlier span events
3. Re-activates the role with the same model/version
4. Captures the new run as a sibling trace with `replay.parent_run_id` attribute

Replay is **best-effort reproducible**, not bit-exact. Provider non-determinism, MCP server state, and external API responses are not controlled by the harness. For deterministic replay, use a captured-tool-response cassette (project-specific tooling).

## Sampling

For high-volume production, sample at the run level (head-based: `OTEL_TRACES_SAMPLER=parentbased_traceidratio`). Within a sampled run, **all spans are kept** — partial role traces are useless for grading.

## Trace as eval input

[trace-evals.md](trace-evals.md) describes the grading rubric. Graders consume traces as input, not the run document — traces have full LLM call detail, the run document only has role-level handoffs.

Standard graders:

- `handoff_valid_grader` — every handoff matches schema
- `gate_consistency_grader` — checks reflect actual command results (no fabrication)
- `approval_policy_grader` — destructive ops requested approval
- `final_verdict_grader` — release decision matches accumulated evidence

Each grader runs against the trace, emits a score and a JSON report linked back to the run via `run.id`.

## See also

- [trace-evals.md](trace-evals.md) — grading rubric and regression flow
- [versioning.md](versioning.md) — how trace replay supports prompt-regression evals
- [shared-blackboard.md](shared-blackboard.md) — blackboard vs trace; what each captures
