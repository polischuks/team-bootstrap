#!/usr/bin/env bash
# inline-build-doctrine.test.sh — #144. The build step of commands/deliver.md must state that build is
# INLINE BY DEFAULT, and that delegating a builder-subagent is the exception for large, separable batches.
# Rationale: builder-subagents were the largest token line of a full run (cold-context re-read + ~15×
# multi-agent multiplier), and the vendor flags sequential-dependency / shared-context work (most coding)
# as a poor multi-agent fit. Doctrine fix: assert the rule and its rationale are present in deliver.md.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
_chk(){ if [ "$1" -ge "$2" ]; then echo "  PASS $3"; else echo "  FAIL $3 (got [$1] want >=[$2])" >&2; fail=$((fail+1)); fi; }

d="$here/commands/deliver.md"

echo "#144 — commands/deliver.md build step states inline-build-by-default:"
_chk "$(grep -c '#144' "$d")" 1 "deliver.md cites #144"
_chk "$(grep -ci 'inline by default\|build inline by default' "$d")" 1 "states build is inline by default"
_chk "$(grep -ci 'delegate .*builder-subagent only\|only for large' "$d")" 1 "delegation is the exception for large/separable batches"
_chk "$(grep -ci 'cold.context re-read\|cold re-read\|poor.*fit\|shared context' "$d")" 1 "carries the cost/vendor-poor-fit rationale"
_chk "$(grep -ci 'review fan-out.*unaffected\|parallel review.*unaffected\|review fan-out is unaffected' "$d")" 1 "scopes the rule to build, leaving the review fan-out intact"

if [ "$fail" -eq 0 ]; then echo "inline-build-doctrine.test.sh: OK"; exit 0; fi
echo "inline-build-doctrine.test.sh: $fail case(s) FAILED" >&2; exit 1
