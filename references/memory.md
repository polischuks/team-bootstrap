# Memory

team-bootstrap distinguishes three memory tiers. Each has different durability, scope, and what's safe to put in it.

## The three tiers

### 1. Persistent (project-scoped)

**Lives in:** `AGENTS.md` / `CLAUDE.md` at repo root, plus per-package `AGENTS.md` files.

**Durability:** Lifetime of the repository. Versioned in git.

**Read by:** Every role at session start.

**Write by:** Humans, or `documentation-agent` role with explicit approval.

**Contains:** Build/test/lint commands, code style, security constraints, monorepo scoping rules, destructive-script declarations, project-specific conventions.

Schema and required fields: [agents-md-contract.md](agents-md-contract.md).

### 2. Per-run (shared blackboard)

**Lives in:** The run document (markdown file or main-thread transcript section).

**Durability:** Lifetime of the run. Persisted to disk if `--persist-run-document` (default: yes).

**Read by:** Every role in the same run.

**Write by:** The orchestrator, appending one section per role.

**Contains:** Spec, every role's full output, every handoff, run metadata.

Details: [shared-blackboard.md](shared-blackboard.md).

### 3. Per-role (scratchpad)

**Lives in:** Role's working context only. **Does not propagate.**

**Durability:** Lifetime of the role's execution.

**Read by:** Only the role itself.

**Write by:** The role.

**Contains:** Intermediate exploration, partial drafts, internal reasoning. Captured in the trace ([tracing.md](tracing.md)) but excluded from the blackboard.

Useful for: a role exploring 10 files to find the right one, drafting and discarding wrong solutions, multi-attempt reasoning. None of that should pollute the blackboard.

## Checkpoint and resume

Each role's validated handoff is a **checkpoint**. After validation, the orchestrator persists the run document state. To resume:

```text
/team-bootstrap resume <run_id>
```

The orchestrator:

1. Loads the persisted run document
2. Reads metadata: pipeline, spec, repo
3. Finds the last `### Handoff` block; checks `status` and `next_role`
4. If last status is `completed`: continue from `next_role`
5. If `blocked` / `needs_input`: surface the blocker, do not auto-resume
6. If validation failed mid-role: re-execute that role from scratch (no partial-state resume)

Resume restores blackboard, **not** per-role scratchpads (those are gone). If a role was mid-execution when the run was interrupted, that role re-runs from the start.

## What memory team-bootstrap does NOT have

- **Cross-run learning.** team-bootstrap is stateless across runs. Lessons from a past run don't influence a future one unless explicitly written into `AGENTS.md` or the role playbooks.
- **Long-term agent memory** (Letta/MemGPT-style). Out of scope; would require a separate memory service.
- **Vector retrieval over past runs.** If you need this, build it as a project-level MCP server and add it to roles' `tool_surface`. Not bundled.

## Privacy and retention

| Tier | Default retention | Where |
|---|---|---|
| Persistent | Forever (in git) | Repo |
| Per-run | 30 days local, then archive policy | `./runs/<run_id>.md` |
| Per-role | Lifetime of trace (per [tracing.md](tracing.md) sampling) | Trace backend |

Override via orchestrator flags:

- `--ephemeral` — no run document persisted; resume unavailable
- `--retention 7d` — auto-prune runs/ older than 7 days
- `--no-content-capture` — traces capture structure but not prompt/response bodies (memory is still in the run document; this only affects traces)

## Anti-patterns

- **Putting secrets in the run document.** It may be archived/shared. Secrets belong in env, not in markdown.
- **Re-asking for AGENTS.md content in every role.** It's loaded once at session start; roles read it from session context, not by re-issuing reads.
- **Carrying scratchpad to next role.** Use the handoff. If a role's intermediate finding is needed downstream, it must be in an `artifact` or in the role's narrative output.
- **Resuming after schema change.** If `role-output.schema.json` changed between runs, old handoffs may not validate. Resume detects this; bump skill version and require fresh runs.

## See also

- [shared-blackboard.md](shared-blackboard.md) — per-run tier in detail
- [agents-md-contract.md](agents-md-contract.md) — persistent tier in detail
- [tracing.md](tracing.md) — what the trace captures (and how that differs from memory)
- [failure-policy.md](failure-policy.md) — `after-failure` resume mode
