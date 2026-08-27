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
    case "$mk" in
      *role_verdict_waiver*|*gate_integrity_waiver*) RUNS_WAIVED=$((RUNS_WAIVED + 1)) ;;
    esac
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

if [ "$JSON" -eq 1 ]; then
  printf '{"code_batches":%d,"recorded":%d,"enforce_share_pct":"%s","non_default":%d,"non_default_share_pct":"%s","live_role_bindings":"%s","code_runs":%d,"waived_runs":%d,"waived_share_pct":"%s"}\n' \
    "$TOTAL" "$RECORDED" "$(_pct "$RECORDED" "$TOTAL")" "$NONDEFAULT" "$(_pct "$NONDEFAULT" "$RECORDED")" "$LIVE" \
    "$RUNS_CODE" "$RUNS_WAIVED" "$(_pct "$RUNS_WAIVED" "$RUNS_CODE")"
  exit 0
fi
echo "delivery-metrics (read-only; from .runs/*/batches.jsonl)"
echo "  code batches seen ................. $TOTAL"
echo "  closed with a recorded role set ... $RECORDED  ($(_pct "$RECORDED" "$TOTAL")%)   <- target ~100%; lower = the per-role floor was unreachable"
echo "  assigned set != tier default ...... $NONDEFAULT  ($(_pct "$NONDEFAULT" "$RECORDED")%)   <- near 0 = the selector does not discriminate"
echo "  live role bindings ................ $LIVE  (eval-role.sh --liveness)"
echo "  code runs closed under a waiver ... $RUNS_WAIVED/$RUNS_CODE  ($(_pct "$RUNS_WAIVED" "$RUNS_CODE")%)   <- R2: a waiver is an event; a rising share means it became the posture"
exit 0
