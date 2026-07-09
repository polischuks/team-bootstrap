# Single-Thread Pipeline

The recommended default. One Claude session, three logical phases. Roles are activated as **output styles** at phase boundaries — not as separate agents with private context. This pipeline matches what 2025-2026 SOTA autonomous coding agents converge on, per the architecture rationale in [../../ARCHITECTURE.md](../../ARCHITECTURE.md).

Pipeline metadata:

```yaml
name: single-thread
version: 1.0.0
```

## Phases

### Phase 1 — Discover & Plan

Activates the **planning composite role**: the agent reads spec + AGENTS.md, optionally invokes `discovery-research` as a subagent for external evidence, then produces:

- A scoped plan (list of changes, files affected, tests to run)
- Open questions (if any) → if non-empty, return `needs_input` and stop
- A test plan (what proves the change works)

Active output styles drawn from: `product-ba`, `delivery-manager`, `cto-architect`. The agent emits **one** combined handoff at phase end.

Phase-end handoff:

```yaml
status: completed
role: single-thread.plan
phase: plan
release_decision: null
summary: <plan summary>
artifacts:
  - kind: plan
    path: <run-doc>#plan
    description: Scoped plan + test plan
checks:
  - name: spec_understood
    status: passed
    details: All requirements mapped to changes
  - name: test_plan_defined
    status: passed
    details: <N> tests proposed
next_phase: implement
risks_or_blockers: []
manual_approval_requested: false
stop_reason: null
rollback_recommended: false
rollback_scope: null
```

Note: phase-level handoffs use `phase` and `next_phase` instead of `role`/`next_role`. Schema variant: see [single-thread phase schema](#schema-note) below.

### Phase 2 — Implement

Activates the **implementation composite role**: backend + frontend changes inline, following
**TDD red→green** ([../tdd.md](../tdd.md)) — write the test, confirm it fails, then implement — with
a mandatory verification loop after each edit batch:

```
write test → confirm RED → implement → typecheck → lint → tests → (if any fail) repair → retry → GREEN
```

Tests are not weakened to pass. Max 3 repair cycles per check; on exhausted, phase emits `blocked`.
The verify phase records **evidence** (real command output), not an assertion, and if the change
spans backend↔frontend, confirms the path is wired end-to-end (no orphans).

Phase-end handoff:

```yaml
status: completed
role: single-thread.implement
phase: implement
summary: <what changed>
artifacts:
  - kind: code
    path: <changed file paths>
    description: Implementation
checks:
  - name: typecheck
    status: passed
    details: 0 errors
  - name: lint
    status: passed
    details: 0 warnings
  - name: unit_tests
    status: passed
    details: <N>/<N> passing
verification_attempts: <integer>
next_phase: verify
...
```

### Phase 3 — Verify & Decide

Activates **review + release composite**: runs full test suite, performs a self-review pass (covers what `code-reviewer`, `overengineering-reviewer`, `qa-test-engineer` would check), and emits a release decision.

For high-risk changes (security-sensitive, schema migrations, accessibility-critical UI), the orchestrator dispatches the relevant specialist reviewer roles as **parallel subagents** ([subagent-dispatch.md](../subagent-dispatch.md)) and merges their findings into this phase's output.

Phase-end handoff:

```yaml
status: completed
role: single-thread.verify
phase: verify
release_decision: go | no_go
summary: <verdict + rationale>
artifacts:
  - kind: verdict
    path: <run-doc>#verdict
    description: Release decision and evidence
checks:
  - name: full_tests
    status: passed
    details: <N>/<N>
  - name: self_review
    status: passed
    details: No blocking findings
  - name: specialist_review (if dispatched)
    status: passed | failed
    details: <subagent role names and outcomes>
next_phase: null
risks_or_blockers: []
manual_approval_requested: false
stop_reason: null
rollback_recommended: false
rollback_scope: null
```

## When to use single-thread vs multi-role

| Situation | Use |
|---|---|
| Most engineering tasks | `single-thread` |
| Compliance-required audit trail per discipline | `mvp` or `full` |
| External stakeholders need role-attributed sign-off | `mvp` or `full` |
| Long-horizon (>2 hours wall-clock) | `single-thread` with checkpoints |
| Production release of customer-facing change | `full` (includes `release-manager`, `stakeholder-communicator`, `documentation-agent`) |

## Specialist subagent dispatch (Phase 3)

The orchestrator dispatches a specialist as subagent when the spec or implementation hits a trigger:

| Trigger | Subagent |
|---|---|
| DB migration / schema change | `data-schema-reviewer` |
| Auth, payments, PII handling | `security-reviewer` |
| User-facing UI change | `accessibility-reviewer` |
| Hot path / data-heavy endpoint | `performance-reviewer` |

If multiple triggers fire, dispatch in parallel. See [subagent-dispatch.md](../subagent-dispatch.md).

## Schema note

Single-thread phases use a slight variant of the role-output schema: `role` becomes `single-thread.plan` / `single-thread.implement` / `single-thread.verify`, and `next_role` becomes `next_phase` (with values `plan` | `implement` | `verify` | `null`).

The schema currently validates each phase as a `single-thread.<phase>` role definition. Implementation note for orchestrator: extend [../schemas/role-output.schema.json](../schemas/role-output.schema.json) with three additional `$defs` for `single-thread.plan`, `single-thread.implement`, `single-thread.verify` if strict validation of single-thread phases is required. v1.0 ships without these explicit `$defs`; phase handoffs are validated against the base shape and the orchestrator-level rules in this document.

## Anti-patterns

- **Treating phases as fully independent.** They share a thread; later phases see everything from earlier phases verbatim.
- **Skipping Phase 3 verify.** "I tested while implementing" is not the same as a full verification pass. Always run.
- **Dispatching the planning composite as a subagent.** Phase 1 needs full context to make the plan; isolating it defeats the purpose.
- **Forgetting to declare specialist triggers in the spec.** If your change touches the DB, say so in the spec. The orchestrator's trigger detection is best-effort.

## See also

- [../../ARCHITECTURE.md](../../ARCHITECTURE.md) — design rationale (Cognition, single-thread)
- [../subagent-dispatch.md](../subagent-dispatch.md) — when to dispatch
- [mvp.md](mvp.md), [full.md](full.md) — multi-role alternatives
