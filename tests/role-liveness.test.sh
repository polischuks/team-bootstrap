#!/usr/bin/env bash
# role-liveness.test.sh — phase 3.3: the constitutional definition of a live role, enforced.
#
#   A role is ALIVE iff an eval exists that goes RED when the role is removed from the set.
#
# This is check-gate-integrity.sh's philosophy applied to roles instead of gates: a gate that cannot
# fail is not a gate, and a role whose removal changes nothing is a playbook, not a role. Counting it
# is self-deception, which is why "number of roles with a reddening eval" is the only honest answer to
# "how many roles are alive".
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
_chk() { if [ "$1" = "$2" ]; then printf '  PASS %s\n' "$3"
  else printf '  FAIL %s (got [%s] want [%s])\n' "$3" "$1" "$2" >&2; fail=$((fail + 1)); fi; }

echo "3.3 — every binding the shipped profile can assign is alive:"
OUT="$(bash "$here/bin/eval-role.sh" --liveness 2>&1)"; RC=$?
printf '%s\n' "$OUT" | sed 's/^/    /'
_chk "$RC" 0 "eval-role --liveness is green on the shipped profile"
_chk "$(printf '%s' "$OUT" | grep -c 'DEAD')" 0 "no dead bindings"

echo "3.3 — the eval is not green-by-construction (it must be able to say DEAD):"
# Mutation: a mapping the tier already satisfies contributes nothing, and the eval must SAY so rather
# than counting it. This is the check that keeps the metric honest.
M="$(mktemp)"; cp "$here/profiles/default.map" "$M"
printf 'api/contract    integration-verifier\n' >> "$M"
DOUT="$(TEAM_BOOTSTRAP_PROFILE="$M" bash "$here/bin/eval-role.sh" --liveness 2>&1)"; DRC=$?
rm -f "$M"
_chk "$DRC" 1 "a binding the tier already satisfies → non-zero exit"
_chk "$(printf '%s' "$DOUT" | grep -c 'DEAD  integration-verifier')" 1 "  …and is named DEAD, not silently counted"

[ "$fail" -eq 0 ] && { echo "role-liveness.test.sh: OK"; exit 0; }
echo "role-liveness.test.sh: $fail failure(s)" >&2; exit 1
