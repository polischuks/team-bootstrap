#!/usr/bin/env bash
# roles-are-agents.test.sh — #148 T006/T007. AC-2 single-source + AC-3 no-external-dispatch lints.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
G="$here/bin/check-roles-are-agents.sh"
chmod +x "$G" 2>/dev/null || true
fail=0
_c(){ if [ "$1" = "$2" ]; then printf '  PASS %s\n' "$3"; else printf '  FAIL %s (got [%s] want [%s])\n' "$3" "$1" "$2" >&2; fail=$((fail+1)); fi; }
_run(){ ( cd "$1" && bash "$G" . >/dev/null 2>&1 ); echo $?; }

_mk(){ mkdir -p "$1/agents" "$1/references/roles"; }

# AC-2: migrated self-contained agent (no playbook) → OK
T="$(mktemp -d)"; _mk "$T"
{ printf -- '---\nname: r\ndescription: d\ntools: Read\n---\n\n# R\n'; for i in $(seq 1 20); do echo "criterion $i"; done; } > "$T/agents/r.md"
_c "$(_run "$T")" 0 "migrated self-contained agent (no playbook) passes"; rm -rf "$T"

# AC-2: legacy thin shell that REFERENCES its playbook (both exist) → OK (allowed during transition)
T="$(mktemp -d)"; _mk "$T"; printf '# playbook\n' > "$T/references/roles/r.md"
printf -- '---\nname: r\ndescription: d\ntools: Read\n---\n\nRead references/roles/r.md and execute it.\n' > "$T/agents/r.md"
_c "$(_run "$T")" 0 "legacy thin shell referencing its playbook passes (transition)"; rm -rf "$T"

# AC-2 VIOLATION: self-contained agent (does NOT reference playbook) but a leftover playbook exists → CAUGHT
T="$(mktemp -d)"; _mk "$T"; printf '# leftover playbook\n' > "$T/references/roles/r.md"
{ printf -- '---\nname: r\ndescription: d\ntools: Read\n---\n\n# R\n'; for i in $(seq 1 20); do echo "folded criterion $i"; done; } > "$T/agents/r.md"
_c "$([ "$(_run "$T")" -ge 1 ] && echo caught || echo missed)" caught "leftover duplicate playbook (fold left it behind) is caught (AC-2)"; rm -rf "$T"

# AC-3 VIOLATION: migrated agent carries an external preferred_subagent_types → CAUGHT
T="$(mktemp -d)"; _mk "$T"
{ printf -- '---\nname: r\ndescription: d\ntools: Read\npreferred_subagent_types: [backend-developer]\n---\n\n# R\n'; for i in $(seq 1 20); do echo "c $i"; done; } > "$T/agents/r.md"
_c "$([ "$(_run "$T")" -ge 1 ] && echo caught || echo missed)" caught "agent with external preferred_subagent_types is caught (AC-3)"; rm -rf "$T"

if [ "$fail" -eq 0 ]; then echo "roles-are-agents.test.sh: OK"; exit 0; fi
echo "roles-are-agents.test.sh: $fail case(s) FAILED" >&2; exit 1
