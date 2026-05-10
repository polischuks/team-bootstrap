# Failure Policy

Use this policy for autonomous multi-role execution.

## Statuses

- `completed`: role finished and produced the required output shape
- `blocked`: role cannot continue without a real blocker being resolved
- `needs_input`: role is waiting for missing user or environment input
- `failed`: validation or gate failure
- `awaiting_retry`: runtime will permit another attempt
- `awaiting_approval`: runtime requires a manual approval decision before continuing
- `completed_run`: final role passed and the run is complete

## Retry Policy

- Allow up to `2` retries per role by default.
- Retry only on validation failures or incomplete handoff structure.
- Do not auto-retry `blocked` or `needs_input`.
- Stop immediately once the retry budget is exhausted.

## Manual Approval Policy

Require manual approval when:

- the role explicitly sets `manual_approval_requested: true`
- the role is `devops-platform`
- the role is `release-manager`

Manual approval should produce one of:

- `approved`
- `rejected`
- `deferred`

## Rollback Policy

The runtime must not invent rollback actions. Instead:

- record `rollback_recommended: true` when a gate fails after a destructive or externally visible change
- record `rollback_scope` as a short free-text description
- stop and hand off to a human or a dedicated recovery flow

## Stop Reasons

Use one of these canonical stop reasons:

- `schema_validation_failed`
- `gate_requirements_missing`
- `unexpected_next_role`
- `manual_approval_required`
- `manual_approval_rejected`
- `external_blocker`
- `missing_user_input`
- `retry_budget_exhausted`
- `release_verdict_no_go`
- `timeout_exceeded`
- `policy_gate_failed`

## Resume Policy

When resuming a stopped run:

- `after-timeout`: archive the partial role attempt and retry the same role
- `after-failure`: archive the failed attempt, reset the retry counter for the current role, and retry
- `force`: bypass the stop-reason check and reopen the current role manually

## Approval And Tooling Best Practice

- Prefer approval-preserving execution for risky steps.
- Keep the active tool surface as small as possible for each role.
- Escalate to human review for infra, release, external publishing, or destructive actions.
- Full-auto is forbidden for `devops-platform` and `release-manager`.

## Irreversibility Gates

Approval gates for destructive actions are governed by [irreversibility.md](irreversibility.md), not by `manual_approval_requested` at the role level.

| Action class | Approval policy |
|---|---|
| `read_only` | auto-allow |
| `stateful_local` | confirm-once-per-run |
| `stateful_remote` | confirm-each |
| `irreversible` | deny-by-default; explicit per-call approval with target preview |

`manual_approval_requested: true` in a handoff is **advisory** — it suggests human review of the role's entire output. It does NOT replace per-action irreversibility gating. Action class is determined by the harness from the tool + arguments, not by the role.

## Cross-references

- [irreversibility.md](irreversibility.md) — action class taxonomy
- [tracing.md](tracing.md) — how stop reasons and approval outcomes are recorded
- [memory.md](memory.md) — `after-failure` and `after-timeout` resume modes
