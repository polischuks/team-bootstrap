# Test-Driven Development (red → green)

TDD is the single strongest pattern for agentic coding: each red-to-green cycle gives the model
unambiguous ground truth to iterate on without a human in the loop
([Anthropic — Claude Code best practices](https://code.claude.com/docs/en/best-practices)). team-bootstrap
treats it as the default implementation discipline for `mvp`, `full`, and the implement phase of
`single-thread`.

## The loop (do not skip a step)

1. **Write the tests first** from the acceptance criteria — before any implementation.
2. **Run them and confirm they FAIL** (red) via [`../bin/tdd-red.sh`](../bin/tdd-red.sh) — it runs the
   project's `Test:` command, **requires** a non-zero (red) result, and records the observed red
   (`red_sha` = current HEAD) to `.runs/<run>/tdd.jsonl`. A test that passes before you wrote the code
   tests nothing — `tdd-red` refuses to record a green suite. This makes "seen to fail" a **git-grounded
   fact**, not the self-declared `tests_failed_first` boolean: [`../bin/check-tdd.sh`](../bin/check-tdd.sh)
   (run inside `verify-batch`) **fails the batch** if a code-shipping run has no red record whose
   `red_sha` sits between the run baseline and HEAD, or if the suite isn't green at HEAD.
   **Per batch:** run `tdd-red.sh --batch <id>` at the red step of **each** code batch — every code
   batch must be red-first in its own window (`… < redₖ < codeₖ`), and one red record credits at most
   one batch, so you cannot cover B2 with B1's red.
3. **Commit the failing tests** as a checkpoint.
4. **Implement until green** — iterate against the test output, not against intention.
5. **Do not modify the tests to make them pass.** If a test is wrong, fix it deliberately and say
   so in the handoff; never quietly weaken a test to go green.

## Evidence, not assertion

The green result must be shown, not claimed: the engineer/QA handoff carries
`verification_evidence` — a real command-output excerpt — required when `status: completed`
([schemas/role-output.schema.json](schemas/role-output.schema.json), [trace-evals.md](trace-evals.md)).
"Tests pass" without the output is not acceptable ([Anthropic — Claude Code best practices](https://code.claude.com/docs/en/best-practices)).

## Per-step verification (ground truth from the environment)

Don't wait for the end. After each significant change, run typecheck + lint + the relevant tests
and correct against the result — "gain ground truth from the environment at each step"
([Anthropic — Building Effective Agents](https://www.anthropic.com/engineering/building-effective-agents)).
The fast typecheck/lint half of this is also harness-enforced by the Stop hook
([hooks.md](hooks.md)); the full/integration half is enforced by
[integration-verifier](roles/integration-verifier.md).

## Who owns what

- `test-designer` (full) writes the test strategy and failing cases **before** implementation.
- `backend-engineer` / `frontend-engineer` follow red→green, keep tests immutable, and attach
  `verification_evidence`.
- `qa-test-engineer` re-runs and attaches its own evidence; does not trust prior self-reports.
