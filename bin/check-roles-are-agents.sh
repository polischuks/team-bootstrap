#!/usr/bin/env bash
# check-roles-are-agents.sh — #148 (milestone roles-as-first-class-agents). The agent-is-source lints
# that check-role-triples does not cover:
#   AC-2 single-source — a MIGRATED role must not keep BOTH a self-contained agent AND its old playbook.
#         Signal: references/roles/<role>.md exists AND agents/<slug>.md does NOT reference it → the fold
#         happened but the playbook was left behind (a duplicate source). A LEGACY thin shell that DOES
#         reference its playbook is the sanctioned un-migrated form and is allowed during the transition.
#         (Playbook resolved through the review-types attribution column: slug!=role, e.g.
#         tb-code-reviewer → code-reviewer, mirroring check-role-triples.)
#   AC-3 no external dispatch — a migrated agents/<slug>.md must not carry a `preferred_subagent_types:`
#         frontmatter key (it dispatches to the in-repo team-bootstrap:<slug> type; no external catalog).
#
# Usage: bin/check-roles-are-agents.sh [project-dir]  ·  --self-test
# Exit:  0 clean · 1 a single-source or external-dispatch violation · 64 bad usage
set -uo pipefail

# _refs_playbook FILE ROLE → 0 if the agent body references references/roles/<role>.md (fixed-string).
_refs_playbook() { grep -qF "references/roles/$2.md" "$1"; }

# _role_of ROOT SLUG → the attribution role (review-types.txt column 2), else empty.
_role_of() { awk -F'\t' -v s="$2" '!/^#/ && $1==s && NF>1 {print $2; exit}' "$1/references/review-types.txt" 2>/dev/null; }

# _has_pst FILE → 0 if the frontmatter carries a preferred_subagent_types: key (external dispatch).
_has_pst() { awk 'BEGIN{fm=0} /^---$/{fm++; if(fm==2) exit; next} fm==1 && /^preferred_subagent_types:/ {found=1; exit} END{exit !found}' "$1"; }

_check() {
  local root="$1" f slug role n=0
  for f in "$root"/agents/*.md; do
    [ -f "$f" ] || continue
    slug="$(basename "$f" .md)"
    role="$(_role_of "$root" "$slug")"; [ -n "$role" ] || role="$slug"

    # AC-2: leftover duplicate — a playbook exists but the agent does not reference it (self-contained
    # fold that left the playbook behind). A thin shell that references it is the legacy form (allowed).
    if [ -f "$root/references/roles/$role.md" ] && ! _refs_playbook "$f" "$role"; then
      echo "  $slug: single-source violation (AC-2) — references/roles/$role.md still exists but agents/$slug.md does not reference it; a migrated agent must delete the playbook it folded in" >&2
      n=$((n + 1))
    fi

    # AC-3: a migrated agent must not carry an external preferred_subagent_types (dispatch is team-bootstrap:<slug>).
    if _has_pst "$f"; then
      echo "  $slug: external-dispatch violation (AC-3) — agents/$slug.md carries preferred_subagent_types:; a migrated agent dispatches to team-bootstrap:$slug with no external catalog" >&2
      n=$((n + 1))
    fi
  done
  printf '%s' "$n"
}

# --- self-test ---------------------------------------------------------------
if [ "${1:-}" = "--self-test" ]; then
  fail=0
  _c(){ if [ "$1" = "$2" ]; then printf '  PASS %s\n' "$3"; else printf '  FAIL %s (got [%s] want [%s])\n' "$3" "$1" "$2" >&2; fail=$((fail+1)); fi; }
  T="$(mktemp -d)"; mkdir -p "$T/agents" "$T/references/roles"
  # self-contained, no playbook → clean
  { printf -- '---\nname: a\ndescription: d\ntools: Read\n---\n\n# A\n'; for i in $(seq 1 10); do echo "c $i"; done; } > "$T/agents/a.md"
  _c "$(_check "$T")" 0 "self-contained agent, no playbook → clean"
  # leftover duplicate → 1
  printf '# pb\n' > "$T/references/roles/a.md"
  _c "$([ "$(_check "$T")" -ge 1 ] && echo caught || echo missed)" caught "leftover duplicate playbook caught (AC-2)"
  rm "$T/references/roles/a.md"
  # external pst → 1
  { printf -- '---\nname: a\ndescription: d\ntools: Read\npreferred_subagent_types: [backend-developer]\n---\n\n# A\n'; for i in $(seq 1 10); do echo "c $i"; done; } > "$T/agents/a.md"
  _c "$([ "$(_check "$T")" -ge 1 ] && echo caught || echo missed)" caught "external preferred_subagent_types caught (AC-3)"
  rm -rf "$T"
  if [ "$fail" -eq 0 ]; then echo "check-roles-are-agents --self-test: OK"; exit 0; fi
  echo "check-roles-are-agents --self-test: $fail case(s) FAILED" >&2; exit 1
fi

# --- main --------------------------------------------------------------------
case "${1:-}" in -*) echo "usage: check-roles-are-agents.sh [project-dir] | --self-test" >&2; exit 64 ;; esac
root="${1:-.}"
[ -d "$root/agents" ] || { echo "check-roles-are-agents: '$root' has no agents/ — nothing to check"; exit 0; }
n="$(_check "$root")"
if [ "${n:-0}" -eq 0 ]; then
  echo "check-roles-are-agents: OK — no single-source (AC-2) or external-dispatch (AC-3) violations."
  exit 0
fi
echo "check-roles-are-agents: FAIL — $n violation(s) (AC-2 single-source / AC-3 external dispatch)." >&2
exit 1
