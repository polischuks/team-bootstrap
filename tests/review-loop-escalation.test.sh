#!/usr/bin/env bash
# review-loop-escalation.test.sh — surface a review loop before it eats the budget (issue #22).
#
# Observed: one milestone spent 6 architecture-review rounds in Phase A with ZERO closed batches
# (~900k tokens, no code), then a single batch absorbed 16+ review dispatches while a sibling closed on
# 4. Nothing in the harness noticed either — every gate is closure-time, so the SHAPE of the review
# effort is invisible until someone reads dispatch.jsonl by hand.
#
# Three predicates over data already recorded (dispatch.jsonl + batches.jsonl). All NON-BLOCKING:
# blocking a dispatch pushes the orchestrator to review INLINE — the spec-169 collapse, which is why
# attempt-budget-protocol was rejected. Reporting is the whole intervention.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
FAILF="$(mktemp)"; printf '0' > "$FAILF"
_chk() { if [ "$1" = "$2" ]; then printf '  PASS %s\n' "$3"
  else printf '  FAIL %s (got [%s] want [%s])\n' "$3" "$1" "$2"
       printf '%s' "$(( $(cat "$FAILF") + 1 ))" > "$FAILF"; fi; }

# _run DIR → the escalation output for a prepared .runs/r fixture
_sig() { ( cd "$1" && . "$here/bin/delivery-lib.sh" && TEAM_BOOTSTRAP_RUN=r review_loop_signals ); }
_mk() { # $1=dir  $2=batches.jsonl content  $3=dispatch.jsonl content
  mkdir -p "$1/.runs/r"
  printf '{"run":"r","pipeline":"full","intends_code":true,"baseline_sha":"x"}\n' > "$1/.runs/r/RUN"
  printf '%s' "$2" > "$1/.runs/r/batches.jsonl"
  printf '%s' "$3" > "$1/.runs/r/dispatch.jsonl"
}
_role() { printf '{"batch":"%s","subagent_type":"team-bootstrap:%s"}\n' "$2" "$1"; }

echo "issue #22 — review-loop escalation (three predicates, all non-blocking):"

# ---- P1: same role re-run while NOTHING has closed (the Phase-A loop) ----
T="$(mktemp -d)"; _mk "$T" '' "$(for i in 1 2 3; do _role architecture-reviewer ''; done)"
out="$(_sig "$T")"
_chk "$(printf '%s' "$out" | grep -ci 'architecture-reviewer')" "1" "P1 3 same-role dispatches, zero closures → escalates"
_chk "$(printf '%s' "$out" | grep -ci 'zero')" "1" "P1 …and names the zero-closure condition"
rm -rf "$T"

T="$(mktemp -d)"; _mk "$T" '' "$(for i in 1 2; do _role architecture-reviewer ''; done)"
_chk "$(_sig "$T" | grep -c .)" "0" "P1 2 dispatches is below the threshold → silent"
rm -rf "$T"

# a healthy run that IS closing batches must never trip P1, however many roles it uses
T="$(mktemp -d)"; _mk "$T" '{"id":"B1","kind":"code","status":"closed"}
' "$(for i in 1 2 3 4; do _role architecture-reviewer B1; done)"
_chk "$(_sig "$T" | grep -ci 'zero')" "0" "P1 does not fire once a batch has closed (that is P2/P3's job)"
rm -rf "$T"

# ---- P2: one UNCLOSED batch absorbing >=8 review dispatches ----
T="$(mktemp -d)"; _mk "$T" '{"id":"B2","kind":"code","status":"announced"}
' "$(for i in 1 2; do _role integration-verifier B2; _role architecture-reviewer B2; _role regression-guardian B2; _role tb-code-reviewer B2; done)"
out="$(_sig "$T")"
_chk "$(printf '%s' "$out" | grep -c 'B2')" "1" "P2 8 dispatches on one unclosed batch → escalates"
_chk "$(printf '%s' "$out" | grep -ci 'still open\|unclosed')" "1" "P2 …and says the batch is still open"
rm -rf "$T"

# a CLOSED batch with the same count must not fire — the cost already bought a closure
T="$(mktemp -d)"; _mk "$T" '{"id":"B2","kind":"code","status":"closed"}
' "$(for i in 1 2; do _role integration-verifier B2; _role architecture-reviewer B2; _role regression-guardian B2; _role tb-code-reviewer B2; done)"
_chk "$(_sig "$T" | grep -c 'B2')" "0" "P2 a CLOSED batch with the same spend is silent"
rm -rf "$T"

# a healthy four-role fan-out (B1 closed on 4) must never trip P2
T="$(mktemp -d)"; _mk "$T" '{"id":"B1","kind":"code","status":"announced"}
' "$(_role integration-verifier B1; _role architecture-reviewer B1; _role regression-guardian B1; _role tb-code-reviewer B1)"
_chk "$(_sig "$T" | grep -c .)" "0" "P2 one full four-role fan-out is NOT a loop (threshold is 2 fan-outs)"
rm -rf "$T"

# ---- P3: the aggregate across batches — dispatches per closure ----
# Neither P1 nor P2 sees a run of N batches each costing a "healthy-looking" amount.
T="$(mktemp -d)"; _mk "$T" '{"id":"B1","kind":"code","status":"closed"}
{"id":"B2","kind":"code","status":"closed"}
' "$(for i in 1 2 3 4 5; do _role tb-code-reviewer B1; done; for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do _role tb-code-reviewer B2; done)"
out="$(_sig "$T")"
_chk "$(printf '%s' "$out" | grep -ci 'per closure\|per closed')" "1" "P3 20 dispatches / 2 closures → escalates on the ratio"
_chk "$(printf '%s' "$out" | grep -c '20')" "1" "P3 …and reports the ABSOLUTE count too (a ratio hides scale)"
rm -rf "$T"

# scale-invariance: 10 batches x 4 dispatches is a big milestone, not a loop
T="$(mktemp -d)"
b=""; d=""
for n in 1 2 3 4 5 6 7 8 9 10; do
  b="$b{\"id\":\"B$n\",\"kind\":\"code\",\"status\":\"closed\"}
"; d="$d$(_role integration-verifier "B$n"; _role architecture-reviewer "B$n"; _role regression-guardian "B$n"; _role tb-code-reviewer "B$n")"
done
_mk "$T" "$b" "$d"
_chk "$(_sig "$T" | grep -ci 'per closure\|per closed')" "0" "P3 is scale-invariant: 10 batches x 4 dispatches stays silent"
rm -rf "$T"

# needs >=2 closures to be meaningful (a single expensive batch is P2's job, not a ratio)
T="$(mktemp -d)"; _mk "$T" '{"id":"B1","kind":"code","status":"closed"}
' "$(for i in 1 2 3 4 5 6 7 8 9 10 11 12; do _role tb-code-reviewer B1; done)"
_chk "$(_sig "$T" | grep -ci 'per closure\|per closed')" "0" "P3 stays silent with only one closure (undefined sample)"
rm -rf "$T"

# ---- non-blocking is the contract ----
T="$(mktemp -d)"; _mk "$T" '' "$(for i in 1 2 3 4; do _role architecture-reviewer ''; done)"
( _sig "$T" >/dev/null 2>&1 ); _chk "$?" "0" "escalation always exits 0 — reporting, never a block (spec-169)"
rm -rf "$T"

# ---- pollution tolerance: #20 split-brain mis-stamped Phase-A records onto a foreign batch id ----
# Historical runs carry those; the counter must not be surprised by them (issue #22 caveat).
T="$(mktemp -d)"; _mk "$T" '{"id":"B1","kind":"code","status":"closed"}
' "$(for i in 1 2 3; do _role architecture-reviewer B9-not-in-ledger; done)"
( _sig "$T" >/dev/null 2>&1 ); _chk "$?" "0" "dispatches attributed to an id absent from the ledger do not crash the counter"
rm -rf "$T"

fail="$(cat "$FAILF")"; rm -f "$FAILF"
[ "$fail" -eq 0 ] && { echo "review-loop-escalation.test.sh: OK"; exit 0; }
echo "review-loop-escalation.test.sh: $fail failure(s)"; exit 1
