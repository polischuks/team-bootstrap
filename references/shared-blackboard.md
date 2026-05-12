# Shared Blackboard

The run document is the canonical shared blackboard. **Every role reads the complete prior document**, not just the immediate predecessor's handoff.

## Why

Cognition's "Don't Build Multi-Agents" (June 2025) showed that role pipelines with private per-role context produce fragmentation: contradictory edits, lost decisions, re-litigated questions. The fix is shared context.

team-bootstrap's blackboard makes the full state visible:

- Every role's full output (not just summary)
- Every handoff (full YAML)
- Every artifact reference and path
- The original spec
- The selected pipeline

## Format

The run document is markdown:

```markdown
# <Task Name> — <ISO date>

## Run Metadata

- run_id: <uuid>
- workflow: team-bootstrap
- pipeline: mvp | full | single-thread | audit | incident
- spec: <path-to-spec>
- repository: <repo-path>
- started_at: <ISO timestamp>
- agents_md: <hash of AGENTS.md at start>

## Spec

<verbatim copy of the task brief>

## Role 1 — <role-name>

<full role output: brief, requirements, code, findings — whatever this role's template says>

### Handoff

```yaml
status: completed
role: <role-name>
...
```

## Role 2 — <role-name>

...
```

The orchestrator appends sections as roles complete. Run document location is chosen by the orchestrator at run start; default: `./runs/<run_id>.md` in the working repo, or a path the user provides.

## Read contract

When activating a role, the orchestrator must:

1. Read the **full run document** so far
2. Pass the spec, AGENTS.md, and full document to the role's working context
3. The role's output template MUST acknowledge prior decisions where relevant — not re-litigate

For roles dispatched as subagents ([subagent-dispatch.md](subagent-dispatch.md)), the orchestrator passes a curated slice rather than the full document, but only because subagent context is bounded. Inline roles always see everything.

## Write contract

Each role appends one section:

- A `## Role N — <name>` heading
- The role's full output (per its template in [roles/](roles/))
- A `### Handoff` block with validated YAML

The orchestrator validates the handoff before writing. Validation failure → no append, retry per [failure-policy.md](failure-policy.md).

## Compaction

When the run document exceeds **50% of available context window**, the orchestrator compacts:

1. Replace each prior role's narrative output (everything before `### Handoff`) with a 200-token summary
2. **Keep all handoffs verbatim** — they are typed and load-bearing
3. **Keep all artifact references** verbatim
4. Add a `<!-- compacted at role N -->` marker so trace replay can reconstruct

Compaction happens **before** activating a new role, never mid-role. Original full document is retained in the trace ([tracing.md](tracing.md)) for replay.

## Resume

To resume an interrupted run:

1. Load the run document from disk
2. Find the last completed handoff
3. Determine the next role from pipeline + last `next_role`
4. Activate that role with the full document as input

See [memory.md](memory.md) for checkpoint/resume semantics.

## Single-thread vs multi-role

In [single-thread mode](pipelines/single-thread.md), the blackboard is the same Claude session's transcript — no separate document is needed; phase transitions are marked with section headings inline. In multi-role mode, the document is explicit because the orchestrator may need to re-read it after compaction or resume.

## What the blackboard is NOT

- Not a database. It's a markdown file or transcript section. Append-only.
- Not a chat log. Role outputs are structured per template, not free-form dialogue.
- Not the trace. The trace ([tracing.md](tracing.md)) captures every LLM call and tool call; the blackboard captures only role-level decisions and artifacts.
- Not where secrets go. Anything sensitive belongs in environment / repo configuration, never in the run document.

## Privacy

The run document may be archived for grading. If it might contain PII or secrets:

- Configure the orchestrator with a redaction list (paths, patterns)
- Or run with `--ephemeral`, in which case no document is persisted (and resume is unavailable)

Default is to write to local disk only.
