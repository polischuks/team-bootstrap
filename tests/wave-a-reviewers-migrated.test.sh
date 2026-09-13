#!/usr/bin/env bash
# wave-a-reviewers-migrated.test.sh — #148 Wave A (T010-T013). Asserts the 14 dedicated reviewer roles
# are FULLY migrated to the agent-is-source form: the playbook references/roles/<role>.md is DELETED
# (single-source, AC-2), and agents/<slug>.md carries its own mind — a version (AC-6), a maintained
# read-map + freshness sourcing (AC-6/AC-7, #146), a typed numeric acceptance contract (AC-7, #147),
# and a tool_surface (AC-1). RED-first: fails while any reviewer still ships a playbook or a thin shell.
# independent-reviewer is the GENERIC slug (no role column, no typed $def) — it is already self-contained
# and is intentionally NOT held to the typed-contract bar (see agents/independent-reviewer.md).
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
_c(){ if [ "$1" -eq 0 ]; then printf '  PASS %s\n' "$2"; else printf '  FAIL %s\n' "$2" >&2; fail=$((fail+1)); fi; }

# slug list (code-reviewer ships as the tb-code-reviewer slug: slug!=role).
SLUGS="accessibility-reviewer architecture-reviewer chaos-engineer data-schema-reviewer devops-platform integration-verifier ip-contracts-reviewer legal-compliance-checker overengineering-reviewer performance-reviewer regression-guardian security-reviewer test-designer tb-code-reviewer"

# role_of SLUG → the review-types attribution role (col 2), else the slug.
_role_of(){ awk -F'\t' -v s="$1" '!/^#/ && $1==s && NF>1 {print $2; exit}' "$here/references/review-types.txt" 2>/dev/null; }

echo "#148 Wave A — the 14 dedicated reviewers are self-contained (playbook folded in + deleted):"
for slug in $SLUGS; do
  a="$here/agents/$slug.md"
  role="$(_role_of "$slug")"; [ -n "$role" ] || role="$slug"
  [ -f "$a" ]; _c $? "$slug: agents/$slug.md exists"
  # AC-2 single-source: the playbook is gone.
  [ ! -f "$here/references/roles/$role.md" ]; _c $? "$slug: references/roles/$role.md deleted (single-source, AC-2)"
  # AC-6: version present in frontmatter.
  grep -qE '^version:[[:space:]]*[0-9]' "$a" 2>/dev/null; _c $? "$slug: carries version: (AC-6)"
  # AC-1: tool_surface present.
  grep -qE '^tool_surface:' "$a" 2>/dev/null; _c $? "$slug: carries tool_surface: (AC-1)"
  # AC-7 #146: a read-map section.
  grep -qiE 'read-?map' "$a" 2>/dev/null; _c $? "$slug: carries a read-map (#146/AC-7)"
  # AC-7 #147: the typed numeric acceptance contract anchored to role-output.schema.json.
  grep -qF 'role-output.schema.json' "$a" 2>/dev/null; _c $? "$slug: carries a typed acceptance contract (#147/AC-7)"
  # AC-6 freshness: an instruction to consult current sources.
  grep -qiE 'freshness|current (source|practice)|WebSearch|consult' "$a" 2>/dev/null; _c $? "$slug: carries freshness sourcing (AC-6)"
done

if [ "$fail" -eq 0 ]; then echo "wave-a-reviewers-migrated.test.sh: OK"; exit 0; fi
echo "wave-a-reviewers-migrated.test.sh: $fail case(s) FAILED" >&2; exit 1
