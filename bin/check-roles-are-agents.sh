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

    # AC-6/AC-7 (#148 T062) — standing machine-side enforcement of the self-contained agent contract.
    # A MIGRATED self-contained agent (no playbook) MUST carry its own mind: `version:` (AC-6, freshness),
    # a read-map (#146/AC-7), and a typed acceptance contract anchored to role-output.schema.json
    # (#147/AC-7). This is the standing gate the per-wave tests assert; here it binds every current AND
    # future agent through verify-batch. EXEMPT: the generic `independent-reviewer` (no role column, no
    # typed $def by design), and legacy thin-shells (playbook present → validated the pre-148 way).
    if [ ! -f "$root/references/roles/$role.md" ] && [ "$slug" != "independent-reviewer" ]; then
      grep -qE '^version:[[:space:]]*[0-9]' "$f" \
        || { echo "  $slug: AC-6 — self-contained agent has no 'version:' frontmatter (freshness contract)" >&2; n=$((n + 1)); }
      grep -qiE 'read-?map' "$f" \
        || { echo "  $slug: AC-7 — self-contained agent carries no read-map (#146)" >&2; n=$((n + 1)); }
      grep -qF 'role-output.schema.json' "$f" \
        || { echo "  $slug: AC-7 — self-contained agent carries no typed acceptance contract anchored to role-output.schema.json (#147)" >&2; n=$((n + 1)); }
    fi
  done
  printf '%s' "$n"
}

# --- self-test ---------------------------------------------------------------
if [ "${1:-}" = "--self-test" ]; then
  fail=0
  _c(){ if [ "$1" = "$2" ]; then printf '  PASS %s\n' "$3"; else printf '  FAIL %s (got [%s] want [%s])\n' "$3" "$1" "$2" >&2; fail=$((fail+1)); fi; }
  T="$(mktemp -d)"; mkdir -p "$T/agents" "$T/references/roles"
  # _mk FILE FRONTMATTER_EXTRA BODY_EXTRA — a self-contained agent that is AC-6/AC-7 compliant by default
  # (version + read-map + role-output.schema.json), so a case can drop exactly the field it means to test.
  _mk(){ { printf -- '---\nname: a\ndescription: d\ntools: Read\nversion: 1.0.0\n%s---\n\n# A\n## Read-map\nrole-output.schema.json\n%s\n' "$2" "$3"; for i in $(seq 1 8); do echo "c $i"; done; } > "$1"; }
  # self-contained, compliant → clean
  _mk "$T/agents/a.md" "" ""
  _c "$(_check "$T")" 0 "self-contained agent (version+read-map+typed contract) → clean"
  # leftover duplicate → 1 (AC-2)
  printf '# pb\n' > "$T/references/roles/a.md"
  _c "$([ "$(_check "$T")" -ge 1 ] && echo caught || echo missed)" caught "leftover duplicate playbook caught (AC-2)"
  rm "$T/references/roles/a.md"
  # external pst → 1 (AC-3)
  _mk "$T/agents/a.md" "preferred_subagent_types: [backend-developer]\n" ""
  _c "$([ "$(_check "$T")" -ge 1 ] && echo caught || echo missed)" caught "external preferred_subagent_types caught (AC-3)"
  # AC-6: missing version → caught
  { printf -- '---\nname: a\ndescription: d\ntools: Read\n---\n\n# A\n## Read-map\nrole-output.schema.json\n'; for i in $(seq 1 8); do echo "c $i"; done; } > "$T/agents/a.md"
  _c "$([ "$(_check "$T")" -ge 1 ] && echo caught || echo missed)" caught "self-contained agent missing version caught (AC-6)"
  # AC-7: missing read-map → caught
  { printf -- '---\nname: a\ndescription: d\ntools: Read\nversion: 1.0.0\n---\n\n# A\nrole-output.schema.json\n'; for i in $(seq 1 8); do echo "c $i"; done; } > "$T/agents/a.md"
  _c "$([ "$(_check "$T")" -ge 1 ] && echo caught || echo missed)" caught "self-contained agent missing read-map caught (AC-7)"
  # AC-7: missing typed contract → caught
  { printf -- '---\nname: a\ndescription: d\ntools: Read\nversion: 1.0.0\n---\n\n# A\n## Read-map\n'; for i in $(seq 1 8); do echo "c $i"; done; } > "$T/agents/a.md"
  _c "$([ "$(_check "$T")" -ge 1 ] && echo caught || echo missed)" caught "self-contained agent missing typed contract caught (AC-7)"
  # the generic independent-reviewer is EXEMPT from AC-6/AC-7 (no version/read-map/contract) → clean
  { printf -- '---\nname: independent-reviewer\ndescription: d\ntools: Read\n---\n\n# Independent\n'; for i in $(seq 1 8); do echo "c $i"; done; } > "$T/agents/independent-reviewer.md"
  rm -f "$T/agents/a.md"
  _c "$(_check "$T")" 0 "generic independent-reviewer exempt from AC-6/AC-7 → clean"
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
