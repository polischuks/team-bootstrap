#!/usr/bin/env bash
# delivery-resize.sh — mid-turn degraded-sizing recompute (PostToolBatch hook). Issue #48.
#
# THE GAP THIS CLOSES. delivery-marker-init.sh recovers a run from its first (always-degraded,
# no-tasks-md) sizing — but only on UserPromptSubmit, i.e. on the NEXT prompt. Phase A -> Phase B
# routinely happens inside a SINGLE agentic turn: artefacts land, preflight runs, batches are
# announced, subagents are dispatched, all with no new user prompt. No prompt, no hook, no re-size —
# so the run stayed `pipeline=auto degraded=no-tasks-md`, `assigned_roles=[]`, with a fully sizable
# tasks.md on disk beside it (observed on run 176-withgauge-platform-integration).
#
# WHY PostToolBatch. The recompute is not prompt-shaped work: it is "a stored verdict has become false,
# recompute it", and the moment it becomes false is when the artefacts land — which the harness
# observes without a prompt. PostToolBatch fires after a tool batch resolves and before the model's
# next turn (the same event, and the same "first cheap moment", that check-review-batch.sh already
# relies on) — so it catches tasks.md landing mid-turn. It is NON-BLOCKING (exit 0): this hook only
# ever recomputes a verdict, never refuses a turn.
#
# WHY IT IS SAFE TO FIRE ON EVERY BATCH. resize_degraded_marker is idempotent: a successful re-size
# CLEARS sizing_degraded, so a later batch in the same turn is an immediate no-op that emits nothing
# and touches nothing (no thrash). A run that sized cleanly is never entered — a settled verdict is
# never re-decided. With no active run marker it no-ops, exactly like the other delivery hooks.
#
# The recompute itself is ONE definition, shared with the UserPromptSubmit path (delivery-lib.sh
# resize_degraded_marker) — the two triggers cannot drift.
#
# Exit: always 0 (non-blocking). STDOUT carries the RE-SIZED notice to the model on the PostToolBatch
# additionalContext channel, only in the one turn where it is news.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/delivery-lib.sh
. "$here/delivery-lib.sh" 2>/dev/null || exit 0   # cannot evaluate ⇒ absent, never a false re-size

# ---- self-test --------------------------------------------------------------
if [ "${1:-}" = "--self-test" ]; then
  fail=0
  # Hermetic: an outer session may pin TEAM_BOOTSTRAP_RUN, which resolve_marker honours over a fixture's
  # .runs/current. Clear it so these cases resolve the fixture run from disk.
  unset TEAM_BOOTSTRAP_RUN
  _c() { if [ "$1" = "$2" ]; then echo "  PASS $3"; else echo "  FAIL $3 (got [$1] want [$2])" >&2; fail=$((fail + 1)); fi; }
  T="$(mktemp -d)"
  # no armed run ⇒ silent, exit 0
  _c "$( ( cd "$T" || exit 1; printf '{}' | "$here/delivery-resize.sh" ); echo -n )" "" "no armed run ⇒ silent"
  _c "$( ( cd "$T" || exit 1; printf '{}' | "$here/delivery-resize.sh" >/dev/null 2>&1 ); echo $? )" 0 "…and exit 0"
  # a degraded run whose spec is now sizable ⇒ recompute to a real tier, no prompt involved
  mkdir -p "$T/specs/st"
  printf '# Spec\n\nAn auth change touching src/auth/login.ts.\n' > "$T/specs/st/spec.md"
  ( cd "$T" || exit 1; git init -q; git config user.email a@b.c; git config user.name t
    printf 'x\n' > seed.txt; git add -A; git commit -q -m base
    printf '%s' '/team-bootstrap:deliver specs/st' | "$here/delivery-marker-init.sh" >/dev/null 2>&1 )
  printf '# Tasks\n\n## WS-A\n\n- [ ] T1 a `src/auth/x.ts`\n' > "$T/specs/st/tasks.md"
  ( cd "$T" || exit 1; printf '{}' | "$here/delivery-resize.sh" >/dev/null 2>&1 )
  _c "$(field_str "$(cat "$T/.runs/st/RUN")" pipeline)" full "degraded run with artefacts now on disk ⇒ re-sized"
  _c "$(field_str "$(cat "$T/.runs/st/RUN")" sizing_degraded)" "" "…and the degradation is cleared (idempotent next time)"
  rm -rf "$T"
  [ "$fail" -eq 0 ] && { echo "delivery-resize --self-test: OK"; exit 0; }
  echo "delivery-resize --self-test: $fail case(s) FAILED" >&2; exit 1
fi

[ "${TEAM_BOOTSTRAP_DELIVERY_GATE:-on}" = "off" ] && exit 0
cat >/dev/null 2>&1 || true   # drain the PostToolBatch payload (unused — the run is resolved from disk)

marker="$(resolve_marker 2>/dev/null || true)"
# An AMBIGUOUS resolution (two runs tied on mtime, no .runs/current) is not a run to re-size — do not
# guess which. [ -f ] is false for the sentinel, so the check below also skips; the explicit test just
# names the reason. Fail-safe: an un-recomputed marker is the pre-existing (conservative) state.
marker_ambiguous "$marker" && exit 0
[ -n "$marker" ] && [ -f "$marker" ] || exit 0   # no armed run ⇒ out of scope
mk="$(cat "$marker" 2>/dev/null || true)"
[ "$(field_bool "$mk" intends_code)" = "true" ] || exit 0   # a doc run has no sizing to recover

run="$(field_str "$mk" run)"
# tier_source is the marker's own stored provenance — the re-size does not re-derive it (there is no
# prompt here to derive it from), it carries forward what the arming prompt recorded.
tier_source="$(field_str "$mk" tier_source)"; [ -n "$tier_source" ] || tier_source="harness"

_note="$(resize_degraded_marker "$marker" "$tier_source" "$run" 2>/dev/null || true)"
[ -n "$_note" ] && emit_hook_context PostToolBatch "$(json_esc "$_note")"
exit 0
