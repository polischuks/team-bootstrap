# Artifact schemas (l2p)

Exact shapes for each output file the `l2p` pipeline writes into `./l2p-artifacts/`. Keep ids stable across the run so citations resolve. Every downstream assertion must cite an id defined in `00-grounding.md` (enforced by [../../bin/check-citations.sh](../../bin/check-citations.sh) and the between-stage gate).

## 00-grounding.md
- `## claims[]` — table: id (C###) | verbatim | source | type | OBSERVED/CLAIMED
- `## surfaces[]` — table: id (S###) | where (landing/platform) | name | purpose | cta/next-action
- `## features[]` — table: id (F###) | capability | surface | status (observed/inferred/unverifiable)
- `## instrumentation[]` — table: id (I###) | event/metric | tool | surface | status (live/partial/missing)
- `## Unknowns` — bullet list: what couldn't be observed + access needed

## 01-use-cases.md
- `## personas[]` — table: id (P##) | name | job | evidence (ids) | confidence
- `## use-cases[]` — table: id (UC##) | persona | trigger | desired outcome | entry surface | expected path (S### list) | activation event | proof metric | priority (1-5) | justification
- Ordered by priority. Note any `PATH-BREAK`.

## 02-map.md
- `## trace[]` — table: promise (C###/S###, verbatim) | journey steps (S### list) | fulfillment (S###/F###) | status (matched/partial/missing/contradicted/dead-end) | note (UC##)
- `## overpromise[]` — missing/contradicted claims
- `## undersold[]` — features with no promise
- `## summary` — matched vs broken counts, worst UC##, top 3 mismatches

## 03-funnel-audit.md
- One `### <Stage>` block per funnel stage: intended action | entry/exit | friction inventory (tagged) | instrumentation status (I###) | drop-off hypotheses (with evidence) | cross-env checks
- `## findings[]` — table: id (FND##) | stage | description | evidence | Impact | Confidence | Ease | ICE — sorted by ICE desc

## 04-gates.md
- One `### <Gate>` block per gate: definition | entry criterion | qualifying criterion | current pass rate (I### or ESTIMATE) | failure modes (FND##) | instrumentation event | owner | highest-leverage fix
- `## Gate ledger` — table: gate | pass rate | biggest leak | recommended fix — sorted by leak size

## l2p-backlog.md (gap-backlog-author)
Each gap becomes a Phase-2 task consumable by `single-thread` / `mvp` / `full`:
- `id`: TASK-XXX
- `title`: short imperative
- `source`: the gap's origin (map status `missing`/`contradicted`/`dead-end`, `FND##`, or gate leak)
- `evidence`: grounding ids that justify it (C###/S###/F###/I###/FND##/UC##)
- `severity`: critical | high | medium | low
- `ice`: {impact, confidence, ease, score} — inherited from the source finding
- `acceptance_criteria`: how Phase 2 knows it's done
- `precedent`: pointer to the artifact + id chain the task derives from
- `recommended_pipeline`: `single-thread` | `mvp` | `full`
