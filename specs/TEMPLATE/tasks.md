# Tasks — <milestone-slug>

> Step 5 deliverable. Every AC-N from spec.md maps to ≥1 task (grep-verify before commit).

- Status: <draft/active/done>
- Source plan: plan.md
- Source spec: spec.md
- Constitution version pin: 1.0.0
- Total tasks: <N>

## Conventions
`Txxx [P?] [USx?] Description` — `[P]` = parallelizable within phase; `[USx]` = ties to a
user story; suffix `(category · principle)`; each task cites `precedent: <SHA-or-marker>` and
its `AC-N`; add `⚠ <reviewer-type>` where a reviewer role must sign off.

## Front gates (block all subsequent work)
- [ ] T001 <hard gate>

## Phase 1
- [ ] T010 [P] [US1] <description>
  - file: <path>
  - (foundation · P<n>) — AC-1
  - precedent: <commit-sha OR memory-marker>

## Dependencies & parallelization
<within-phase lanes; critical seams>

## Risk register
| # | Risk | Mitigation |
|---|---|---|
| R1 | <risk> | <mitigation> |

## Exit criteria (release gate)
- [ ] All ACs mapped and satisfied
- [ ] Reviewer disposition: 0 unresolved CRITICAL/HIGH (release-manager gate)
- [ ] Eval gate green
