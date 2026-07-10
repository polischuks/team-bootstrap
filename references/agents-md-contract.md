# AGENTS.md Contract

team-bootstrap reads `AGENTS.md` (or `CLAUDE.md`) from the repository root at run start. This file is the persistent memory tier ([memory.md](memory.md)) — the canonical source for project-specific commands, conventions, and constraints.

By 2026, the AGENTS.md spec has stabilized as the de-facto convention across Codex, Cursor, Aider, Devin, Sourcegraph Amp, and Claude Code. team-bootstrap requires a specific subset of fields.

## Required fields (run blocks if missing)

A `## Build & Run` section with:

- An `Install:` line containing the dependency-install command (`npm ci`, `poetry install`, etc.)
- A `Dev:` line containing the dev-server command (or `N/A` if non-applicable)

A `## Test` section with:

- A `Unit:` line containing the unit-test command
- A `Typecheck:` line (or `N/A` if dynamically typed)
- A `Lint:` line (or `N/A` if not linted)

A `## Code Style` section, even if just "Follow existing conventions in the file being edited."

A `## Security` section with:

- A `Secrets:` line stating where secrets live (env, vault, .env file path)
- A `Never commit:` list of patterns

These are the minimum for `qa-test-engineer` and implementation roles to function.

## Recommended fields (advisory; some roles fall back if missing)

A `## Testing` section detailing:

- E2E command (`E2E:`)
- Coverage target (`Coverage target:`)
- Fixture/setup commands

A `## PR Conventions` section with:

- Commit message format (e.g., Conventional Commits)
- PR title format
- Branch naming

A `## Monorepo Scoping` section if the repo is a monorepo:

- How to identify the relevant package for a task
- Per-package AGENTS.md locations

A `## Destructive Scripts` section listing:

- Project-specific commands that have `irreversible` semantics (e.g., `npm run reset:prod-db`, `bin/cleanup-staging`). Used by [irreversibility.md](irreversibility.md) classification.

A `## Known Hazards` section:

- File patterns engineers should avoid touching without coordination
- Modules with high churn / fragile tests

An `## Architecture` section (the **architecture baseline** — see
[architecture-baseline.md](architecture-baseline.md)):

- Boundaries/modules, layers, and allowed dependency directions (e.g. `web → app → domain`).
- Forbidden edges, ideally machine-checkable, e.g. `- forbid: src/domain imports web`.
- Sanctioned patterns for recurring work.

Consumed by `architecture-reviewer` to gate soundness (plan) and conformance/drift (batch). If
absent, that role's first finding is "no baseline — establish one". A project `ARCHITECTURE.md` or
the project's ADRs may hold this instead.

## Per-role consumption

| Role | Reads which sections |
|---|---|
| `product-ba`, `business-analyst`, `product-manager` | `## Build & Run`, `## Testing` (to ground requirements in feasibility) |
| `delivery-manager` | `## Test`, `## Testing`, `## PR Conventions` (to populate validation commands and PR steps) |
| `cto-architect`, `cto-tech-lead`, `solution-architect` | All sections; especially `## Security`, `## Known Hazards` |
| `backend-engineer`, `frontend-engineer` | All sections; mandatory `## Test` to populate verification loop |
| `qa-test-engineer` | `## Test`, `## Testing` |
| Reviewer roles (security/perf/a11y/data-schema) | `## Security`, `## Known Hazards`, language/framework specifics |
| `devops-platform`, `release-manager`, `release-docs` | `## Destructive Scripts`, `## Security`, `## PR Conventions` |
| `documentation-agent` | `## PR Conventions` |

## Failure mode: missing required fields

If a required field is absent, the orchestrator returns at run start (not mid-pipeline):

```yaml
status: needs_input
role: orchestrator
summary: AGENTS.md is missing required fields
risks_or_blockers:
  - "AGENTS.md missing section: ## Build & Run > Install:"
  - "AGENTS.md missing section: ## Test > Unit:"
stop_reason: missing_user_input
```

The user fixes `AGENTS.md` and re-runs.

## CLAUDE.md fallback

If `AGENTS.md` doesn't exist but `CLAUDE.md` does, team-bootstrap reads `CLAUDE.md` with the same field requirements. If both exist, `AGENTS.md` wins (the broader-ecosystem convention).

## Per-package AGENTS.md (monorepo)

In monorepos, place an `AGENTS.md` at each package root. The orchestrator uses the spec's mentioned files/paths to determine the relevant package and merges:

1. Repo root `AGENTS.md` (base)
2. Package `AGENTS.md` (overrides root for keys that conflict)

Rules:

- Per-package `AGENTS.md` may omit fields that the root provides
- Per-package fields override conflicting root fields
- Required-field check applies to the **merged** view

## Hashing for trace

The orchestrator records `agents_md.sha256` in the run trace ([tracing.md](tracing.md)) at run start. If `AGENTS.md` changes mid-run (e.g., a role edits it), the orchestrator re-loads and records both hashes — useful for replay reproducibility.

## Anti-patterns

- **Putting secrets in AGENTS.md.** It's in git; everyone sees it. Use `## Security > Secrets:` to point to where secrets live (vault, env), not the secrets themselves.
- **Listing every file in `## Known Hazards`.** Keep it to genuinely fragile or coordination-required modules.
- **Drift.** AGENTS.md updated by humans for humans; agents read it verbatim. Stale commands → broken runs. Treat AGENTS.md edits as load-bearing.
- **Markdown decorative content** without the required headings. The orchestrator uses heading detection; non-conforming structure fails the required-field check.

## Template

See [examples/AGENTS.md.template](../examples/AGENTS.md.template) for a complete starting point with all required and recommended sections.

## See also

- [memory.md](memory.md) — three-tier memory model
- [irreversibility.md](irreversibility.md) — how `## Destructive Scripts` feeds action gating
- [versioning.md](versioning.md) — `agents_md.sha256` capture
