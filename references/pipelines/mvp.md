# MVP Pipeline

Run roles in this order:

1. `product-ba`
2. `delivery-manager`
3. `cto-architect`
4. `backend-engineer`
5. `frontend-engineer`
6. `integration-verifier` ← **outcome-based: E2E path runs + no orphans (dead code) — hard gate**
7. `architecture-reviewer` ← **conformance: batch stays within the app's architecture (no drift) — hard gate**
8. `qa-test-engineer`
9. `release-docs`

## Required Handoff Outputs

| Role | Must produce before next role |
| --- | --- |
| `product-ba` | brief, requirements, edge cases, next role |
| `delivery-manager` | plan, task breakdown, dependencies, next role |
| `cto-architect` | technical direction, constraints, contracts, next role |
| `backend-engineer` | implementation summary, changed files, validation results, next role |
| `frontend-engineer` | implementation summary, changed files, validation results, next role |
| `integration-verifier` | integration_verified, orphans_found (0 to pass), E2E evidence — **hard gate: cannot pass over dead code** |
| `architecture-reviewer` | conformance_verified, drift_findings (0 to pass) against the baseline — **hard gate: cannot pass over architectural drift** |
| `qa-test-engineer` | test results, defects, release risk summary, next role |
| `release-docs` | final release decision, evidence summary, blockers |

## Integration gate (hard)

Between `frontend-engineer` and `qa-test-engineer`, `integration-verifier` runs with a clean
context and verifies **outcomes, not self-reports**: it executes the E2E command from `AGENTS.md`
and scans for orphans (any endpoint/component the batch produced that has no live consumer). A
batch **cannot advance** while `orphans_found > 0` or the E2E path fails — the verifier emits
`blocked`, the orphan is sent back to the builder, and after 3–5 failed attempts the run stops
for human intervention / rollback. This is the fix for "backend built the endpoint, frontend
never called it, both reported done." See [../roles/integration-verifier.md](../roles/integration-verifier.md).

## Architecture conformance gate (hard)

After the integration gate, `architecture-reviewer` checks the batch against the app's
[architecture baseline](../architecture-baseline.md) — boundaries, layers, dependency directions —
using fitness functions ([../../bin/check-architecture.sh](../../bin/check-architecture.sh)). Passing
E2E is not enough: a batch can work and still **drift** (wrong layer, bypassed boundary). The batch
**cannot advance** while `drift_findings > 0`; drift goes back to the builder, 3–5 attempts → human
/ rollback. This catches architectural erosion that the integration gate can't see. See
[../roles/architecture-reviewer.md](../roles/architecture-reviewer.md).
