#!/usr/bin/env bash
# role-triples-delivery-typed.test.sh — #148 T003/T009. A DELIVERY agent must be Typed: when a
# references/schemas/role-output.schema.json exists, the delivery slug must have a $def carrying at least
# one required field (its numeric acceptance contract, #147/AC-7). This is the "Typed" liveness condition
# (role-registry.md:16) for delivery agents — eval-role --liveness only measures ROUTED bindings, so a
# delivery agent (unrouted by design) needs its Typed check where it is already iterated: check-role-triples.
# When no schema file exists (a fixture testing something else), the Typed check is not applicable.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
G="$here/bin/check-role-triples.sh"
fail=0
_c(){ if [ "$1" = "$2" ]; then printf '  PASS %s\n' "$3"; else printf '  FAIL %s (got [%s] want [%s])\n' "$3" "$1" "$2" >&2; fail=$((fail+1)); fi; }
_run(){ ( cd "$1" && bash "$G" . >/dev/null 2>&1 ); echo $?; }

_fixture(){ # → root with ONE self-contained delivery agent; caller adds the schema
  local T; T="$(mktemp -d)"; mkdir -p "$T/agents" "$T/references/roles" "$T/references/schemas"
  : > "$T/references/review-types.txt"
  printf 'backend-engineer\nteam-bootstrap:backend-engineer\n' > "$T/references/delivery-types.txt"
  printf '| `backend-engineer` | delivery | `agents/backend-engineer.md` | delivery role |\n' > "$T/references/role-registry.md"
  { printf -- '---\nname: backend-engineer\ndescription: builds backend\ntools: Read, Edit, Bash\n---\n\n# Backend Engineer\n'
    for i in $(seq 1 25); do echo "criterion $i"; done; } > "$T/agents/backend-engineer.md"
  printf '%s' "$T"
}

# delivery agent WITH a schema $def carrying a required field → Typed → PASS
T="$(_fixture)"; printf '{"$defs":{"backend-engineer":{"allOf":[{"required":["build_verdict"]}]}}}\n' > "$T/references/schemas/role-output.schema.json"
_c "$(_run "$T")" 0 "delivery agent with a role-output.schema.json \$def PASSES (Typed)"; rm -rf "$T"

# delivery agent WITH a schema present but NO $def for it → not Typed → CAUGHT
T="$(_fixture)"; printf '{"$defs":{"someone-else":{"allOf":[{"required":["x"]}]}}}\n' > "$T/references/schemas/role-output.schema.json"
_c "$([ "$(_run "$T")" -ge 1 ] && echo caught || echo missed)" caught "delivery agent with schema but no \$def is caught (not Typed)"; rm -rf "$T"

# delivery agent with NO schema file at all → Typed check not applicable → PASS (fixtures/foreign repos)
T="$(_fixture)"; rm -rf "$T/references/schemas"
_c "$(_run "$T")" 0 "no schema file → Typed check not applicable → PASSES"; rm -rf "$T"

if [ "$fail" -eq 0 ]; then echo "role-triples-delivery-typed.test.sh: OK"; exit 0; fi
echo "role-triples-delivery-typed.test.sh: $fail case(s) FAILED" >&2; exit 1
