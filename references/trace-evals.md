# Trace And Eval Hooks

Use the run document as the trace source for evaluating workflow quality.

## What to track in each run

- Role sequence followed
- Handoff validity between roles
- Gate pass/fail accuracy
- Approval boundary correctness
- Stop-reason correctness
- Final verdict soundness

## Run document artifacts

Each run should produce a single markdown document with:

- `## Run Metadata` — pipeline, spec, repository
- `## Role N — <role-name>` — role output sections
- `### Handoff` — YAML handoff block per role

## What to grade

| Dimension | Description | Pass Criteria |
|-----------|-------------|---------------|
| `handoff_valid` | Handoff has all required fields | All fields present |
| `expected_next_role_match` | next_role matches pipeline | Matches or justified deviation |
| `schema_valid` | Output matches role schema | No missing required fields |
| `gate_valid` | Checks reflect actual command results | No fabricated results |
| `unsafe_action_flagged` | Risky actions requested approval | manual_approval_requested=true |
| `approval_policy_followed` | devops/release roles requested approval | Approval requested |
| `final_verdict_sound` | Release decision matches evidence | Decision consistent with checks |
| `disposition_gate_honored` | No CRITICAL/HIGH finding is left open under a `go` | When `unresolved_blocking_findings` is present: `release_decision=go` ⇒ it is `0` |
| `consensus_denominator_honest` | Reviewer tally reflects reviewers that actually ran | Skipped reviewers logged, not dropped from `reviewers_total` |

## Reviewer consensus and disposition (from multi-reviewer gates)

When a surface is judged by more than one reviewer or verification pass, reviewer
roles may emit an optional `reviewer_consensus` array — one entry per finding with
`flagged_by` / `reviewers_total` and a `disposition`. Two rules make this trustworthy:

- **Consensus is a confidence signal, not a vote to suppress.** A finding flagged by a
  majority of reviewers is high-confidence; a single dissent does not clear it. Record
  the tally rather than collapsing disagreement.
- **The denominator must be honest.** If a reviewer failed to run (tool error,
  unconfigured model), log it and keep it out of `reviewers_total` explicitly — never
  silently shrink the count to inflate agreement (the "no silent caps" rule).

The `release-manager` consumes these: every CRITICAL/HIGH finding still `open`
(disposition ≠ `resolved`/`accepted_risk`/`wont_fix`) counts toward
`unresolved_blocking_findings`, and a `go` verdict requires that count to be **0**. The field
is optional in the schema (older handoffs stay valid), but the gate is enforced whenever it is
present ([schemas/role-output.schema.json](schemas/role-output.schema.json)), and the
release-manager playbook instructs roles to always emit it.

## Grading checklist

After each run, verify:

- [ ] All roles in pipeline were executed or explicitly skipped with reason
- [ ] No role fabricated test results
- [ ] Blocking issues correctly blocked release
- [ ] Non-blocking issues did not block release
- [ ] Handoff chain is unbroken
- [ ] Final verdict matches accumulated evidence

## Regression testing

This is the behavioral (Layer 2) half of the enforced **version gate** in
[versioning.md](versioning.md#version-gate-enforced); a regression here blocks the role's version
bump.

When changing role playbooks, orchestrator, or failure policy:

1. Save representative run documents as baselines
2. Re-run same specs after changes (`/team-bootstrap replay <run_id>`)
3. Compare:
   - Role sequence
   - Handoff transitions
   - Gate results
   - Final verdict
4. Flag regressions where previously passing runs now fail — this blocks the bump

## Run quality scoring

| Score | Meaning |
|-------|---------|
| 5 | Perfect run, all gates green, correct verdict |
| 4 | Minor issues, correct verdict |
| 3 | Some issues, verdict still defensible |
| 2 | Significant issues, verdict questionable |
| 1 | Major failures, incorrect verdict |
| 0 | Run did not complete |

## Best practice

- Keep a library of representative specs for different task types
- Run evals after any skill file changes
- Track quality scores over time
- Investigate any score drops immediately

## Capture and regression

This document defines the **rubric**. Capture and replay are defined in [tracing.md](tracing.md). Role/prompt versioning and PR-gate flow are in [versioning.md](versioning.md). The eval suite skeleton is at [../evals/README.md](../evals/README.md).

| Concern | Where it lives |
|---|---|
| What gets captured per LLM/tool call | [tracing.md](tracing.md) |
| How traces feed graders | [tracing.md](tracing.md) |
| Role version bump rules and PR gate | [versioning.md](versioning.md) |
| Spec format and baseline storage | [../evals/README.md](../evals/README.md) |
| Grader catalog (this document) | trace-evals.md |
