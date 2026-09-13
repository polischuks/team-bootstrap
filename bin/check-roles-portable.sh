#!/usr/bin/env bash
# check-roles-portable.sh — #148 T050 / AC-4 (portability). A fresh plugin install with NO host agent
# catalog must still yield the FULL cast: every dispatchable role resolves its definition from the
# plugin-shipped agents/ alone. This harness enumerates the cast (review-types.txt non-generic roles +
# delivery-types.txt slugs) and, seeing ONLY agents/, asserts each resolves:
#   - agents/<slug>.md exists (the definition ships in-repo), and
#   - it carries NO external `preferred_subagent_types` (no reliance on a host/external catalog).
# Any external reliance = failure. This is the machine check behind AC-4: strip the host catalog (which is
# simply never consulted here) and prove the cast still stands on the plugin's own agents/.
#
# Usage: bin/check-roles-portable.sh [project-dir]  ·  --self-test
# Exit:  0 fully portable · 1 a role does not resolve from agents/ alone · 64 bad usage
set -uo pipefail

# _cast ROOT → the dispatchable cast, one slug per line: review-types.txt rows with a role column (bare
# slugs only, excluding the generic which has no role column) + every delivery-types.txt slug. Both files
# are the sanction manifests; a slug in either is a role the harness must be able to dispatch.
_cast() {
  local root="$1"
  { awk -F'\t' '!/^#/ && NF>1 && $2!="" && $1 !~ /^team-bootstrap:/ {print $1}' "$root/references/review-types.txt" 2>/dev/null
    awk '!/^#/ && $1 !~ /^team-bootstrap:/ && NF {print $1}' "$root/references/delivery-types.txt" 2>/dev/null
  } | sort -u | grep -v '^$'
}

# _has_pst FILE → 0 if the frontmatter carries preferred_subagent_types: (external-catalog reliance).
_has_pst() { awk 'BEGIN{fm=0} /^---$/{fm++; if(fm==2) exit; next} fm==1 && /^preferred_subagent_types:/ {found=1; exit} END{exit !found}' "$1"; }

_check() {
  local root="$1" slug n=0
  while IFS= read -r slug; do
    [ -n "$slug" ] || continue
    if [ ! -f "$root/agents/$slug.md" ]; then
      echo "  $slug: NOT portable — no agents/$slug.md; the cast role does not resolve from the plugin's own agents/ (would need a host catalog, AC-4)" >&2
      n=$((n + 1)); continue
    fi
    if _has_pst "$root/agents/$slug.md"; then
      echo "  $slug: NOT portable — agents/$slug.md carries preferred_subagent_types (relies on an external/host catalog, AC-4)" >&2
      n=$((n + 1))
    fi
  done < <(_cast "$root")
  printf '%s' "$n"
}

# --- self-test ---------------------------------------------------------------
if [ "${1:-}" = "--self-test" ]; then
  fail=0
  _c(){ if [ "$1" = "$2" ]; then printf '  PASS %s\n' "$3"; else printf '  FAIL %s (got [%s] want [%s])\n' "$3" "$1" "$2" >&2; fail=$((fail+1)); fi; }
  T="$(mktemp -d)"; mkdir -p "$T/agents" "$T/references"
  printf 'r1\treviewrole\n' > "$T/references/review-types.txt"
  printf 'd1\nteam-bootstrap:d1\n' > "$T/references/delivery-types.txt"
  # both resolve from agents/ → portable
  printf -- '---\nname: r1\n---\nbody\n' > "$T/agents/r1.md"
  printf -- '---\nname: d1\n---\nbody\n' > "$T/agents/d1.md"
  _c "$(_check "$T")" 0 "every cast role has an agents/ definition → portable"
  # a cast role with no agent → not portable
  rm "$T/agents/d1.md"
  _c "$([ "$(_check "$T")" -ge 1 ] && echo caught || echo missed)" caught "a cast role with no agents/<slug>.md is caught (AC-4)"
  printf -- '---\nname: d1\n---\nbody\n' > "$T/agents/d1.md"
  # a cast role that relies on an external catalog → not portable
  printf -- '---\nname: d1\npreferred_subagent_types: [backend-developer]\n---\nbody\n' > "$T/agents/d1.md"
  _c "$([ "$(_check "$T")" -ge 1 ] && echo caught || echo missed)" caught "a cast role with external preferred_subagent_types is caught (AC-4)"
  rm -rf "$T"
  if [ "$fail" -eq 0 ]; then echo "check-roles-portable --self-test: OK"; exit 0; fi
  echo "check-roles-portable --self-test: $fail case(s) FAILED" >&2; exit 1
fi

# --- main --------------------------------------------------------------------
case "${1:-}" in -*) echo "usage: check-roles-portable.sh [project-dir] | --self-test" >&2; exit 64 ;; esac
root="${1:-.}"
[ -d "$root/agents" ] || { echo "check-roles-portable: '$root' has no agents/ — nothing to check"; exit 0; }
n="$(_check "$root")"
if [ "${n:-0}" -eq 0 ]; then
  echo "check-roles-portable: OK — every cast role resolves from the plugin's own agents/ (no host catalog needed, AC-4)."
  exit 0
fi
echo "check-roles-portable: FAIL — $n cast role(s) do not resolve from agents/ alone (AC-4 portability)." >&2
exit 1
