#!/usr/bin/env bash
# role-triples-agent-is-source.test.sh — #148 T001. check-role-triples.sh flips to AGENT-IS-SOURCE,
# transition-aware: a role whose playbook references/roles/<role>.md is ABSENT is a self-contained agent
# and passes WITHOUT a playbook and WITHOUT the <=40-line ceiling — provided it carries a non-trivial
# body. A role whose playbook is PRESENT keeps the legacy rules (body must reference it, ceiling applies),
# so un-migrated reviewers keep passing during the migration. AC-12 sanction + both-slug review row stay.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
G="$here/bin/check-role-triples.sh"
fail=0
_c(){ if [ "$1" = "$2" ]; then printf '  PASS %s\n' "$3"; else printf '  FAIL %s (got [%s] want [%s])\n' "$3" "$1" "$2" >&2; fail=$((fail+1)); fi; }
_run(){ ( cd "$1" && bash "$G" . >/dev/null 2>&1 ); echo $?; }

# --- self-contained agent (NEW form): no playbook, sanctioned, both slug forms, non-trivial body → PASS
T="$(mktemp -d)"; mkdir -p "$T/agents" "$T/references/roles"
printf 'x\treviewer-x\nteam-bootstrap:x\treviewer-x\n' > "$T/references/review-types.txt"
printf '| `x` | reviewer-x | `agents/x.md` (self-contained) | routed from `ui` |\n' > "$T/references/role-registry.md"
{ printf -- '---\nname: x\ndescription: d\ntools: Read, Grep\n---\n\n# Reviewer X\n'
  for i in $(seq 1 30); do echo "Substantive criterion line $i — the mind lives here now."; done; } > "$T/agents/x.md"
_c "$(_run "$T")" 0 "self-contained agent (no playbook, long body) PASSES — agent is the source"
rm -rf "$T"

# --- guard: no playbook AND trivial body → FAIL (not actually self-contained)
T="$(mktemp -d)"; mkdir -p "$T/agents" "$T/references/roles"
printf 'x\treviewer-x\nteam-bootstrap:x\treviewer-x\n' > "$T/references/review-types.txt"
printf '| `x` | reviewer-x | `agents/x.md` | r |\n' > "$T/references/role-registry.md"
printf -- '---\nname: x\ndescription: d\ntools: Read\n---\n\ntodo\n' > "$T/agents/x.md"
_c "$([ "$(_run "$T")" -ge 1 ] && echo caught || echo missed)" caught "no-playbook + trivial body is caught (not self-contained)"
rm -rf "$T"

# --- legacy form (playbook PRESENT, referenced, small body) → still PASS (transition safety)
T="$(mktemp -d)"; mkdir -p "$T/agents" "$T/references/roles"
printf 'y\treviewer-y\nteam-bootstrap:y\treviewer-y\n' > "$T/references/review-types.txt"
printf '# Reviewer Y\n' > "$T/references/roles/reviewer-y.md"
printf '| `y` | reviewer-y | `references/roles/reviewer-y.md` | r |\n' > "$T/references/role-registry.md"
printf -- '---\nname: y\ndescription: d\ntools: Read\n---\n\nRead references/roles/reviewer-y.md and execute it.\n' > "$T/agents/y.md"
_c "$(_run "$T")" 0 "legacy thin-shell + playbook STILL passes (un-migrated reviewer)"
rm -rf "$T"

# --- unsanctioned agent (no registry row) → FAIL (AC-12 preserved)
T="$(mktemp -d)"; mkdir -p "$T/agents" "$T/references/roles"
printf 'x\treviewer-x\nteam-bootstrap:x\treviewer-x\n' > "$T/references/review-types.txt"
: > "$T/references/role-registry.md"
{ printf -- '---\nname: x\ndescription: d\ntools: Read\n---\n\n'; for i in $(seq 1 30); do echo "line $i"; done; } > "$T/agents/x.md"
_c "$([ "$(_run "$T")" -ge 1 ] && echo caught || echo missed)" caught "unsanctioned agent still caught (AC-12)"
rm -rf "$T"

if [ "$fail" -eq 0 ]; then echo "role-triples-agent-is-source.test.sh: OK"; exit 0; fi
echo "role-triples-agent-is-source.test.sh: $fail case(s) FAILED" >&2; exit 1
