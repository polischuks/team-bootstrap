# Invocation Examples

## Single role

```text
Use /team-bootstrap.
Work as the role described in `references/roles/backend-engineer.md`.
Repository: /path/to/repo
Task: fix the OpenClaw callback validation path.
Use the repository's AGENTS.md or CLAUDE.md and actual package scripts.
Produce a handoff object at the end.
```

## Full MVP pipeline

```text
Use /team-bootstrap.
Act as the orchestrator from `references/orchestrator.md`.
Use the MVP pipeline in `references/pipelines/mvp.md`.
Project spec: /path/to/spec.md
Repository: /path/to/repo
Run from the first role to the last role automatically.
After each role, validate the handoff and continue unless blocked.
```

## Stop at QA

```text
Use /team-bootstrap.
Act as the orchestrator from `references/orchestrator.md`.
Use the MVP pipeline in `references/pipelines/mvp.md`.
Project spec: /path/to/spec.md
Stop after `qa-test-engineer` and summarize the release risks.
```

## Targeted overengineering audit

```text
Use /team-bootstrap.
Work as the role described in `references/roles/overengineering-reviewer.md`.
Repository: /path/to/repo
Product spec: /path/to/spec.md
Task: audit whether the active workflow or implementation is overengineered relative to product value, package scope, and business goals.
Produce an overengineering audit and a handoff object.
```

## Quick slash command usage

```
/team-bootstrap mvp "Implement OpenClaw auth hardening"
/team-bootstrap full "Add new CMS integration"
/team-bootstrap role backend-engineer "Fix callback validation"
/team-bootstrap role qa-test-engineer "Validate release candidate"
```

## Single-thread (recommended default)

```text
Use /team-bootstrap.
Act as the orchestrator from `references/orchestrator.md`.
Pipeline: single-thread from `references/pipelines/single-thread.md`.
Spec: /path/to/spec.md
Repository: /path/to/repo
Run all three phases (plan → implement → verify) in a single thread, dispatching
specialist reviewers as parallel subagents only when triggered (security, a11y,
performance, data-schema). Validate AGENTS.md preconditions before starting.
```

## Resume from checkpoint

```text
Use /team-bootstrap.
Resume run_id: 01HJ7ABCDEF...
The orchestrator should load `runs/01HJ7ABCDEF.md`, find the last completed
handoff, and continue from the next role per the pipeline declared in the run
metadata.
```

## Replay from trace (for grading or debugging)

```text
Use /team-bootstrap.
Replay run_id: 01HJ7ABCDEF... [--role security-reviewer]
Re-execute the role(s) with the same input from the captured trace. Emit a
sibling trace with replay.parent_run_id set.
```

## Slash command usage (full)

```text
/team-bootstrap single-thread "Add OAuth login"
/team-bootstrap mvp "Implement OpenClaw auth hardening"
/team-bootstrap full "Add new CMS integration"
/team-bootstrap role backend-engineer "Fix callback validation"
/team-bootstrap role qa-test-engineer "Validate release candidate"
/team-bootstrap resume 01HJ7ABCDEF...
/team-bootstrap replay 01HJ7ABCDEF... --role security-reviewer
```
