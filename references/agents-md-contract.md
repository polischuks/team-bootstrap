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

### Test-quality gate fields (v2.17.0 — all optional; absence ⇒ the gate skips+warns, never a false block)

Consumed by the F1/F2/F3 `verify-batch` gates ([enforcement.md](enforcement.md)). Same backtick/bare
convention as `Test:`/`Typecheck:`; the framework declares the *contract*, the project supplies the runner
(no bundled coverage/mutation tooling — P7):

- **`TestGlobs:`** (F1) — extra test-path globs, space/comma-separated, that **extend** the built-in set
  (`*_test.*`, `*.test.*`, `test_*.*`, `*.spec.*`, `*Test.*`, `*_spec.rb`, and any path under
  `test/ tests/ spec/ __tests__/`). Extends only — a project can widen the "what counts as a test" set,
  never shrink it. Inline-test layouts (Rust `#[cfg(test)]`, doctests) set this to their source globs.
- **`Coverage:`** (F2) — a command emitting an **LCOV** tracefile to stdout (or to the `CoverageFile:`
  path). It must cover **all changed files** (cover-all / `--include`) so an untested changed file appears
  as `DA` misses, not as an absence. Emitted natively by coverage.py, lcov, nyc, tarpaulin, …
- **`CoverageFile:`** (F2) — optional path the `Coverage:` command writes LCOV to (else stdout is parsed).
- **`CoverageThreshold:`** (F2) — minimum percent of the batch's changed non-doc lines that must be
  covered. Default **80**.
- **`CoverageStrict:`** (F2) — `true` counts changed lines the report never measured as **misses**
  (denominator = all changed non-doc lines), so a non-cover-all report fails instead of passing over its
  subset. Default (unset/false): pass over the measured subset but emit a **loud WARN** — a partial report
  never passes silently.
- **`Mutation:`** (F3) — a command running the project's mutation tool **scoped to changed files**, emitting
  a final `mutation_score: <float>` (0–100) **or** `killed:<k>` + `total:<t>` line. Adapters: Stryker
  (JS/TS), mutmut (Py), PIT (JVM), cargo-mutants (Rust) — documented, not parsed natively.
- **`MutationThreshold:`** (F3) — minimum mutation score to pass under enforce. Default **60**.
- **`MutationMode:`** (F3) — `enforce` (hard gate) or `advisory` (report only). Default **advisory** —
  mutation is opt-in by contract, not by pipeline tier.
- **`VersionFiles:`** (version-sync) — a space/comma list of `path` (whole trimmed file) or `path:key`
  (first `"key":"…"` in that file) whose version values must all agree, e.g.
  `` `package.json:version`, `pyproject.toml:version` ``. **Only needed for non-plugin projects** — a
  plugin (`.claude-plugin/plugin.json` present) is checked automatically (`VERSION` + `plugin.json.version`
  + every `marketplace.json` version). Absent + not a plugin ⇒ the gate skips + warns
  ([`check-version-sync.sh`](../bin/check-version-sync.sh)).

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

An `## Invariants` section (or a `.regressions/registry.md` + invariant-tagged tests — see
[regression-and-invariants.md](regression-and-invariants.md)):

- What must **hold across all workflows** (not just the one closed today), and how each is checked
  (the test/command that proves it).
- How a verified closure **graduates** into the regression suite.

Consumed by `regression-guardian` to re-run invariants across workflows and gate regressions. If
absent, closures aren't protected and "closed for that day" drift goes undetected.

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
