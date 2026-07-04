# 0001 — Single-thread by default; subagents for context isolation only

- **Status:** Accepted
- **Date:** 2026-06-26
- **Constitution clause(s):** P1, P2

## Context
Multi-agent systems with private per-role context produce contradictory edits, lost
decisions, re-litigation of settled questions, and fragility past ~10 tool calls (Cognition,
"Don't Build Multi-Agents", June 2025; corroborated by SOTA agent benchmarks through
2025–2026). team-bootstrap needed to decide whether to orchestrate many agents or run one
context with role phases.

## Decision
Run most tasks single-thread: roles are phase boundaries within one Claude session sharing the
full run document as a blackboard. Dispatch subagents **only** for context isolation
(research, security audit, parallel reviews), never to delegate a decision. Multi-role
pipelines (`mvp`, `full`, `audit`, `audit-dd`) remain available for tasks that require formal
phase gates and an audit trail.

## Alternatives considered
- **Pure multi-agent orchestration (LangGraph/AutoGen-style, private context per agent)** —
  rejected: reintroduces the exact failure modes above; contradicts P2.
- **Fixed SOP pipeline for every task (MetaGPT-style)** — rejected: pays multi-phase cost even
  for trivial work; contradicts P1.

## Consequences
- Shared blackboard is mandatory; every role reads complete prior state.
- Subagent dispatch needs an explicit isolation rationale
  ([subagent-dispatch.md](../../references/subagent-dispatch.md)).
- `full` audits are slower by design — that cost buys the audit trail.
