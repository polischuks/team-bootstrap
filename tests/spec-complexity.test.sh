#!/usr/bin/env bash
# spec-complexity.test.sh — the harness must judge COMPLEXITY, not just count files.
#
# v2.33.x sized a milestone from the PATHS its tasks name: file count, layer count, and five
# path-pattern risk categories. That is blind to everything a spec actually says. A milestone about
# exactly-once distributed payout settlement — consensus, split-brain reconciliation, irreversible
# money movement — sized to `single-thread`, because it touched two files in one directory.
#
# Two signals were being ignored, and this suite pins both:
#   1. the spec's own PROSE (spec.md/plan.md), where the hard part is actually described
#   2. the `⚠ <role>` markers the task author already wrote, declaring which reviewers a task needs
#
# Both are LIFT-ONLY. Precedent: risk_rank in the batch ledger is likewise self-declared and likewise
# one-directional (select-pipeline _batch_risk_floor, ADR-0006) — a declaration can buy extra review,
# never skip required review.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
FAILF="$(mktemp)"; printf '0' > "$FAILF"
_chk() { if [ "$1" = "$2" ]; then printf '  PASS %s\n' "$3"
  else printf '  FAIL %s (got [%s] want [%s])\n' "$3" "$1" "$2"
       printf '%s' "$(( $(cat "$FAILF") + 1 ))" > "$FAILF"; fi; }
_tier()  { printf '%s\n' "$1" | sed -n 's/^tier=//p' | head -1; }
_roles() { printf '%s\n' "$1" | sed -n 's/^roles=//p' | head -1; }

# _spec DIR OVERVIEW TASKS — a milestone whose PATHS are deliberately boring, so any escalation can
# only have come from the prose or the declared markers.
_spec() {
  mkdir -p "$1"
  printf '# Spec — fixture\n\n## Overview\n%s\n\n## Acceptance criteria\n- **AC-1** — a thing.\n' "$2" > "$1/spec.md"
  printf '# Plan — fixture\n\n## Architecture\nStraightforward.\n' > "$1/plan.md"
  printf '# Tasks — fixture\n\n- Total tasks: 2\n\n## Phase 1 — WS-1: the work\n%s\n' "$3" > "$1/tasks.md"
}
PLAIN='- [ ] T010 Do the thing.
  - file: lib/thing.ts · (feat · P5) — AC-1'

echo "the control: boring prose + boring paths stays light"
T="$(mktemp -d)"; ( cd "$T" || exit 1
  _spec specs/m 'Rename a helper and update its callers.' "$PLAIN"
  o="$("$here/bin/size-from-spec.sh" specs/m 2>/dev/null || true)"
  _chk "$(_tier "$o")" "single-thread" "a genuinely small milestone is not inflated" )
rm -rf "$T"

echo
echo "PROSE complexity lifts the tier, with boring paths throughout:"
for c in "consensus:Exactly-once settlement across regions under a network partition, via a consensus round." \
         "concurrency:A lock-free queue with a documented race between the producer and the reaper." \
         "money:Irreversible payout movement against the customer ledger; refunds are compensating entries." \
         "migration:A backfill that rewrites every historical row, then a schema migration to drop the old column." \
         "auth:Session tokens gain a scope claim; every existing credential must keep validating."; do
  name="${c%%:*}"; text="${c#*:}"
  T="$(mktemp -d)"; ( cd "$T" || exit 1
    _spec specs/m "$text" "$PLAIN"
    o="$("$here/bin/size-from-spec.sh" specs/m 2>/dev/null || true)"
    t="$(_tier "$o")"
    _chk "$([ "$t" = "single-thread" ] || [ -z "$t" ] && echo not-lifted || echo lifted)" "lifted" \
         "'${name}' prose lifts the tier (got ${t:-<none>})" )
  rm -rf "$T"
done

echo
echo "the author's own \`⚠ <role>\` markers are a role floor:"
T="$(mktemp -d)"; ( cd "$T" || exit 1
  _spec specs/m 'Rename a helper.' '- [ ] T010 Do it.
  - file: lib/thing.ts · (feat · P5) — AC-1 · ⚠ architecture-reviewer
- [ ] T011 And this.
  - file: lib/thing.ts · (test · P9) — AC-1 · ⚠ regression-guardian'
  o="$("$here/bin/size-from-spec.sh" specs/m 2>/dev/null || true)"
  r="$(_roles "$o")"
  _chk "$(printf '%s' "$r" | grep -cw architecture-reviewer)" "1" "a declared architecture-reviewer is carried"
  _chk "$(printf '%s' "$r" | grep -cw regression-guardian)"  "1" "…and a declared regression-guardian too"
  _chk "$(printf '%s' "$r" | grep -cw code-reviewer)"        "1" "…and the >=1 reviewer invariant still holds" )
rm -rf "$T"

echo
echo "declarations are ONE-DIRECTIONAL (they buy review, never skip it):"
T="$(mktemp -d)"; ( cd "$T" || exit 1
  # Paths alone already demand the full set (auth). A task declaring only code-reviewer must not
  # shrink that — a self-declared marker that could LOWER the floor would be a forgeable bypass.
  _spec specs/m 'Ordinary work.' '- [ ] T010 Touch auth.
  - file: src/auth/login.ts · (feat · P5) — AC-1 · ⚠ code-reviewer'
  o="$("$here/bin/size-from-spec.sh" specs/m 2>/dev/null || true)"
  _chk "$(_tier "$o")" "full" "a path-derived full tier is not lowered by a narrower declaration"
  r="$(_roles "$o")"
  _chk "$(printf '%s' "$r" | grep -cw integration-verifier)" "1" "…and the full role set survives it" )
rm -rf "$T"

echo
echo "the per-work-stream view carries roles too:"
T="$(mktemp -d)"; ( cd "$T" || exit 1
  mkdir -p specs/m
  printf '# Spec\n\n## Overview\nOrdinary.\n' > specs/m/spec.md; printf '# Plan\n' > specs/m/plan.md
  cat > specs/m/tasks.md <<'EOT'
# Tasks

## Phase 1 — WS-1: docs
- [ ] T010 Write it.
  - file: docs/guide.md · (docs · P10) — AC-1

## Phase 2 — WS-2: the hard part
- [ ] T020 Do it.
  - file: lib/thing.ts · (feat · P5) — AC-1 · ⚠ architecture-reviewer
EOT
  o="$("$here/bin/size-from-spec.sh" --per-batch specs/m 2>/dev/null || true)"
  _chk "$(printf '%s\n' "$o" | sed -n '2s/.*roles=\(.*\)$/\1/p' | grep -cw architecture-reviewer)" "1" \
       "WS-2's declared reviewer reaches the per-work-stream plan"
  _chk "$(printf '%s\n' "$o" | sed -n '1s/.*[[:space:]]tier=\([a-z-]*\).*/\1/p')" "single-thread" \
       "…and the docs work-stream stays light" )
rm -rf "$T"

echo
echo "template scaffolding must not lift anything (regression):"

# The stock plan.md ships `## Data / schema changes (if any)` and `## Migration shape (if applicable)`.
# Scanning headings meant EVERY milestone using the template tripped prose:data and became `full` —
# which would make the whole sizing exercise pointless. Prose means what the author wrote.
T="$(mktemp -d)"; ( cd "$T" || exit 1
  mkdir -p specs/m
  printf '# Spec\n\n## Overview\nRename a helper.\n' > specs/m/spec.md
  cp "$here/specs/TEMPLATE/plan.md" specs/m/plan.md 2>/dev/null \
    || printf '# Plan\n\n## Data / schema changes (if any)\n\n## Migration shape (if applicable)\n' > specs/m/plan.md
  printf '# Tasks\n\n- [ ] T010 Do it.\n  - file: lib/thing.ts · (feat · P5) — AC-1\n' > specs/m/tasks.md
  o="$("$here/bin/size-from-spec.sh" specs/m 2>/dev/null || true)"
  _chk "$(_tier "$o")" "single-thread" "the stock plan.md template does not lift a light milestone"
  _chk "$(printf '%s\n' "$o" | sed -n 's/^reasons=//p' | grep -c 'prose:' || true)" "0" \
       "…and trips no prose category at all" )
rm -rf "$T"

# `ledger` was in the money vocabulary and matched this plugin's own BATCH ledger three times in
# specs/review-loop-escalation — a domain term, not money. Domain-ambiguous words do not belong in a
# lift vocabulary, however lift-only it is: everything becoming `full` is the same failure as nothing
# escalating.
T="$(mktemp -d)"; ( cd "$T" || exit 1
  _spec specs/m 'The batch ledger records each entry; the ledger is append-only.' "$PLAIN"
  o="$("$here/bin/size-from-spec.sh" specs/m 2>/dev/null || true)"
  _chk "$(_tier "$o")" "single-thread" "'ledger' alone (this repo's batch ledger) does not mean money" )
rm -rf "$T"

echo
echo "end-to-end: a declaration must reach the ENFORCEMENT path, not just the script's output:"

# size-from-spec printing roles= proves nothing on its own. What matters is required_roles_for_batch —
# the function check-role-dispatch and check-review-ack actually gate on.
T="$(mktemp -d)"; ( cd "$T" || exit 1; git init -q; git config user.email a@b.c; git config user.name t
  git commit -q --allow-empty -m base
  mkdir -p .runs/r lib
  # The batch's own diff is one benign file, so the diff alone sizes it single-thread → code-reviewer.
  # The plan carries the author's declared architecture-reviewer for this work-stream.
  printf '{"run":"r","pipeline":"mvp","source":"harness","intends_code":true,"spec_present":true,"role_plan":[{"ws":"WS-1","tier":"single-thread","roles":"code-reviewer architecture-reviewer","paths":"lib/thing.ts"}]}\n' > .runs/r/RUN
  printf 'r\n' > .runs/current
  printf 'x\n' > lib/thing.ts; git add -A; git commit -q -m b1
  printf '{"id":"B1","kind":"code","status":"announced","base":"%s"}\n' "$(git rev-parse HEAD~1)" > .runs/r/batches.jsonl
  got="$( . "$here/bin/delivery-lib.sh"; TEAM_BOOTSTRAP_RUN=r required_roles_for_batch B1 )"
  _chk "$(printf '%s' "$got" | grep -cw architecture-reviewer)" "1" \
       "a declared architecture-reviewer is REQUIRED of the batch, not merely reported"
  _chk "$(printf '%s' "$got" | grep -cw code-reviewer)" "1" "…alongside the invariant floor" )
rm -rf "$T"

# And the doc-batch exemption is not disturbed by any of this.
T="$(mktemp -d)"; ( cd "$T" || exit 1; git init -q; git config user.email a@b.c; git config user.name t
  git commit -q --allow-empty -m base
  mkdir -p .runs/r
  printf '{"run":"r","pipeline":"mvp","source":"harness","intends_code":true,"role_plan":[{"ws":"WS-1","tier":"full","roles":"architecture-reviewer","paths":"docs/x.md"}]}\n' > .runs/r/RUN
  printf 'r\n' > .runs/current
  printf '{"id":"B9","kind":"doc","status":"announced"}\n' > .runs/r/batches.jsonl
  got="$( . "$here/bin/delivery-lib.sh"; TEAM_BOOTSTRAP_RUN=r required_roles_for_batch B9 )"
  _chk "$(printf '%s' "$got" | tr -d ' \n')" "" "a kind:doc batch still earns no review role" )
rm -rf "$T"

fail="$(cat "$FAILF")"; rm -f "$FAILF"
[ "$fail" -eq 0 ] && { echo "spec-complexity.test.sh: OK"; exit 0; }
echo "spec-complexity.test.sh: $fail failure(s)"; exit 1
