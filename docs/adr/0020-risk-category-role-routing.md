# ADR-0020 — The tier decides depth; the risk category decides composition

**Status:** accepted · **Date:** 2026-08-25 · **Supersedes in part:** [ADR-0017](0017-harness-owned-pipeline-sizing.md)

## Context

`required_roles_for_batch` derived the whole review set from one tier word, through a hardcoded
three-branch `case`:

```
full) integration-verifier architecture-reviewer regression-guardian code-reviewer
mvp)  integration-verifier code-reviewer
*)    code-reviewer
```

So the tier decided **both** composition and depth. Two consequences followed, and both were visible in
the repository rather than hypothetical:

**The classifier's own signal was discarded.** `bin/select-pipeline.sh` computes five risk categories —
`security/auth`, `data/schema`, `infra/deploy`, `api/contract`, `deps` — and emits them into a
`(reasons: …)` string. Nothing consumed them for role selection. Five computed facts collapsed into one
tier word.

**47 of 51 roles were unreachable.** A role is dispatchable only if `agents/<slug>.md` exists — that is
what lets it carry a `subagent_type`, which is what `bin/record-dispatch.sh` observes. There were 51
playbooks and 5 agent definitions. `references/roles/security-reviewer.md` is 150 lines that, to the
machine, described nothing that could run. The schema was ready for it —
`role-output.schema.json` already **requires** `severity_counts` and `secrets_audit_passed` from
`security-reviewer` — but no path existed to produce that output.

Three hardcoded tiers were the symptom people noticed. The cause was that composition had no input
other than the tier.

## Decision

**Composition comes from risk categories; depth stays with the tier.**

`profiles/default.map` maps a category to the roles it makes mandatory. `profile_roles_for_batch` reads
the categories from `select-pipeline.sh`'s own `(reasons: …)` line — the same computation that sizes the
tier, so composition and depth cannot disagree about what the diff contains — and unions the result into
the tier-derived base set.

This is the Spec Kit **preset** model: a profile overrides the mapping and adds no capability. An
organisation ships its own file (`$TEAM_BOOTSTRAP_PROFILE`) and leaves the core untouched.

Three properties are load-bearing and tested:

- **Add-only.** The map is unioned into the base set. A profile can never shrink a set the paths already
  earned, and the ≥1 independent-reviewer anti-collapse floor is never sized away. Same one-directional
  discipline as [ADR-0018](0018-spec-sourced-role-plan.md), applied to a second signal source.
- **No dead entries.** Every role named must have an `agents/<slug>.md` (or it cannot be dispatched), a
  role column in `references/review-types.txt` in **both** slug forms (or the dispatch is not
  attributed), and a required verdict field in the schema (or it cannot be confirmed at closure).
- **No dead keys.** Every category key must be one `select-pipeline.sh` actually emits.

First wave: `security/auth` → `security-reviewer`; `data/schema` → `data-schema-reviewer`;
`api/contract` → `integration-verifier`; `deps` → `security-reviewer` + `overengineering-reviewer`.

## What we deliberately did not do

**`infra/deploy` is left unmapped.** Its natural owner is `chaos-engineer`, whose schema definition
declares **no required field**. Assigning it would buy a dispatch and no confirmation — a role that
cannot be confirmed at closure is not alive, it is a decoy that satisfies a count. Giving it one is a new
required handoff field, which is a **major** bump under [versioning](../../references/versioning.md).
That is a decision to take deliberately, not a detail to slip into a routing change.

**Builder roles are not routed.** `references/review-types.txt` carries an anti-builder invariant — a
builder must never satisfy a review floor — and it is now asserted by test across every attributed role,
not merely stated in a comment.

## Consequences

- The five risk categories acquire an addressee. A batch touching `src/auth/` now *requires*
  `security-reviewer`, and under the v2.35.0 enforce path it cannot close without it.
- Review cost rises on exactly the batches that earned it, and nowhere else. An ordinary batch is
  unaffected: no category trips, the map contributes nothing.
- Reaching the remaining roles is now configuration rather than code. The three-position tier stops being
  a ceiling on composition.
- The honest limit is unchanged: `subagent_type` is model-authored, so this raises the **degradation**
  floor, not the **forgery** bar ([ADR-0008](0008-harness-verified-role-execution.md)).
