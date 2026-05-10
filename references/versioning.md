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
model: claude-opus-4-7
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

CI integration is project-specific. Recommended: a GitHub Action that runs `team-bootstrap-evals` on every PR touching `references/roles/*.md`.

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
4. Run the full eval suite against representative specs (one per pipeline)
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
- [schemas/role-frontmatter.schema.json](schemas/role-frontmatter.schema.json) — frontmatter schema
