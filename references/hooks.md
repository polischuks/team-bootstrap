# Hooks (harness-enforced gates)

Prose instructions in a role or CLAUDE.md are followed ~70% of the time; **hooks enforce rules at
~100%** ([Anthropic — Claude Code best practices](https://code.claude.com/docs/en/best-practices),
[The Verification Gap](https://codemyspec.com/blog/agentic-qa-verification)). So the always-on
quality gate belongs in a hook, not a playbook.

## What ships

[`../hooks/hooks.json`](../hooks/hooks.json) registers a **Stop hook** that runs
[`../bin/quality-gate.sh`](../bin/quality-gate.sh). The Stop hook fires when the agent declares it
is done; if the gate exits non-zero (2), completion is **blocked** and the failure is fed back —
the agent cannot stop over red checks.

`quality-gate.sh` runs the **fast** checks (`Typecheck`, `Lint`) declared in the project's
`AGENTS.md` / `CLAUDE.md`. It is deliberately fast:

- Full unit / E2E suites stay with [integration-verifier](roles/integration-verifier.md) and CI —
  too slow to run on every Stop.
- It **no-ops** (exit 0) when there is no `AGENTS.md`/`CLAUDE.md` (a non-team-bootstrap session)
  or when a command is `N/A`, so it is safe to have active globally.

### Delivery-run hooks (v2.12.0)

Two more hooks make the delivery-occurred gate ([enforcement.md](enforcement.md)) **self-starting** and
**fail-closed** without nagging non-delivery sessions. Both key on the run marker `.runs/<run>/RUN` and
**no-op (exit 0) whenever no active marker is present** — the same on-by-default-safe property as
`quality-gate.sh` without an `AGENTS.md`.

- **`UserPromptSubmit` → [`../bin/delivery-marker-init.sh`](../bin/delivery-marker-init.sh)** — when a
  prompt invokes `/deliver` (an `mvp`/`full` pipeline + a spec path), it writes the run marker
  (`intends_code:true`, `baseline_sha`) **before any Skill/tool runs**. This makes "a delivery run is
  active" a harness-owned machine fact, so an orchestrator that skips the batch protocol cannot make the
  gate no-op (the marker exists regardless). It detects the invocation by scanning the whole stdin
  payload, so it is agnostic to the exact prompt-field name, and it always exits 0 (never blocks a
  prompt). On any non-`/deliver` prompt it no-ops.
- **`Stop` → [`../bin/delivery-stop-hook.sh`](../bin/delivery-stop-hook.sh)** — while a marked run still
  has a `kind:code` batch announced-but-unclosed (or has delivered no code), it **blocks completion
  (exit 2)** with an actionable message; it allows the stop (exit 0) once all code batches are closed or
  no marker is present. It is deliberately **not** on `SubagentStop`: worker subagents
  (integration-verifier, reviewers) finish *before* `verify-batch.sh` stamps the batch closed, so
  blocking their `SubagentStop` on an unclosed batch would deadlock the step that closes it — the
  premature-completion this guards is the **main orchestrator's** (`Stop`).

## Layering (which gate runs where)

| Gate | Where | Enforces |
|---|---|---|
| Typecheck + Lint | **Stop hook** (`quality-gate.sh`) | fast, every completion — 100% |
| Red→green + evidence | role handoff schema (`verification_evidence`, `tests_failed_first`) | TDD + evidence, per role |
| E2E + no-orphans | `integration-verifier` role | wiring, per batch |
| Batch gate (orphans + drift + gate-integrity) | `bin/verify-batch.sh` at batch close **+ CI** | dead code / drift / green-by-skip — non-bypassable at merge ([enforcement.md](enforcement.md)) |
| Full suite from scratch | CI (`.github/workflows/ci.yml`) | independent environment |

## Controls

- Disable the quality gate for a session: `TEAM_BOOTSTRAP_QUALITY_GATE=off`.
- Disable the delivery hooks (marker writer + Stop) for a session: `TEAM_BOOTSTRAP_DELIVERY_GATE=off`.
- Optional hardening (not shipped on by default): a **PreToolUse** hook can block destructive Bash
  ahead of the [irreversibility](irreversibility.md) taxonomy — add it in project
  `.claude/settings.json` if you want belt-and-suspenders on top of `tool_surface`.
