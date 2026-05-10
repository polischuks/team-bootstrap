# Evals

Regression evals for team-bootstrap roles, pipelines, and the orchestrator. Runs reproducible task specs against the bundled roles and grades the resulting traces.

This directory ships a skeleton — fill in your own representative specs.

## Layout

```
evals/
├── README.md                       # this file
├── specs/                          # task specs to run
│   ├── <role>/                     # role-specific specs
│   │   └── <name>.spec.md
│   └── pipelines/                  # full-pipeline specs
│       └── <name>.spec.md
├── baselines/                      # last-green traces, by role and version
│   └── <role>@<version>/
│       └── <spec-name>.trace.json
└── graders/                        # grader configs (mostly use bundled defaults)
    └── <name>.yaml
```

## Running evals

team-bootstrap doesn't ship a CLI runner — eval execution is project-specific. Recommended invocation pattern:

```bash
# For each spec, run the role/pipeline, capture the trace, run graders
team-bootstrap-evals run --specs evals/specs --baseline evals/baselines
```

Implementations vary; the contract is:

1. Pick a spec
2. Run the appropriate role or pipeline ([../USAGE.md](../USAGE.md))
3. Capture the trace per [../references/tracing.md](../references/tracing.md)
4. Apply graders (bundled list in [../references/trace-evals.md](../references/trace-evals.md))
5. Compare to baseline; fail on regression

## Graders

Bundled graders (see [../references/trace-evals.md](../references/trace-evals.md)):

| Grader | Pass criterion |
|---|---|
| `handoff_valid_grader` | Every handoff matches [../references/schemas/role-output.schema.json](../references/schemas/role-output.schema.json) |
| `gate_consistency_grader` | `checks[*].status` reflects actual command results in trace |
| `approval_policy_grader` | Destructive ops (per [../references/irreversibility.md](../references/irreversibility.md)) requested approval |
| `final_verdict_grader` | Release decision matches accumulated evidence |

Project-specific graders go in `evals/graders/` as YAML; reference them from the spec frontmatter.

## Spec format

```markdown
---
spec_id: oauth-basic
target: pipeline:mvp        # or role:security-reviewer, or pipeline:single-thread
graders:
  - handoff_valid_grader
  - gate_consistency_grader
  - my-project/oauth-flow-grader
fixtures:
  repo: ./fixtures/oauth-fixture-repo
  agents_md: ./fixtures/oauth-fixture-repo/AGENTS.md
expected:
  release_decision: go
  blocked_count: 0
---

# Spec body (the task brief, same shape as a real run input)

Add OAuth login...
```

## Regression flow

1. Author a spec; run team-bootstrap with the bundled roles; verify outcome by hand
2. Save the resulting trace as a baseline at `baselines/<role>@<version>/<spec-name>.trace.json`
3. CI: on every PR touching `references/roles/*.md` or pipelines, re-run all specs and compare to baselines
4. Fail PR on:
   - Any grader regression (was passing, now failing)
   - Token-usage regression > 25% without justification in PR
   - New schema-validation failures

## Fixture repos

For specs that need a real repository to operate on, vendor a minimal fixture under `fixtures/`. Keep them small (< 200 LOC, < 20 files); the goal is reproducibility, not realism.

## Anti-patterns

- **Treating evals as "tests for the model."** They're tests for the **prompt + role + pipeline + harness**. Model behavior may shift; that's a regression signal for *the model*, but for our purposes we treat the role version + model pin as a unit.
- **Comparing free-form prose.** Grade structured outputs (handoff schema, check statuses), not narrative. Prose comparison is brittle.
- **Skipping the baseline update.** When a major-version role bump intentionally changes outputs, update the baseline and document it in the PR.

## See also

- [../references/trace-evals.md](../references/trace-evals.md) — grader catalog and rubric
- [../references/tracing.md](../references/tracing.md) — what gets captured
- [../references/versioning.md](../references/versioning.md) — when bumps require eval-suite passes
