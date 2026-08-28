#!/usr/bin/env bash
# delivery-metrics.sh — the three numbers the roles-alive doc asks to measure, computed from the
# harness's own records rather than estimated.
#
#   1. Share of code batches whose ASSIGNED role set differs from the tier default.
#      Near zero after the selector lands means the selector does not discriminate and the profile
#      needs calibration — a routing layer that always returns the default is decoration.
#   2. Share of closed code batches that had a RECORDED role set (i.e. closed under mode=enforce).
#      Should be ~100%; anything lower is batches where required_roles never landed, and the per-role
#      floor was therefore unreachable for them.
#   3. Roles with a reddening eval — delegated to `eval-role.sh --liveness`, the only honest count.
#
# Read-only. Reports what the ledgers say and never writes, so it cannot flatter itself.
#
# Usage: bin/delivery-metrics.sh [run-dir|.]  ·  --json  ·  --self-test
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/delivery-lib.sh
. "$here/delivery-lib.sh"

_pct() { # $1=numerator $2=denominator → integer percent, or "n/a" when there is nothing to divide
  [ "${2:-0}" -gt 0 ] || { printf 'n/a'; return 0; }
  printf '%d' $(( $1 * 100 / $2 ))
}

# _scan_waivers → sets RUNS_CODE and RUNS_WAIVED: of the runs that closed at least one kind:code
# batch, how many did so under a governed waiver recorded in their marker.
#
# R2's own stated mitigation (spec 021 §8), and it had no task until T028. The risk R2 names is that
# `role_verdict_waiver` stops being an event and becomes the way batches close — and measured capture
# in this repo is 0 for 7 (plan §8.3), so that is the DEFAULT trajectory here, not a tail case. A
# number nobody computes is a mitigation nobody has. This one is computed from the markers themselves,
# so it cannot be talked up.
#
# The denominator is RUNS, matching the waivers scope (OQ-2: run-scoped, because a per-batch waiver
# invites one per batch). A run that closed no code batch is not counted either way — it was never in
# a position to need one.
_scan_waivers() {
  RUNS_CODE=0; RUNS_WAIVED=0
  local d mk
  for d in .runs/*/; do
    [ -f "$d/batches.jsonl" ] || continue
    grep -q '"kind":[[:space:]]*"code"' "$d/batches.jsonl" 2>/dev/null || continue
    RUNS_CODE=$((RUNS_CODE + 1))
    [ -f "$d/RUN" ] || continue
    mk="$(cat "$d/RUN" 2>/dev/null || true)"
    # A run counts as waived only if a waiver is actually EFFECTIVE — the same governed_waiver_ok the
    # gates read with. A bare substring match would count an expired (ineffective) waiver, or the key
    # merely appearing inside a reason string, and inflate the very number R2 watches. Undated markers
    # (the metric has no "now") use the stored expires against today, exactly as the gate would.
    for _w in role_verdict_waiver gate_integrity_waiver; do
      if governed_waiver_ok \
           "$(field_in_obj "$mk" "$_w" ack)" \
           "$(field_in_obj "$mk" "$_w" by)" \
           "$(field_in_obj "$mk" "$_w" reason)" \
           "$(field_in_obj "$mk" "$_w" expires)"; then
        RUNS_WAIVED=$((RUNS_WAIVED + 1)); break
      fi
    done
  done
}

_scan() { # sets: TOTAL RECORDED NONDEFAULT
  TOTAL=0; RECORDED=0; NONDEFAULT=0
  local d line bid rec sized tier base
  for d in .runs/*/; do
    [ -f "$d/batches.jsonl" ] || continue
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      [ "$(field_str "$line" kind)" = "code" ] || continue
      TOTAL=$((TOTAL + 1))
      rec="$(printf '%s' "$line" | grep -o '"required_roles":\[[^]]*\]' || true)"
      [ -n "$rec" ] || continue
      RECORDED=$((RECORDED + 1))
      # non-default = the recorded set names a role the blanket tier default would not have produced
      sized="$(printf '%s' "$rec" | tr -d '[]"' | sed 's/required_roles://; s/,/ /g')"
      for base in $sized; do
        case " integration-verifier architecture-reviewer regression-guardian code-reviewer " in
          *" $base "*) : ;;
          *) NONDEFAULT=$((NONDEFAULT + 1)); break ;;
        esac
      done
    done < "$d/batches.jsonl"
  done
}

# --- wall-time attribution (issue #61) -----------------------------------------
# Turns the two honest wall-clock facts the hooks record — dispatch `ts` (record-dispatch, per review
# role) and batch `closed_at` (verify-batch, per batch) — into per-batch and per-role wall-time, so a
# 1.1M-token/3h46m run can be ATTRIBUTED to where the time went. What is NOT here is TOKENS: a bash hook
# cannot see per-subagent token usage (that is the harness's, not the plugin's — see delivery-lib's #61
# note), so this reports wall-time only and says so, rather than fabricating a token split.
#
# HONEST LIMITS carried in the output itself:
#   - Per-batch wall-time = closed_at[N] - closed_at[N-1]; the FIRST batch is measured from the run's
#     earliest recorded activity (min ts / closed_at), which UNDER-counts any implementation done before
#     the first recorded event. Labelled "from first recorded activity".
#   - "review-window" is the wall-clock span from a batch's first to its last review DISPATCH. Reviews
#     run background/parallel and their COMPLETION is not observed (#60), so this is a span, not additive
#     reviewer time, and it has no matching per-role end — per role we can report WHEN each was dispatched
#     and how often, never how long it ran.

_hms() { # SECS → "Xm Ys" (or "Ys" under a minute); non-numeric/negative → "?"
  local s="${1:-}"
  case "$s" in ''|*[!0-9-]*) printf '?'; return 0 ;; esac
  [ "$s" -lt 0 ] && { printf '?'; return 0; }
  if [ "$s" -ge 60 ]; then printf '%dm %ds' "$((s / 60))" "$((s % 60))"; else printf '%ds' "$s"; fi
}

# _emit_timing MODE DIR  (MODE = human | json) → per-run wall-time for the single run rooted at DIR.
# Prints nothing when the run has no timing to report (no closed_at and no dispatch ts). In json mode it
# prints exactly one object with NO trailing comma; the caller joins objects.
_emit_timing() {
  local mode="$1" d="$2" bfile="$2/batches.jsonl" dfile="$2/dispatch.jsonl"
  local runid; runid="$(basename "$d")"
  [ -f "$bfile" ] || return 0

  # earliest recorded activity across BOTH ledgers = run t0.
  local t0="" v line
  if [ -f "$dfile" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      v="$(field_num "$line" ts)"; [ -n "$v" ] || continue
      { [ -z "$t0" ] || [ "$v" -lt "$t0" ]; } && t0="$v"
    done < "$dfile"
  fi
  # closed code batches, in close (file) order.
  local ids="" closes="" last_close=""
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    [ "$(field_str "$line" kind)" = "code" ] || continue
    v="$(field_num "$line" closed_at)"; [ -n "$v" ] || continue
    ids="$ids $(field_str "$line" id)"; closes="$closes $v"; last_close="$v"
    { [ -z "$t0" ] || [ "$v" -lt "$t0" ]; } && t0="$v"
  done < "$bfile"
  [ -n "$t0" ] || return 0                      # nothing timed at all
  local total=""; [ -n "$last_close" ] && total="$((last_close - t0))"

  # per-role tallies (subagent_type → attributed role) across the run.
  local roles_seen="" role
  if [ -f "$dfile" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      role="$(role_of_slug "$(field_str "$line" subagent_type)")"
      [ -n "$role" ] || role="$(field_str "$line" subagent_type)"
      [ -n "$role" ] && roles_seen="$roles_seen $role"
    done < "$dfile"
  fi

  if [ "$mode" = "human" ]; then
    printf '    run %s: total %ss (%s) from first recorded activity\n' "$runid" "$total" "$(_hms "$total")"
    local prev="$t0" id cl bid n mn mx
    # zip ids+closes positionally
    set -- $closes
    for id in $ids; do
      cl="$1"; shift
      # review window for this batch
      n=0; mn=""; mx=""
      if [ -f "$dfile" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
          [ -n "$line" ] || continue
          [ "$(field_str "$line" batch)" = "$id" ] || continue
          v="$(field_num "$line" ts)"; [ -n "$v" ] || continue
          n=$((n + 1))
          { [ -z "$mn" ] || [ "$v" -lt "$mn" ]; } && mn="$v"
          { [ -z "$mx" ] || [ "$v" -gt "$mx" ]; } && mx="$v"
        done < "$dfile"
      fi
      local win=0; [ -n "$mn" ] && [ -n "$mx" ] && win="$((mx - mn))"
      printf '      batch %-6s wall %ss (%s)  review-window %ss over %d dispatch(es)\n' \
        "$id" "$((cl - prev))" "$(_hms "$((cl - prev))")" "$win" "$n"
      prev="$cl"
    done
    for role in $(printf '%s\n' $roles_seen | sort -u); do
      n="$(printf '%s\n' $roles_seen | grep -cxF -e "$role" || true)"
      mn=""; mx=""
      while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$line" ] || continue
        r2="$(role_of_slug "$(field_str "$line" subagent_type)")"; [ -n "$r2" ] || r2="$(field_str "$line" subagent_type)"
        [ "$r2" = "$role" ] || continue
        v="$(field_num "$line" ts)"; [ -n "$v" ] || continue
        { [ -z "$mn" ] || [ "$v" -lt "$mn" ]; } && mn="$v"
        { [ -z "$mx" ] || [ "$v" -gt "$mx" ]; } && mx="$v"
      done < "$dfile"
      printf '      role %-24s %s dispatch(es)  first@%s last@%s\n' "$role" "$n" "${mn:-n/a}" "${mx:-n/a}"
    done
    return 0
  fi

  # json mode — one object, no trailing comma.
  local bj="" prev="$t0" id cl n mn mx first=1
  set -- $closes
  for id in $ids; do
    cl="$1"; shift
    n=0; mn=""; mx=""
    if [ -f "$dfile" ]; then
      while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$line" ] || continue
        [ "$(field_str "$line" batch)" = "$id" ] || continue
        v="$(field_num "$line" ts)"; [ -n "$v" ] || continue
        n=$((n + 1))
        { [ -z "$mn" ] || [ "$v" -lt "$mn" ]; } && mn="$v"
        { [ -z "$mx" ] || [ "$v" -gt "$mx" ]; } && mx="$v"
      done < "$dfile"
    fi
    local win=0; [ -n "$mn" ] && [ -n "$mx" ] && win="$((mx - mn))"
    [ "$first" -eq 1 ] || bj="$bj,"; first=0
    bj="$bj{\"id\":\"$id\",\"wall_s\":$((cl - prev)),\"review_window_s\":$win,\"dispatches\":$n}"
    prev="$cl"
  done
  local rj="" r2; first=1
  for role in $(printf '%s\n' $roles_seen | sort -u); do
    n="$(printf '%s\n' $roles_seen | grep -cxF -e "$role" || true)"
    mn=""; mx=""
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      r2="$(role_of_slug "$(field_str "$line" subagent_type)")"; [ -n "$r2" ] || r2="$(field_str "$line" subagent_type)"
      [ "$r2" = "$role" ] || continue
      v="$(field_num "$line" ts)"; [ -n "$v" ] || continue
      { [ -z "$mn" ] || [ "$v" -lt "$mn" ]; } && mn="$v"
      { [ -z "$mx" ] || [ "$v" -gt "$mx" ]; } && mx="$v"
    done < "$dfile"
    [ "$first" -eq 1 ] || rj="$rj,"; first=0
    rj="$rj{\"role\":\"$role\",\"dispatches\":$n,\"first_ts\":${mn:-null},\"last_ts\":${mx:-null}}"
  done
  printf '{"run":"%s","total_wall_s":%s,"tokens":null,"batches":[%s],"roles":[%s]}' \
    "$runid" "${total:-null}" "$bj" "$rj"
  return 0
}

# _timing_runs → the run dirs to report timing for, newest first, capped. Read-only.
_timing_runs() {
  local d
  for d in $(ls -dt .runs/*/ 2>/dev/null); do
    [ -d "$d" ] || continue
    printf '%s\n' "${d%/}"
  done
}

if [ "${1:-}" = "--self-test" ]; then
  fail=0
  _c() { if [ "$1" = "$2" ]; then echo "  PASS $3"; else echo "  FAIL $3 (got [$1] want [$2])" >&2; fail=$((fail + 1)); fi; }
  _c "$(_pct 1 2)" "50" "percentages divide"
  _c "$(_pct 3 0)" "n/a" "an empty denominator is n/a, never a flattering 100"
  _c "$(_pct 0 4)" "0" "zero is reported as zero"
  T="$(mktemp -d)"
  ( cd "$T" || exit 1; mkdir -p .runs/r
    printf '%s\n' '{"id":"B1","kind":"code","required_roles":["code-reviewer","security-reviewer"]}' >> .runs/r/batches.jsonl
    printf '%s\n' '{"id":"B2","kind":"code","required_roles":["code-reviewer"]}' >> .runs/r/batches.jsonl
    printf '%s\n' '{"id":"B3","kind":"code"}' >> .runs/r/batches.jsonl
    printf '%s\n' '{"id":"D1","kind":"doc"}' >> .runs/r/batches.jsonl
    . "$here/delivery-lib.sh"; _scan; printf '%s %s %s\n' "$TOTAL" "$RECORDED" "$NONDEFAULT" ) > "$T/out" 2>/dev/null
  read -r t r n < "$T/out"
  _c "$t" "3" "doc batches are excluded from the denominator"
  _c "$r" "2" "batches without required_roles count as NOT recorded"
  _c "$n" "1" "only a set naming a non-default role counts as non-default"
  # T028 — the waiver share. A run with no code batch is outside the denominator entirely; a code run
  # with no waiver is in the denominator and not the numerator; a waived one is in both.
  ( cd "$T" || exit 1; mkdir -p .runs/w .runs/nocode
    printf '%s\n' '{"id":"B1","kind":"code"}' > .runs/w/batches.jsonl
    printf '%s\n' '{"run":"w","role_verdict_waiver":{"ack":true,"by":"f","reason":"r","expires":"2099-01-01"}}' > .runs/w/RUN
    printf '%s\n' '{"id":"D1","kind":"doc"}' > .runs/nocode/batches.jsonl
    printf '%s\n' '{"run":"nocode","gate_integrity_waiver":{"ack":true,"by":"f","reason":"r","expires":"2099-01-01"}}' > .runs/nocode/RUN
    . "$here/delivery-lib.sh"; _scan_waivers; printf '%s %s\n' "$RUNS_CODE" "$RUNS_WAIVED" ) > "$T/wout" 2>/dev/null
  read -r rc rw < "$T/wout"
  _c "$rc" "2" "the waiver denominator counts runs that closed a code batch (r and w, not the doc-only run)"
  _c "$rw" "1" "a waiver on a run that closed no code batch does not inflate the numerator"
  rm -rf "$T"
  [ "$fail" -eq 0 ] && { echo "delivery-metrics --self-test: OK"; exit 0; }
  echo "delivery-metrics --self-test: $fail FAILED" >&2; exit 1
fi

JSON=0; [ "${1:-}" = "--json" ] && { JSON=1; shift; }
# Same reasoning as check-role-verdict's --gate: an unreachable directory must not silently become
# "report metrics for wherever I happen to be".
if [ -n "${1:-}" ]; then
  cd "$1" 2>/dev/null || { echo "delivery-metrics: bad project dir '$1'" >&2; exit 64; }
fi

_scan
_scan_waivers
LIVE="$("$here/eval-role.sh" --liveness 2>/dev/null | sed -n 's/.*: \([0-9]*\)\/\([0-9]*\) assignable.*/\1\/\2/p' | tail -1)"
[ -n "$LIVE" ] || LIVE="unknown"

# wall-time attribution across the runs that carry timing (issue #61), newest first.
TIMING_JSON="["; _tsep=""; _tobj=""
while IFS= read -r _trun; do
  [ -n "$_trun" ] || continue
  _tobj="$(_emit_timing json "$_trun")"
  [ -n "$_tobj" ] || continue
  TIMING_JSON="$TIMING_JSON$_tsep$_tobj"; _tsep=","
done <<EOF
$(_timing_runs)
EOF
TIMING_JSON="$TIMING_JSON]"

if [ "$JSON" -eq 1 ]; then
  printf '{"code_batches":%d,"recorded":%d,"enforce_share_pct":"%s","non_default":%d,"non_default_share_pct":"%s","live_role_bindings":"%s","code_runs":%d,"waived_runs":%d,"waived_share_pct":"%s","timing":%s,"tokens_available":false}\n' \
    "$TOTAL" "$RECORDED" "$(_pct "$RECORDED" "$TOTAL")" "$NONDEFAULT" "$(_pct "$NONDEFAULT" "$RECORDED")" "$LIVE" \
    "$RUNS_CODE" "$RUNS_WAIVED" "$(_pct "$RUNS_WAIVED" "$RUNS_CODE")" "$TIMING_JSON"
  exit 0
fi
echo "delivery-metrics (read-only; from .runs/*/batches.jsonl)"
echo "  code batches seen ................. $TOTAL"
echo "  closed with a recorded role set ... $RECORDED  ($(_pct "$RECORDED" "$TOTAL")%)   <- target ~100%; lower = the per-role floor was unreachable"
echo "  assigned set != tier default ...... $NONDEFAULT  ($(_pct "$NONDEFAULT" "$RECORDED")%)   <- near 0 = the selector does not discriminate"
echo "  live role bindings ................ $LIVE  (eval-role.sh --liveness)"
echo "  code runs closed under a waiver ... $RUNS_WAIVED/$RUNS_CODE  ($(_pct "$RUNS_WAIVED" "$RUNS_CODE")%)   <- R2: a waiver is an event; a rising share means it became the posture"
# issue #61 — per-batch / per-role wall-time. Tokens are the harness's, not the plugin's, so they are
# NOT here; a bash hook never sees per-subagent token usage (delivery-lib #61 note). This is the honest
# half: where the WALL-CLOCK went. Printed newest run first, only for runs that carry timing.
_any_timing=0
while IFS= read -r _trun; do
  [ -n "$_trun" ] || continue
  _thuman="$(_emit_timing human "$_trun")"
  [ -n "$_thuman" ] || continue
  if [ "$_any_timing" -eq 0 ]; then
    echo "  wall-time (issue #61; per run — tokens NOT recorded: per-subagent token usage is the harness's, not a bash hook's):"
    _any_timing=1
  fi
  printf '%s\n' "$_thuman"
done <<EOF
$(_timing_runs)
EOF
[ "$_any_timing" -eq 0 ] && echo "  wall-time .......................... none recorded yet (needs closed_at on batches / ts on dispatches; accrues as runs close on this version)"
exit 0
