#!/usr/bin/env bash
# loader-agent-first-doctrine.test.sh — #148 T004/B4. The orchestrator role-loader doctrine must resolve
# a role's mind AGENT-FIRST (agents/<role>.md, self-contained) with a legacy fallback to
# references/roles/<role>.md, and must dispatch to the in-repo team-bootstrap:<role> type — across BOTH
# consumers of references/roles/: the reviewer dispatch-prompt supply (subagent-dispatch.md) AND the
# inline output-style activation read path (orchestrator.md / subagent-mapping.md). Doctrine change →
# presence-test on the reference docs.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
_c(){ if [ "$1" -ge "$2" ]; then printf '  PASS %s\n' "$3"; else printf '  FAIL %s (got [%s] want >=[%s])\n' "$3" "$1" "$2" >&2; fail=$((fail+1)); fi; }

D="$here/references/subagent-dispatch.md"
M="$here/references/subagent-mapping.md"
O="$here/references/orchestrator.md"

echo "#148 B4 — dispatch doctrine resolves agent-first + dispatches to team-bootstrap:<role>:"
_c "$(grep -c 'agent-is-source\|agents/<role>.md' "$D")" 1 "subagent-dispatch.md states agent-first resolution"
_c "$(grep -c 'team-bootstrap:<role>\|team-bootstrap:<slug>' "$D")" 1 "subagent-dispatch.md dispatches to the in-repo team-bootstrap: type"
_c "$(grep -ci 'self-contained\|legacy\|not-yet-migrated\|not yet migrated' "$D")" 1 "subagent-dispatch.md is transition-aware (self-contained vs legacy)"

echo "#148 B4 — inline activation (second consumer) resolves agent-first:"
_c "$(grep -c 'agent-is-source\|agents/<role>.md' "$O")" 1 "orchestrator.md inline activation resolves from agents/<role>.md"
_c "$(grep -ci 'both consumer\|inline activation\|output style' "$O")" 1 "orchestrator.md names the inline-activation read path"

echo "#148 B4 — mapping doctrine points at agents/ not the external catalog:"
_c "$(grep -c 'agent-is-source\|agents/<role>.md' "$M")" 1 "subagent-mapping.md resolves agent-first"

if [ "$fail" -eq 0 ]; then echo "loader-agent-first-doctrine.test.sh: OK"; exit 0; fi
echo "loader-agent-first-doctrine.test.sh: $fail case(s) FAILED" >&2; exit 1
