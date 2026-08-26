#!/usr/bin/env bash
# session-context.sh — the invariants and the live run state, delivered where they are readable.
#
# THREE EVENTS, one job: keep what the model must not forget inside the window it can actually see.
#
#   SessionStart — the constitution's invariants land in the conversation at its start, via
#     additionalContext. They used to live only in constitution.md, i.e. only if someone read it, and
#     putting them in CLAUDE.md instead would spend that budget on every session forever.
#   PreCompact  — snapshot the active run's state to disk BEFORE the window is compacted.
#   PostCompact — re-state it afterwards. This is the gap the research doc names: the shared blackboard
#     is the project's whole T3 story and nothing protected it across a compaction. A run that survived
#     a compaction kept its FILES and lost the model's knowledge that any of it existed.
#
# Facts, never imperatives: additionalContext phrased as out-of-band instructions trips the
# prompt-injection defence and is shown to the user instead of accepted as context.
#
# Exit: always 0. None of these events should ever be a place a session can die.
set -uo pipefail
[ "${TEAM_BOOTSTRAP_DELIVERY_GATE:-on}" = "off" ] && exit 0
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/delivery-lib.sh
. "$here/delivery-lib.sh" 2>/dev/null || exit 0

EVENT="${1:-SessionStart}"

_invariants() {
  printf '%s' "team-bootstrap invariants in force (constitution.md): \
P1 single-thread by default, multi-role for audit. \
P3 policy is harness-enforced; the model is out of the security loop. \
P4 handoffs are typed and schema-validated. \
P5 irreversible actions are gated on explicit approval. \
P6 truth is reported; blocked outranks false-complete. \
P9 verification is red-to-green with evidence rather than assertion. \
P10 verification is cumulative and fail-closed. \
P11 claims are grounded in the mechanism, not the name."
}

# _run_state → a factual sentence about the ACTIVE run, or empty when none is armed.
_run_state() {
  local marker mk bline bid
  marker="$(resolve_marker 2>/dev/null || true)"
  [ -n "$marker" ] && [ -f "$marker" ] || return 0
  mk="$(cat "$marker" 2>/dev/null || true)"
  bline="$(inflight_batch 2>/dev/null || true)"; bid="$(field_str "$bline" id)"
  printf 'Active delivery run %s: pipeline=%s, review_depth=%s, intends_code=%s, marker=%s.%s' \
    "$(field_str "$mk" run)" "$(field_str "$mk" pipeline)" \
    "$(field_str "$mk" review_depth)" "$(field_bool "$mk" intends_code)" "$marker" \
    "${bid:+ In-flight batch $bid (status=$(field_str "$bline" status), kind=$(field_str "$bline" kind)); required roles: $(required_roles_recorded "$bid" 2>/dev/null || required_roles_for_batch "$bid" 2>/dev/null).}"
}

if [ "${1:-}" = "--self-test" ]; then
  fail=0
  _c() { if [ "$1" = "$2" ]; then echo "  PASS $3"; else echo "  FAIL $3 (got [$1] want [$2])" >&2; fail=$((fail + 1)); fi; }
  _c "$(_invariants | grep -c 'P3')" 1 "the invariants name the harness-enforcement principle"
  _c "$(_invariants | grep -ciE '\b(you must|do not|always |never )')" 0 "phrased as facts, not imperatives"
  _c "$( ( cd "$(mktemp -d)" || exit 1; _run_state ) )" "" "no armed run ⇒ no run-state sentence"
  [ "$fail" -eq 0 ] && { echo "session-context --self-test: OK"; exit 0; }
  echo "session-context --self-test: $fail FAILED" >&2; exit 1
fi

# Drain stdin only now: a hook that leaves its payload unread can wedge the writer, but reading it
# before the --self-test branch made the self-test itself block forever on a terminal.
cat >/dev/null 2>&1 || true

case "$EVENT" in
  PreCompact)
    # Persist, do not speak: the window is about to be discarded, so the durable copy is the point.
    marker="$(resolve_marker 2>/dev/null || true)"
    [ -n "$marker" ] && [ -f "$marker" ] || exit 0
    { _run_state; printf '\n'; } > "$(dirname "$marker")/precompact-state" 2>/dev/null || true
    exit 0
    ;;
  SessionStart|PostCompact)
    ctx="$(_invariants)"
    state="$(_run_state)"
    [ -n "$state" ] && ctx="$ctx $state"
    [ "$EVENT" = "PostCompact" ] && [ -z "$state" ] && exit 0   # nothing live ⇒ nothing to restate
    emit_hook_context "$EVENT" "$(json_esc "$ctx")"
    exit 0
    ;;
  *) exit 0 ;;
esac
