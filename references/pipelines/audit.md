# Audit Pipeline

Read-only assessment of an existing codebase against a reference (spec, design, production-readiness checklist). Produces a prioritized backlog of remediation tasks and a `release-manager` go/no_go verdict. **No implementation roles run.** Each backlog item then becomes a separate `single-thread` / `mvp` / `full` team-bootstrap run.

Pipeline metadata:

```yaml
name: audit
version: 1.0.0
```

## When to use

- Quarterly production-readiness review.
- Pre-release gate for customer-facing change.
- "What's left before we ship?" question on a long-lived branch.
- Project handover — verify state against documented spec/design.
- Compliance review against new regulation or platform policy.

Do **not** use this pipeline to drive implementation work — that's what `single-thread` / `mvp` / `full` are for. Audit produces the backlog; those pipelines execute it.

## Roles (in order)

1. `discovery-research` — gather external context: design references, spec docs, related industry standards, prior research
2. `cto-tech-lead` — set the audit's quality bar and risk posture against project goals
3. `solution-architect` — assess current architecture against the spec; identify structural gaps
4. `data-schema-reviewer` — assess DB schema, migrations, data integrity
5. `security-reviewer` — OWASP risks, secrets, auth, PII handling
6. `accessibility-reviewer` — WCAG compliance of shipped UI (if user-facing)
7. `performance-reviewer` — N+1 queries, memory, scalability of hot paths
8. `ai-engineer` — LLM/RAG/agent layer state (if applicable; skip if no AI surface)
9. `legal-compliance-checker` — GDPR/CCPA/HIPAA/PCI/COPPA/platform-policy obligations (if applicable)
10. `ux-researcher` — design compliance, friction (if a design reference is provided)
11. `qa-test-engineer` — test coverage, suite health, evidence of correctness
12. `overengineering-reviewer` — complexity vs delivered value
13. `code-reviewer` — overall code quality, conventions, maintainability
14. `documentation-agent` — docs gap analysis (README, ADRs, runbooks, API)
15. `release-manager` — synthesize findings → prioritized backlog + go/no_go

## Parallelization

Roles 4–10 (specialist reviewers + optional roles) can be dispatched as parallel subagents — they read the same code snapshot and don't depend on each other. See [../subagent-dispatch.md](../subagent-dispatch.md#parallel-dispatch-reviewers). Sequential execution remains the conservative default.

## Required Handoff Outputs

| Role | Must produce before next role |
| --- | --- |
| `discovery-research` | reference inventory: spec docs, design refs, standards |
| `cto-tech-lead` | quality bar definition, risk posture for this audit |
| `solution-architect` | architecture gap report: what spec says vs what exists |
| `data-schema-reviewer` | severity_counts, migration_safe, schema gap list |
| `security-reviewer` | severity_counts, secrets_audit_passed, OWASP gap list |
| `accessibility-reviewer` | severity_counts, wcag_aa_compliant, a11y gap list |
| `performance-reviewer` | severity_counts, perf gap list with measured baselines |
| `ai-engineer` | AI surface state, eval coverage, cost/latency observations (if applicable) |
| `legal-compliance-checker` | applicable frameworks, gap list with risk classification (if applicable) |
| `ux-researcher` | design-vs-implementation gap inventory (if design ref provided) |
| `qa-test-engineer` | coverage report, release_risk, suite health |
| `overengineering-reviewer` | verdict (appropriate/overengineered/underengineered) |
| `code-reviewer` | approval_status, code-quality findings |
| `documentation-agent` | docs gap list (what should exist, what doesn't, what's stale) |
| `release-manager` | release_decision, prioritized backlog (TASK-XXX list) for Phase 2 |

## Optional / conditional roles

- `ai-engineer` — skip if the project has no LLM/AI surface
- `legal-compliance-checker` — skip if no PII/PHI/payments and no new region/processor
- `ux-researcher` — skip if no design reference is provided in the audit spec
- `accessibility-reviewer` — skip if no user-facing UI

The orchestrator may skip an optional role with `status: completed, summary: not applicable to this audit, checks: [{name: applicability, status: skipped, details: ...}]` and continue. A skip must be explicit, never silent.

## Tool surface

All audit-pipeline roles are read-only by contract — their frontmatter `tool_surface.deny` blocks `Write` and `Edit`. `Bash` is allowed only for read-only inspection commands (`pnpm test --reporter=verbose`, `git log`, etc.). `permission_mode` is `plan` or `ask` for every role. No role may modify the repository during audit.

## Audit spec contract

The user-supplied spec (`/team-bootstrap audit <spec>`) **must** include:

- **Reference**: what the project is being audited against (path to spec doc, design dir, checklist URL, regulation reference).
- **Scope**: which packages / directories / surfaces are in scope.
- **Out of scope**: explicit exclusions.
- **Production-readiness criteria**: how go/no_go is decided.
- **Risk appetite**: which severities block release (typically critical+high block; medium informational).

Missing any of these → orchestrator returns `needs_input` at Step 0 (per [../agents-md-contract.md](../agents-md-contract.md) failure-mode).

## Output

A single run document plus a derived `audit-backlog.md` written to a path declared in the audit spec. The backlog is the **handoff to Phase 2** — each task has:

- `id`: TASK-XXX
- `title`: short imperative
- `source_role`: which audit role found it
- `severity`: critical | high | medium | low
- `category`: security | perf | a11y | schema | compliance | docs | ux | code-quality | architecture
- `acceptance_criteria`: how Phase 2 knows it's done
- `recommended_pipeline`: `single-thread` | `mvp` | `full`
- `optional_roles`: any of `ai-engineer` / `whimsy-injector` / `chaos-engineer` / `legal-compliance-checker` etc. to opt into

## Release decision rules

`release-manager` applies these rules to decide go/no_go:

- Any `critical` finding → `no_go`
- ≥3 `high` findings → `no_go` (unless explicitly waived in spec)
- Any blocking compliance gap → `no_go`
- All `medium`/`low` → informational; do not block release

If `no_go`, the response includes which TASK-XXX must clear before re-running audit.

## Anti-patterns

- **Treating audit as implementation.** The pipeline is read-only by design. Roles propose fixes; they do not write them.
- **Skipping reviewers because "we just audited last week."** Audit is cheap; staleness is expensive. Re-run.
- **Fabricating findings to look thorough.** Empty review with `severity_counts: {0,0,0,0}` is a valid handoff if there genuinely are no issues.
- **Letting the audit blackboard exceed context without compaction.** Apply [../orchestrator.md](../orchestrator.md#step-7--compaction-when-needed) Step 7 aggressively — audit runs touch many files.

## See also

- [../orchestrator.md](../orchestrator.md) — execution loop
- [../subagent-dispatch.md](../subagent-dispatch.md) — parallel reviewer fan-out
- [../role-matrix.md](../role-matrix.md) — role catalog
- [single-thread.md](single-thread.md), [mvp.md](mvp.md), [full.md](full.md) — Phase 2 pipelines for executing the audit backlog
