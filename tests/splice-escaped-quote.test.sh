#!/usr/bin/env bash
# splice-escaped-quote.test.sh — splice_marker_fields corrupts the marker when a string field's value
# contains an ESCAPED quote (\"). The value-match `"[^"]*"` stops at the first inner quote, so replacing
# a field (or leaving one to its left intact) truncates everything after the escaped quote into invalid
# JSON — dropping trailing fields (verdicts_captured, review_acks, …). harness_context is written via
# _json_esc and can carry a quote (a spec heading, a sizing reason), so this is reachable in a live run.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
_chk(){ if [ "$1" = "$2" ]; then echo "  PASS $3"; else echo "  FAIL $3 (got [$1] want [$2])" >&2; fail=$((fail+1)); fi; }
_valid(){ python3 -c 'import json,sys
try: json.load(open(sys.argv[1])); print("valid")
except Exception: print("invalid")' "$1"; }
_field(){ python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get(sys.argv[2],"<absent>"))
except Exception: print("<unparseable>")' "$1" "$2"; }

T="$(mktemp -d)"; export TEAM_BOOTSTRAP_RUN=r; mkdir -p "$T/.runs/r"
MK="$T/.runs/r/RUN"

# A marker whose harness_context value contains an escaped quote, with fields AFTER it that must survive.
cat > "$MK" <<'EOF'
{"run":"r","pipeline":"full","source":"harness","harness_context":"sizing says \"full\" for this run","review_depth":"low","verdicts_captured":["B1/x","B2/y"],"review_acks":[{"batch":"B1"}]}
EOF

_chk "$(_valid "$MK")" valid "fixture starts as valid JSON"

# Replace harness_context (what the resize / operator-reconcile paths do) — must stay valid JSON and
# must not drop the fields that follow it.
( cd "$T" && . "$here/bin/delivery-lib.sh"
  splice_marker_fields ".runs/r/RUN" "harness_context=new context" "review_depth=medium" )

_chk "$(_valid "$MK")" valid "marker is still valid JSON after splicing a field past an escaped quote"
_chk "$(_field "$MK" harness_context)" "new context" "harness_context updated to the new value"
_chk "$(_field "$MK" review_depth)" "medium" "review_depth updated"
_chk "$(_field "$MK" run)" "r" "leading field intact"
_chk "$(_field "$MK" verdicts_captured)" "['B1/x', 'B2/y']" "trailing array field (verdicts_captured) survived"
_chk "$(_field "$MK" review_acks)" "[{'batch': 'B1'}]" "trailing object array (review_acks) survived"

# Round-trip: a value that ITSELF contains an escaped quote can be written and read back intact.
( cd "$T" && . "$here/bin/delivery-lib.sh"
  splice_marker_fields ".runs/r/RUN" 'harness_context=has a \"quote\" inside' )
_chk "$(_valid "$MK")" valid "marker valid after writing a value that contains escaped quotes"

rm -rf "$T"
if [ "$fail" -eq 0 ]; then echo "splice-escaped-quote.test.sh: OK"; exit 0; fi
echo "splice-escaped-quote.test.sh: $fail case(s) FAILED" >&2; exit 1
