# ADR-0019 — Sizing reads what the spec says, not only which files it names

- Status: Accepted
- Date: 2026-08-25
- Milestone: `complexity-from-spec` (v2.34.0)
- Extends: [ADR-0018](0018-spec-sourced-role-plan.md)

## Context

ADR-0018 made the harness size a milestone from its spec. But the evaluator fed
`select-pipeline.sh` a list of **file paths**, so "evaluating the spec" meant counting files, counting
directories, and pattern-matching five risk categories against path names.

That is blind to what a milestone actually does. Demonstrated:

```
# Spec — distributed idempotency for the payout ledger
# Exactly-once payout settlement across three regions under partial network partition.
# Requires a consensus round and a reconciliation path for the split-brain case.
# Money movement is irreversible.

    → tier=single-thread     (two files, one directory)
```

Its `tasks.md` **already declared** `⚠ architecture-reviewer`, `⚠ regression-guardian` and
`⚠ tb-code-reviewer` — the author had said which reviewers the work needs — and the harness discarded
those too.

## Decision

Two signals are added, both **lift-only**.

1. **Prose complexity.** `spec.md` and `plan.md` are scanned for five vocabularies —
   security/auth · money/irreversible · data/schema · distributed/concurrency · infra/deploy. The
   distributed/concurrency category is the one no path pattern can ever express. A hit lifts the tier
   to `full` and is named in `reasons` as `prose:<category>`.
2. **Declared roles.** `⚠ <role>` markers in `tasks.md` are read and **unioned** into the required
   review set, per work-stream, through the existing `required_roles_for_batch` path.

Trust model for (2) is the one already established for `risk_rank` (ADR-0006): a self-declared marker
is forgeable, so it may **raise** the requirement and never lower it. Declaring `⚠ code-reviewer` on a
batch that touches `src/auth/` cannot shrink the full set the paths earned.

## What keyword matching costs, and the two false positives it produced

A vocabulary scan over prose over-provisions, and lift-only makes that safe but not free: if
everything lifts to `full`, sizing is as useless as it was before. Both false positives were found by
running the scan over this repository's own specs:

- **`ledger`** was in the money vocabulary and matched this plugin's own **batch ledger** three times.
  A domain-ambiguous word does not belong in a lift vocabulary. Removed.
- **Markdown headings** were being scanned, and the stock `plan.md` template ships
  `## Data / schema changes (if any)` and `## Migration shape (if applicable)` — so **every** milestone
  using the template tripped `prose:data`. Headings and `<angle-bracket placeholders>` are now stripped
  before matching; prose means what the author wrote.

Both are pinned by regression fixtures.

## Consequences

- The motivating spec now sizes `full` with all four roles, for the stated reasons
  (`prose:money prose:dist declared-roles`) rather than by accident.
- A genuinely small milestone is still light — the control fixture and the stock template both stay
  `single-thread`.
- **The residual limit is real:** this is vocabulary matching, not comprehension. A spec that describes
  something hard in words no list contains will still size on its paths alone. The `⚠ <role>` marker is
  the escape hatch, and it is now honoured — an author who knows the work is hard can say so and be
  obeyed.
