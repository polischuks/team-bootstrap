# Cumulative invariants, regression, and gate integrity

The dominant failure mode found when auditing real `/deliver` output: a task is closed for the
**workflow that existed that day**, the work was usually done — but it was never held as an
**invariant**, so a later milestone silently breaks it and the closure still reads `[x]`. Point
fixes reproduce the class (fixing it in one workflow leaves the same hole in four others). The cure
is not more one-shot reviewers; it is verification that is **cumulative, fail-closed, and
meta-checked**.

## 1. Invariants graduate into a regression suite (fixes "closed for that day")

Anthropic's eval practice: *capability evals that reach a high pass rate **graduate** into a
**regression suite** that runs continuously, holds near 100%, and exists to prevent backsliding*
([Demystifying evals](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents)).
team-bootstrap applies this to delivery:

- When a task is genuinely **VERIFIED** (integration + architecture gates green, evidence shown),
  its acceptance criterion **graduates** into the project's persistent regression suite.
- **Every subsequent batch/milestone re-runs the whole accumulated suite across all workflows** —
  not just the batch's own path. A previously-green invariant that goes red is a **regression** and
  a hard block, regardless of what the closing agent remembers.
- **A task is `CLOSED` only when its invariant holds repo-wide *now*** — not "for the workflow that
  existed that day."

### Where the suite lives (convention, not infra)

- Project tests tagged as invariants: `@invariant` / `tag:regression` (framework-native), run via
  the project's test command from `AGENTS.md`.
- A `.regressions/registry.md` in the project: one row per graduated invariant — id, the closure it
  came from, the workflows it must hold across, and how it's checked. This is the ledger the
  `regression-guardian` reads and appends to.
- Seed it from real failures: every audit finding and every "it got worse" report becomes a
  regression case ([Demystifying evals](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents)).

## 2. Capability conformance — declared ⇒ exercised (fixes "string exists, not works")

A capability that is *declared* is not a capability that *works*: `connected_vendors` that checks a
string is present, an agent that declares 15 tools and dispatches 9, a required gate that can't
actually read. Tools are contracts that must be exercised, and progress is judged by **ground truth
from the environment**, not by declaration
([Writing tools for agents](https://www.anthropic.com/engineering/writing-tools-for-agents),
[Building Effective Agents](https://www.anthropic.com/engineering/building-effective-agents)).
The [integration-verifier](roles/integration-verifier.md) therefore checks **`declared ⇒
exercised`**: every capability/vendor/tool a batch claims must be observably invoked and succeed
(probe passes), or it is a `capability_gap` finding.

## 3. Gate integrity — a gate that didn't run is a failure, not a pass (fixes vacuous/skipped/disabled guards)

The audit found guards that **can't fail**: a validator never called and vacuous anyway,
constitutional tests green because the job `skip`s them, a contract gate switched off for 16
milestones. A gate is only worth its **non-disableability**. So team-bootstrap meta-checks its own
gates ([hooks fail-closed](hooks.md), [The Verification Gap](https://codemyspec.com/blog/agentic-qa-verification)):

- **No green-by-skip.** A gate/constitutional test that passes only because it was skipped is a
  failure, surfaced loudly — [`../bin/check-gate-integrity.sh`](../bin/check-gate-integrity.sh).
- **No silently-disabled gate.** A gate that was turned off (contract gate, a fitness function) is a
  loud finding, not a silent omission.
- **A gate must be observed to run.** "The guard exists" is not "the guard ran"; the
  `regression-guardian` records which gates actually executed for the batch.

Enforced by the [regression-guardian](roles/regression-guardian.md) role and its schema hard gate.
