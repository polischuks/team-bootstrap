# Plan — <milestone-slug>

> Step 4 deliverable. Architecture + phase decomposition. Read the most recent completed
> plan in full and mirror its shape.

## Principles compliance matrix
| AC | Constitution clause | CI/QA binding |
|---|---|---|
| AC-1 | P<n> | <test or check> |

## Architecture
<sequence / dependency description or diagram>

## Phase decomposition
- **Phase 0** — <front gate; blocks all later work>
- **Phase 1** — <...>

Dependency DAG: <Phase 0 gates Phase 1; ...>

## Data / schema changes (if any)
<migration up + down; access-control posture per table>

## Contracts touched
<external routes / internal component contracts / registry impacts>

## ADR candidates
- <decision that outlives this milestone → docs/adr/NNNN-*.md>

## Migration shape (if applicable)
<split vs single; rollback isolation>
