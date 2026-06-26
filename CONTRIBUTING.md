# Contributing to team-bootstrap

Thanks for your interest. team-bootstrap is a markdown-and-schema asset, not a
code library — contributions are role playbooks, pipeline definitions, reference
docs, and the small support scripts under `bin/`. This guide explains how to land
a change cleanly.

## Before you start

- Read [ARCHITECTURE.md](ARCHITECTURE.md) — the single-thread-by-default design and
  the "subagents for context isolation, never for delegation" principle are
  load-bearing. Changes that violate them will be asked to reconsider.
- Skim [references/role-matrix.md](references/role-matrix.md) to see where a new
  role would fit, and whether an existing one already covers the need.

## Project layout

| Path | What lives here |
|---|---|
| `SKILL.md` | Skill entry point; keep counts and links in sync with reality |
| `references/roles/` | One playbook per role (42 today) |
| `references/pipelines/` | Pipeline definitions (`single-thread`, `mvp`, `full`, `audit`, `audit-dd`) |
| `references/schemas/` | JSON Schemas for role frontmatter and handoff output |
| `bin/` | `check-skills.sh`, `eval-role.sh` — the local quality gates |
| `evals/` | Eval harness and fixtures |

## Adding or changing a role

1. Copy the shape of an existing role in `references/roles/`. Every role needs valid
   frontmatter that passes the schema.
2. Validate it locally:
   ```bash
   bin/eval-role.sh <role>        # static frontmatter validation
   bin/eval-role.sh --all         # validate every role (the CI gate)
   ```
3. If the role uses skills, update `skills-manifest.json` and confirm:
   ```bash
   bin/check-skills.sh <pipeline>
   ```
4. Update any catalog that names a count or lists roles (`SKILL.md`,
   `references/role-matrix.md`). Stale counts are the most common review comment.

## Versioning

Roles and the framework follow SemVer; see [references/versioning.md](references/versioning.md).
A behavior change to a role is a minor bump; a breaking handoff-shape change is a
major bump. Note the change in [CHANGELOG.md](CHANGELOG.md) under *Unreleased*.

## Submitting

- Keep PRs focused — one role, one pipeline, or one reference doc per PR where possible.
- Run `bin/eval-role.sh --all` and ensure all internal markdown links resolve.
- Describe the *why*, not just the *what*, in the PR body.

## License

By contributing, you agree your contributions are licensed under the project's
[MIT License](LICENSE).
