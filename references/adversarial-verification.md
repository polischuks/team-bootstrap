# Adversarial & cross-model verification

For high-stakes decisions, one verifier is not enough. Two complementary techniques harden the
evaluator gate ([evaluator.md](evaluator.md)) beyond a single pass.

## 1. Adversarial refutation (spawn skeptics to disprove)

Have a **fresh model try to refute** the result, so the agent doing the work is not the one grading
it ([Anthropic — Claude Code best practices](https://code.claude.com/docs/en/best-practices)). For a
critical finding or a release `go`:

- Dispatch N independent verifiers (clean context), each **prompted to disprove** the claim —
  default to "refuted" when uncertain.
- Accept the claim only if a majority fail to refute it.
- This composes with [reviewer_consensus](trace-evals.md) (record the tally) and the
  [integration-verifier](roles/integration-verifier.md) (outcome-based, builder ≠ auditor).

Reserve it for what's expensive to get wrong: a release decision, a security finding, an
irreversible action — not every routine handoff.

## 2. Cross-model / cross-provider review

Running one model's output past a **different model** catches meaningfully different categories of
bugs than single-model review ([The Verification Gap](https://codemyspec.com/blog/agentic-qa-verification)).
Where a second provider/model is available, route a critical review (security, release go/no-go,
data migration) to it as an independent second opinion. team-bootstrap stays Claude-Code-native by
default; this is an **optional** hardening layer, invoked for high-stakes changes, not the norm.

## When to escalate to this layer

| Signal | Escalate? |
|---|---|
| Release `go` on customer-facing / regulated change | yes — adversarial refutation |
| CRITICAL security or data-integrity finding | yes — cross-model second opinion |
| Irreversible action ([irreversibility.md](irreversibility.md)) | yes — refutation before approval |
| Routine, reversible, low-severity change | no — single evaluator pass is enough |

Cost is real (extra passes/tokens); apply by stakes, and **log** when it was applied vs skipped so
coverage is honest, never silently dropped.
