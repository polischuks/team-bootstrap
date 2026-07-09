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

## Layering (which gate runs where)

| Gate | Where | Enforces |
|---|---|---|
| Typecheck + Lint | **Stop hook** (`quality-gate.sh`) | fast, every completion — 100% |
| Red→green + evidence | role handoff schema (`verification_evidence`, `tests_failed_first`) | TDD + evidence, per role |
| E2E + no-orphans | `integration-verifier` role | wiring, per batch |
| Full suite from scratch | CI (`.github/workflows/ci.yml`) | independent environment |

## Controls

- Disable the gate for a session: `TEAM_BOOTSTRAP_QUALITY_GATE=off`.
- Optional hardening (not shipped on by default): a **PreToolUse** hook can block destructive Bash
  ahead of the [irreversibility](irreversibility.md) taxonomy — add it in project
  `.claude/settings.json` if you want belt-and-suspenders on top of `tool_surface`.
