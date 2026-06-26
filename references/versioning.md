# Versioning

Roles, pipelines, and the team-bootstrap skill itself are versioned with semver. Prompts are code; they need the same release discipline.

## What gets versioned

| Artifact | Version field | Bump rules |
|---|---|---|
| Role playbook ([roles/](roles/)) | `version` in frontmatter | See "Bump rules" below |
| Pipeline ([pipelines/](pipelines/)) | `version` at top of pipeline file | New roles or reordering = minor; renaming a role = major |
| Handoff schema ([schemas/role-output.schema.json](schemas/role-output.schema.json)) | (no internal version; track by skill version) | Field rename or required-field addition = major skill bump |
| Skill | `version` in [.claude-plugin/plugin.json](../.claude-plugin/plugin.json) and [CHANGELOG.md](../CHANGELOG.md) | Aggregate of role/pipeline/schema changes |

## Role frontmatter

Every role file starts with:

```yaml
---
name: backend-engineer
version: 1.0.0
model: claude-sonnet-4-6
compatible_pipelines: [mvp, full, single-thread]
tool_surface:
  allow: [Read, Edit, Write, Bash, Grep, Glob]
  deny: []
  mcp: []
permission_mode: acceptEdits
---
```

Schema: [schemas/role-frontmatter.schema.json](schemas/role-frontmatter.schema.json).

## Bump rules per role

| Change | Bump |
|---|---|
| Wording, examples, clarifications, fixed typos | patch (1.0.0 → 1.0.1) |
| New optional handoff field, new advisory rule, new section | minor (1.0.0 → 1.1.0) |
| New required handoff field, removed/renamed field, contract change to per-role schema, model pin change | major (1.0.0 → 2.0.0) |
| Tool surface tightened (deny added) | patch — runs that worked still work |
| Tool surface loosened (deny removed) | minor — capability addition |
| Tool surface gained a new `mcp` server | minor |

Major bumps require eval-suite pass (see "Regression evals" below) and a CHANGELOG entry.

## Model pin

Each role declares the model it was authored against. Switching model (e.g., 4.7 → 4.8) is a **minor** bump for the role if the eval suite passes, **major** if outputs differ structurally. The pin is advisory: the harness may run a role with a different model if explicitly configured, but trace and grading record both `role.version`'s pinned model and the actual model used.

## Regression evals

Each role should have at least one representative spec in `evals/<role>/`. The eval suite:

1. Runs the role against the spec(s) on a clean blackboard
2. Captures the trace ([tracing.md](tracing.md))
3. Applies the role's grading rubric (default: `handoff_valid_grader` + role-specific check)
4. Compares to the baseline trace (last green run for that role version)

A role-file PR must pass:

- Schema validation on emitted handoffs
- All graders pass (or pass with a documented diff)
- No regression in token usage > 25% without justification

CI integration is project-specific. Recommended: a GitHub Action that runs the version gate below on every PR touching `references/roles/*.md`.

## Version gate (enforced)

A version bump is **not** a free-text edit — it must be earned. The gate has two layers, ordered cheap-to-expensive; a regression at either layer **blocks the bump**.

**Layer 1 — static (runnable today).** Any PR that touches a role file must pass:

```bash
bin/eval-role.sh <role>      # one role
bin/eval-role.sh --all       # whole suite, for CI
```

This validates frontmatter against [schemas/role-frontmatter.schema.json](schemas/role-frontmatter.schema.json) and exits non-zero on drift. It is the minimum bar and runs without a model or network.

**Layer 2 — behavioral replay (where baselines exist).** For a role with a saved baseline, replay its baseline specs against the edited role and compare ([trace-evals.md](trace-evals.md#regression-testing), `/team-bootstrap replay <run_id>`). Treat agent configuration (instructions, tool definitions, guardrails, model pin) as code: a behavior change is reviewed like a code change.

The bump is **blocked** if any of the following regress versus baseline:

| Signal | Block condition |
|---|---|
| Static validation | `bin/eval-role.sh` exits non-zero |
| Grader result | A grader that was `pass` is now `fail` |
| Final verdict | A release/go-no-go verdict flips against the same evidence |
| Schema | New handoff schema-validation failures |
| Token usage | > 25% increase without written justification in the PR |

A blocked bump is a **regression signal, not flakiness** — investigate before merging, never retry-until-green. When a major bump *intentionally* changes outputs, update the baseline in the same PR and say so in the CHANGELOG.

> **Pending ratification:** the Unreleased model-tier change (all roles re-pinned from `claude-opus-4-7` to a per-tier model) is a **minor**-class change per the model-pin rule below. It ships under the skill-level Unreleased entry and is to be ratified per-role through Layer 2 once role baselines are populated; until then it clears Layer 1 (static) only.

## Compatibility matrix

A pipeline only runs if every role it lists is `compatible_pipelines`-compatible:

```yaml
compatible_pipelines: [mvp, full, single-thread]
```

Adding a role to a pipeline requires both the pipeline and the role to be updated. The orchestrator refuses to run a pipeline that includes a role declaring incompatibility.

## Skill release flow

When ready to cut a skill release:

1. Bump `version` in [.claude-plugin/plugin.json](../.claude-plugin/plugin.json)
2. Add an entry to [CHANGELOG.md](../CHANGELOG.md) under a new heading with today's date
3. Tag the git ref: `v1.x.y`
4. Run the version gate: `bin/eval-role.sh --all` (Layer 1) + replay representative specs, one per pipeline (Layer 2)
5. Ship

Pre-1.0 had implicit versioning via git history; from 1.0 onward the file-level `version` is authoritative.

## Anti-patterns

- **Bumping role version without rationale.** The CHANGELOG should say why.
- **Editing a role's contract without bumping major.** Per-role required fields are part of the schema; adding/removing/renaming is breaking.
- **Pinning model in the role body, not frontmatter.** Tools and traces need to read it programmatically; markdown prose is invisible to them.
- **Treating eval failures as flakiness.** A failing eval after a prompt edit is a **regression signal**, not a flaky test. Investigate before merging.

## See also

- [trace-evals.md](trace-evals.md) — grader catalog and pass criteria
- [tracing.md](tracing.md) — how traces feed graders
- [../bin/eval-role.sh](../bin/eval-role.sh) — runnable Layer-1 static gate (and judge-prompt assembly)
- [evaluator.md](evaluator.md) — the per-handoff evaluator rubric the behavioral layer reuses
- [model-tiers.md](model-tiers.md) — per-role model pins governed by the model-pin rule
- [schemas/role-frontmatter.schema.json](schemas/role-frontmatter.schema.json) — frontmatter schema
