#!/usr/bin/env bash
# verdict-schema-upfront.test.sh — issue #88: a review role's required verdict shape must be obtainable
# UPFRONT, not discovered by hitting a --record rejection. Two upfront channels, one schema source:
#   - check-role-verdict --fields ROLE|SLUG prints the required fields with no verdict and no rejection.
#   - subagent-brief.sh states the shape in the reviewer's own brief so it emits the right object first time.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
V="$here/bin/check-role-verdict.sh"; B="$here/bin/subagent-brief.sh"
fail=0
_chk(){ if [ "$1" = "$2" ]; then echo "  PASS $3"; else echo "  FAIL $3 (got [$1] want [$2])" >&2; fail=$((fail+1)); fi; }

echo "1 — --fields prints the required shape without a verdict / rejection:"
_chk "$("$V" --fields security-reviewer | tr ' ' ',')" "severity_counts,secrets_audit_passed" "--fields ROLE lists the required fields"
_chk "$("$V" --fields overengineering-reviewer)" "verdict" "--fields for a single-field role"
_chk "$("$V" --fields no-such-role)" "" "--fields unknown role → empty (invents nothing)"
_chk "$([ -n "$("$V" --fields tb-code-reviewer)" ] && echo nonempty || echo empty)" nonempty "--fields accepts a dispatch slug (tb-code-reviewer → code-reviewer)"

echo "2 — the reviewer's brief states the shape upfront (SubagentStart), from the same schema:"
T="$(mktemp -d)"; export TEAM_BOOTSTRAP_RUN=r
( cd "$T" && git init -q && git config user.email t@t && git config user.name t
  echo base > f && git add . && git commit -qm base && mkdir -p .runs/r
  printf '{"run":"r","pipeline":"full","intends_code":true,"source":"harness"}\n' > .runs/r/RUN
  printf '{"id":"B1","kind":"code","status":"announced"}\n' > .runs/r/batches.jsonl ) >/dev/null 2>&1
OUT="$( cd "$T" && printf '{"subagent_type":"security-reviewer"}' | "$B" 2>/dev/null )"
CTX="$(printf '%s' "$OUT" | python3 -c 'import json,sys
try: print(json.loads(sys.stdin.read()).get("hookSpecificOutput",{}).get("additionalContext",""))
except Exception: print("")' 2>/dev/null)"
_chk "$(printf '%s' "$CTX" | grep -qF 'secrets_audit_passed' && echo yes || echo no)" yes "brief names the role's required verdict fields upfront"
_chk "$(printf '%s' "$CTX" | grep -qF 'check-role-verdict --record' && echo yes || echo no)" yes "  …and how the orchestrator records it"
rm -rf "$T"

if [ "$fail" -eq 0 ]; then echo "verdict-schema-upfront.test.sh: OK"; exit 0; fi
echo "verdict-schema-upfront.test.sh: $fail case(s) FAILED" >&2; exit 1
