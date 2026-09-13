#!/usr/bin/env bash
# wave-d-delivery-agents.test.sh — #148 Wave D (T040-T043). Asserts the 6 engineering DELIVERY roles are
# created as self-contained in-repo agents (agent-is-source): agents/<slug>.md exists with name==slug, its
# references/roles/<slug>.md playbook is DELETED (AC-2), it is sanctioned in references/delivery-types.txt
# (both forms) but NEVER in review-types.txt (the anti-builder guarantee, AC-9b), it is Typed by a
# role-output.schema.json $def (#147/AC-7), and it carries version (AC-6) + read-map (#146) + tool_surface
# (AC-1) + freshness (AC-6). RED-first: fails until every delivery agent is created + wired + playbook gone.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
_c(){ if [ "$1" -eq 0 ]; then printf '  PASS %s\n' "$2"; else printf '  FAIL %s\n' "$2" >&2; fail=$((fail+1)); fi; }

SLUGS="growth-marketer product-marketer community-manager customer-success-manager partnerships-lead stakeholder-communicator ui-designer ux-designer ux-researcher whimsy-injector"

_fm_name(){ awk 'BEGIN{fm=0} /^---$/{fm++; if(fm==2) exit; next} fm==1 && /^name:/ {sub(/^name:[[:space:]]*/,""); print; exit}' "$1"; }
_in_delivery(){ awk -v s="$1" '!/^#/ && $1==s {f=1} END{exit !f}' "$here/references/delivery-types.txt"; }
_in_review(){ awk -F'\t' -v s="$1" '!/^#/ && $1==s && NF>1 && $2!="" {f=1} END{exit !f}' "$here/references/review-types.txt"; }

echo "#148 Wave B — the 10 GTM/UX roles are self-contained delivery agents:"
for slug in $SLUGS; do
  a="$here/agents/$slug.md"
  [ -f "$a" ]; _c $? "$slug: agents/$slug.md exists (created)"
  [ -f "$a" ] && { [ "$(_fm_name "$a")" = "$slug" ]; _c $? "$slug: frontmatter name == slug"; } || _c 1 "$slug: frontmatter name == slug"
  [ ! -f "$here/references/roles/$slug.md" ]; _c $? "$slug: references/roles/$slug.md deleted (single-source, AC-2)"
  _in_delivery "$slug"; _c $? "$slug: sanctioned in delivery-types.txt (bare)"
  _in_delivery "team-bootstrap:$slug"; _c $? "$slug: sanctioned in delivery-types.txt (prefixed)"
  # anti-builder: MUST NOT be a review role.
  if _in_review "$slug" || _in_review "team-bootstrap:$slug"; then _c 1 "$slug: NOT a review role (anti-builder, AC-9b)"; else _c 0 "$slug: NOT a review role (anti-builder, AC-9b)"; fi
  # Typed by a schema $def (resolve base via check-role-verdict, same resolver as _typed_ok).
  python3 -c "import json;d=json.load(open('$here/references/schemas/role-output.schema.json'));import sys;sys.exit(0 if '$slug' in d.get('\$defs',{}) else 1)"; _c $? "$slug: has a role-output.schema.json \$def (Typed, #147)"
  [ -f "$a" ] || continue
  grep -qE '^version:[[:space:]]*[0-9]' "$a"; _c $? "$slug: carries version: (AC-6)"
  grep -qE '^tool_surface:' "$a"; _c $? "$slug: carries tool_surface: (AC-1)"
  grep -qiE 'read-?map' "$a"; _c $? "$slug: carries a read-map (#146/AC-7)"
  grep -qF 'role-output.schema.json' "$a"; _c $? "$slug: carries a typed acceptance contract (#147/AC-7)"
  grep -qiE 'freshness|current source|WebSearch|consult' "$a"; _c $? "$slug: carries freshness sourcing (AC-6)"
done

if [ "$fail" -eq 0 ]; then echo "wave-d-delivery-agents.test.sh: OK"; exit 0; fi
echo "wave-d-delivery-agents.test.sh: $fail case(s) FAILED" >&2; exit 1
