# specs/

One directory per milestone, named `NNN-milestone-slug/` (zero-padded, monotonic).
Each is produced by the [pre-implementation flow](../references/speckit-preimpl-flow.md) and
consumed by team-bootstrap's pipelines.

## Convention

```
specs/
  NNN-milestone-slug/
    spec.md      — Step 2 (spec) + Step 3 (clarify resolutions inline)
    plan.md      — Step 4 (architecture, phases, compliance matrix)
    tasks.md     — Step 5 (numbered tasks, AC coverage, exit criteria)
    team-bootstrap-dispatches.md   — Step 6 (paste-ready dispatch blocks)  [optional until dispatch]
```

- Mirror structure from the most recent completed milestone (precedent chain).
- The active milestone is pointed to by [`../feature.json`](../feature.json) (`active_spec`).
- Version bumps and doctrine impact are decided in Step 1 against
  [`../constitution.md`](../constitution.md).

## Starting a milestone

1. Copy [`TEMPLATE/`](TEMPLATE/) to `NNN-milestone-slug/`.
2. Run Step 1 (constitution analysis) → record the version-bump verdict.
3. Fill `spec.md` → `plan.md` → `tasks.md` via the `speckit-*` skills.
4. Set `active_spec` in `feature.json`.

`TEMPLATE/` is scaffolding, not a milestone — pipelines ignore it.
