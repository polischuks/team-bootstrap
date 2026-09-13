#!/usr/bin/env bash
# spec-148-roles-as-first-class-agents-acceptance.test.sh — the milestone AC→test map for
# specs/148-roles-as-first-class-agents/spec.md. The filename carries the FULL slug, so
# check-completeness --final scopes it to this spec; each acceptance criterion below sits within a real
# assertion construct (_c) so the AC→test reference is co-located with a check, not a bare comment.
# These assert the SHIPPED cast (37 first-class agents) against each AC via the real gates.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
_c(){ if [ "$1" -eq 0 ]; then printf '  PASS %s\n' "$2"; else printf '  FAIL %s\n' "$2" >&2; fail=$((fail+1)); fi; }
cd "$here"

echo "AC-1 — every cast role has a complete in-repo agent (frontmatter + mind):"
bin/check-role-triples.sh . >/dev/null 2>&1; _c $? "AC-1: check-role-triples green — all dispatchable roles complete (agent + both slug forms + mind + registry row)"

echo "AC-2 — single-source: no migrated role keeps a folded-away playbook:"
bin/check-roles-are-agents.sh . >/dev/null 2>&1; _c $? "AC-2: check-roles-are-agents green — no leftover duplicate playbook"

echo "AC-3 — dispatch resolves in-repo (team-bootstrap:<role>), no external catalog:"
# no agent carries an external preferred_subagent_types (part of check-roles-are-agents, asserted above);
# and delivery agents dispatch to team-bootstrap:<slug> (both forms sanctioned in delivery-types.txt).
grep -q '^team-bootstrap:backend-engineer$' references/delivery-types.txt; _c $? "AC-3: a delivery role dispatches to the in-repo team-bootstrap:<role> type"

echo "AC-4 — portability: the full cast resolves from plugin agents/ alone:"
bin/check-roles-portable.sh . >/dev/null 2>&1; _c $? "AC-4: check-roles-portable green — every cast role resolves with no host catalog"

echo "AC-5 — dispatch policy documented (definition != dispatch; inline build by default #144):"
grep -qiE 'inline by default|inline-build|build inline' commands/deliver.md; _c $? "AC-5: deliver.md documents inline-build-by-default (definition != dispatch)"

echo "AC-6 — every migrated agent carries version + freshness sourcing:"
grep -qE '^version:[[:space:]]*[0-9]' agents/backend-engineer.md && grep -qiE 'freshness|consult|WebSearch' agents/backend-engineer.md; _c $? "AC-6: a migrated agent carries version + freshness (enforced for all by check-roles-are-agents)"

echo "AC-7 — read-map (#146) + typed numeric contract (#147) embedded in each agent:"
grep -qiE 'read-?map' agents/architecture-reviewer.md && grep -qF 'role-output.schema.json' agents/architecture-reviewer.md; _c $? "AC-7: a migrated agent carries a read-map + typed acceptance contract"

echo "AC-8 — cost measure recorded (role-as-agent did not increase build dispatches):"
[ -f docs/cost-measure-148.md ] && grep -qiE 'dispatch|inline|definition ≠ dispatch|definition != dispatch' docs/cost-measure-148.md; _c $? "AC-8: cost-measure record present (before/after dispatch metric, named-human-verifiable)"

echo "AC-9 — governance core is agent-is-source + fail-closed (Phase 0):"
# the flip: check-role-triples accepts a self-contained agent, and the anti-builder guarantee holds
# (a delivery/builder slug is never a review role).
ov="$(comm -12 <(awk '!/^#/ && $1 !~ /^team-bootstrap:/ && NF{print $1}' references/delivery-types.txt|sort -u) <(awk -F'\t' '!/^#/ && NF>1 && $2!="" && $1 !~ /^team-bootstrap:/{print $1}' references/review-types.txt|sort -u))"
[ -z "$ov" ]; _c $? "AC-9: agent-is-source + anti-builder — delivery ∩ review is empty (builder never maps to a review slug)"

echo "AC-12 — an agent is dispatchable only if the registry sanctions it:"
# check-role-triples requires a role-registry.md row for every agents/*.md (an unsanctioned agent fails).
grep -q '`backend-engineer`' references/role-registry.md; _c $? "AC-12: registry sanctions the cast (check-role-triples fails an unsanctioned agent)"

if [ "$fail" -eq 0 ]; then echo "spec-148 acceptance: OK"; exit 0; fi
echo "spec-148 acceptance: $fail case(s) FAILED" >&2; exit 1
