# Architecture baseline & fitness functions

An implementation can pass every test, wire up end-to-end (the [integration-verifier](roles/integration-verifier.md)
gate), and still **violate the application's architecture** — wrong layer, a bypassed boundary, a
dependency pointing the wrong way, a duplicated abstraction. Left unchecked this is **architectural
drift**: the implemented architecture diverges from the intended one with no deliberate decision to
justify it, and compounds into erosion ([architecture drift](https://earezki.com/ai-news/2026-06-08-architecture-drift-detection-keep-your-code-aligned-with-design/)).
The baseline is the ground truth the [architecture-reviewer](roles/architecture-reviewer.md) checks
against.

## The baseline (ground truth)

The **architecture baseline** is the target project's intended architecture, written down so it can
be checked — the analog of this repo's own [constitution.md](../constitution.md) + [ADRs](../docs/adr/),
but for the app being built. It declares:

- **Boundaries / modules** — the units and what each owns.
- **Layers & allowed dependency directions** — e.g. `web → app → domain`, never the reverse;
  `domain` depends on nothing.
- **Forbidden edges** — cross-boundary imports that must not exist (`billing` must not import
  `checkout` internals; UI must not import the DB client directly).
- **Sanctioned patterns** — the approved way to do the recurring thing (how a route is added, how
  data access is layered), so batches don't each invent their own.

Where it lives in the target project (checked in order): a project `ARCHITECTURE.md`, an
`## Architecture` section in `AGENTS.md`, or the project's ADRs. If none exists, the
architecture-reviewer's first finding is *"no baseline — architecture cannot be conformance-checked;
establish one"* (an unmeasured architecture is itself a finding, mirroring instrumentation-first).

## Fitness functions (the machine check)

A **fitness function** is an automated check that verifies the system still honors an architectural
decision — "unit tests for your architecture": unit tests ask *does this function return the right
value*, fitness functions ask *does this module still respect its boundaries*
([InfoQ](https://www.infoq.com/articles/fitness-functions-architecture/),
[automating governance](https://developersvoice.com/blog/architecture/architectural-fitness-functions-automating-governance/)).

Encode the baseline's forbidden edges as executable rules and run them per batch:

- Prefer the project's own arch-lint tool when present — **ArchUnit** (Java), **Deptrac** (PHP),
  **go-arch-lint** (Go), **dependency-cruiser** (JS/TS). [`../bin/check-architecture.sh`](../bin/check-architecture.sh)
  delegates to it if a config is detected.
- Otherwise apply the declared forbidden-import rules from the baseline as a conservative grep-level
  check.

## Timing (fast feedback vs. deep review)

Layer the checks ([automating governance](https://developersvoice.com/blog/architecture/architectural-fitness-functions-automating-governance/)):

| When | Check | Depth |
|---|---|---|
| **Phase A** (once, on `plan.md`) | soundness — is the *planned* architecture correct and does it fit the baseline? | reasoning gate before any batch |
| **Phase B** (per batch) | conformance — did this batch drift from the baseline? | fitness functions + review, hard gate |
| CI | full fitness-function suite | independent environment |

See [roles/architecture-reviewer.md](roles/architecture-reviewer.md) for the role that runs both.
