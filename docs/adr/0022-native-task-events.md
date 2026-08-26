# ADR-0022 — Native `TaskCreated`/`TaskCompleted` are recorded, not made load-bearing

- **Status:** Accepted
- **Date:** 2026-08-26
- **Milestone:** `specs/020-live-roles-and-harness-wiring` (AC-46)

## Context

Claude Code exposes `TaskCreated` and `TaskCompleted`. Both **can block**, and `TaskCreated` can roll
back the creation of a task. That is a genuinely interesting primitive for this project: a batch is
conceptually a task, and a rollback point at creation is the one place a bad batch could be refused
before any work is done rather than at close, after it.

The research doc raised it with an explicit condition — *"if batches ever land on native Tasks"* — and
the question sat unanswered while `record-task.sh` was already wired to both events during the
roles-alive wave. Wired but undecided is the worst of the three states: the surface is in use and
nobody has said what it is for.

## Decision

**Both events stay registered and stay OBSERVATIONAL.** `record-task.sh` records them to the run
directory. Neither is given a blocking role, and no gate depends on either.

A batch remains a ledger entry in `.runs/<id>/batches.jsonl`, not a native Task.

## Why not make them load-bearing

- **Batches do not map onto native Tasks, and forcing the mapping would invert the dependency.** A
  batch is defined by a git window — baseline..HEAD, with `commit_shas` — which is what makes closure
  verifiable from repository state (ADR-0002). A native Task has no git window. Binding batch identity
  to Task identity would replace a fact the harness can *verify* with one the model *reports*, which is
  the trade this project exists to refuse.
- **Blocking `TaskCreated` is the same mistake as blocking `PreToolUse[Agent]`.** The research doc's own
  "do not do" list rejects a blocking dispatch gate because refusing a dispatch pushes the work inline —
  the spec-169 collapse. Refusing task *creation* has the identical shape: the orchestrator does the
  work without creating a task. A non-blocking observation cannot be evaded this way, because there is
  nothing to evade.
- **The rollback is not the missing primitive.** The gap a rollback point would close — catching a bad
  batch early — is already covered by Phase-0 preflight (ADR-0010) and by sizing at announce
  (ADR-0017/0018). Adding a second, weaker version of an existing control buys cost, not coverage
  (ADR-0016).

## Consequences

- **Kept:** the recording. It is cheap, it cannot fail open, and it gives the metrics in
  `bin/delivery-metrics.sh` a second source if batches and Tasks ever do converge.
- **Accepted:** the rollback capability stays unused. Recorded here so the next reader knows it was
  weighed, not missed.
- **Revisit when:** native Tasks gain a durable identifier that survives a session and can be tied to a
  git window. At that point the mapping objection disappears and this ADR should be reopened — the
  blocking objection would still stand on its own.
