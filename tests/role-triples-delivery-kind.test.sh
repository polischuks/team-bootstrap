#!/usr/bin/env bash
# role-triples-delivery-kind.test.sh — #148 T002. Non-review roles (builders/PM/GTM) are sanctioned as
# DELIVERY agents via a SEPARATE references/delivery-types.txt (both slug forms), NOT a review-types.txt
# row. check-role-triples accepts a delivery agent that is (a) sanctioned in the registry, (b) listed in
# delivery-types.txt both forms, (c) self-contained (agent-is-source), and (d) NOT carrying a review role
# in review-types.txt — the load-bearing anti-builder guarantee (a builder must never map to a review slug).
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
G="$here/bin/check-role-triples.sh"
fail=0
_c(){ if [ "$1" = "$2" ]; then printf '  PASS %s\n' "$3"; else printf '  FAIL %s (got [%s] want [%s])\n' "$3" "$1" "$2" >&2; fail=$((fail+1)); fi; }
_run(){ ( cd "$1" && bash "$G" . >/dev/null 2>&1 ); echo $?; }

_delivery_fixture(){ # → root with ONE self-contained delivery agent, sanctioned via delivery-types.txt
  local T; T="$(mktemp -d)"; mkdir -p "$T/agents" "$T/references/roles"
  : > "$T/references/review-types.txt"                                   # NOT in review-types (anti-builder)
  printf 'backend-engineer\nteam-bootstrap:backend-engineer\n' > "$T/references/delivery-types.txt"
  printf '| `backend-engineer` | delivery | `agents/backend-engineer.md` (self-contained) | delivery role |\n' > "$T/references/role-registry.md"
  { printf -- '---\nname: backend-engineer\ndescription: builds backend\ntools: Read, Edit, Bash\n---\n\n# Backend Engineer\n'
    for i in $(seq 1 25); do echo "Self-contained criterion line $i."; done; } > "$T/agents/backend-engineer.md"
  printf '%s' "$T"
}

# a well-formed delivery agent PASSES (sanctioned via delivery-types.txt, not review-types.txt)
T="$(_delivery_fixture)"; _c "$(_run "$T")" 0 "self-contained delivery agent via delivery-types.txt PASSES"; rm -rf "$T"

# anti-builder: a delivery agent that ALSO carries a review role column is CAUGHT
T="$(_delivery_fixture)"; printf 'backend-engineer\tsome-review-role\nteam-bootstrap:backend-engineer\tsome-review-role\n' > "$T/references/review-types.txt"
_c "$([ "$(_run "$T")" -ge 1 ] && echo caught || echo missed)" caught "delivery agent with a review role column is caught (anti-builder)"; rm -rf "$T"

# a delivery agent NOT in delivery-types.txt at all is caught (unsanctioned as delivery, absent from review)
T="$(_delivery_fixture)"; : > "$T/references/delivery-types.txt"
_c "$([ "$(_run "$T")" -ge 1 ] && echo caught || echo missed)" caught "delivery agent absent from delivery-types.txt is caught"; rm -rf "$T"

# a REVIEW agent (legacy form) still passes — the split does not disturb the existing path
T="$(mktemp -d)"; mkdir -p "$T/agents" "$T/references/roles"
printf 'y\treviewer-y\nteam-bootstrap:y\treviewer-y\n' > "$T/references/review-types.txt"
: > "$T/references/delivery-types.txt"
printf '# Reviewer Y\n' > "$T/references/roles/reviewer-y.md"
printf '| `y` | reviewer-y | `references/roles/reviewer-y.md` | r |\n' > "$T/references/role-registry.md"
printf -- '---\nname: y\ndescription: d\ntools: Read\n---\n\nRead references/roles/reviewer-y.md and execute it.\n' > "$T/agents/y.md"
_c "$(_run "$T")" 0 "review agent still passes (split does not disturb review path)"; rm -rf "$T"

if [ "$fail" -eq 0 ]; then echo "role-triples-delivery-kind.test.sh: OK"; exit 0; fi
echo "role-triples-delivery-kind.test.sh: $fail case(s) FAILED" >&2; exit 1
