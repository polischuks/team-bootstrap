#!/usr/bin/env bash
# check-role-triples.sh — a dispatchable role is complete, or it is not shipped (AC-7, AC-8, AC-12).
#
# THE FAILURE THIS CATCHES. A role needs four independent things to be assignable, and each one can go
# missing on its own without any other check noticing:
#
#   agents/<slug>.md ................ or it cannot carry a subagent_type at all
#   review-types.txt, BOTH forms .... or the dispatch happens and the harness does not see it
#   the ROLE'S MIND ................. either a self-contained agent body (agent-is-source, milestone 148)
#                                     OR, for an un-migrated role, references/roles/<role>.md it points at
#   references/role-registry.md ..... or nobody can say why this role exists
#
# Before this gate the four were kept in step by hand. `bin/eval-role.sh --liveness` catches an
# incomplete role only if the profile ROUTES it; a role that is dispatchable-but-unrouted — which every
# one of the four MANDATORY review roles is, since the tier base set carries them — was invisible to
# every check in the tree. This is the structural half; --liveness stays the behavioural half.
#
# BOTH SLUG FORMS are required because the `team-bootstrap:` prefix is not reliably delivered in
# `tool_input.subagent_type` — review-types.txt has said so since exec-role-integrity, and a role listed
# in only one form is attributable exactly half the time, which is worse than either extreme because it
# looks correct in a spot check.
#
# SOURCE OF TRUTH (milestone 148 — agent-is-source, transition-aware). A role's mind is EITHER folded
# into the agent body (self-contained: no playbook, no ceiling, but a BODY_MIN floor so a shell cannot
# drop its playbook without folding the criteria in) OR, for a role not yet migrated, carried by
# references/roles/<role>.md that a thin-shell agent references (the pre-148 LEGACY rule: reference + a
# BODY_MAX duplication ceiling). Both are accepted during the migration so it can proceed role-by-role;
# AC-2's single-source lint (a separate gate) forbids a migrated role from keeping BOTH.
#
# Usage: bin/check-role-triples.sh [project-dir]  ·  bin/check-role-triples.sh --self-test
# Exit:  0 every agent is complete · 1 an incomplete triple · 64 bad usage
set -uo pipefail

BODY_MAX="${TEAM_BOOTSTRAP_AGENT_BODY_MAX:-40}"
# Self-contained (agent-is-source) floor: a migrated agent that carries its own mind must have a
# non-trivial body. Guards against a thin shell that deleted its playbook without folding the criteria in.
BODY_MIN="${TEAM_BOOTSTRAP_AGENT_BODY_MIN:-5}"

# _fm FILE KEY → the value of a top-level frontmatter key (empty if absent).
_fm() { awk -v k="$1" 'BEGIN{fm=0} /^---$/{fm++; if(fm==2) exit; next}
        fm==1 && $0 ~ "^"k":" {sub("^"k":[[:space:]]*",""); print; exit}' "$2"; }

# _body_lines FILE → substantive (non-blank) lines after the frontmatter.
_body_lines() { awk 'BEGIN{fm=0} /^---$/{fm++; next} fm>=2 && NF>0 {n++} END{print n+0}' "$1"; }

# _role_of ROOT SLUG → the role a slug attributes to (column 2), or empty for a generic.
_role_of() { awk -F'\t' -v s="$2" '!/^#/ && $1==s && NF>1 {print $2; exit}' "$1/references/review-types.txt"; }

# _listed ROOT SLUG → 0 if the exact slug appears at all (with or without a role column).
_listed() { awk -F'\t' -v s="$2" '!/^#/ && $1==s {f=1} END{exit !f}' "$1/references/review-types.txt"; }

# _has_slug ROOT SLUG → 0 if the exact slug appears with a NON-EMPTY role column.
_has_slug() { awk -F'\t' -v s="$2" '!/^#/ && $1==s && NF>1 && $2!="" {f=1} END{exit !f}' "$1/references/review-types.txt"; }

# _registry_row ROOT SLUG → the role-registry.md "Dispatchable slugs" row for SLUG (empty if none).
_registry_row() { grep -E "^\| \`$2\` \|" "$1/references/role-registry.md" 2>/dev/null | head -1; }

# _is_generic ROW → 0 when the registry marks the slug a generic: no role column, no playbook. A
# generic satisfies the >=1 anti-collapse floor WITHOUT attributing, so demanding attribution of it
# would be demanding it stop being a generic. The exemption is narrow and must be written down —
# otherwise "no role column" is indistinguishable from an oversight, which is the whole failure class
# this gate exists for.
_is_generic() { printf '%s' "$1" | grep -q '| generic |'; }

_check() {
  local root="$1" f slug role body v row n=0
  for f in "$root"/agents/*.md; do
    [ -f "$f" ] || continue
    slug="$(basename "$f" .md)"

    for k in name description tools; do
      v="$(_fm "$k" "$f")"
      [ -n "$v" ] || { echo "  $slug: frontmatter has no '$k:'" >&2; n=$((n + 1)); }
    done
    v="$(_fm name "$f")"
    [ "$v" = "$slug" ] || { echo "  $slug: frontmatter name '$v' does not match the filename" >&2; n=$((n + 1)); }

    row="$(_registry_row "$root" "$slug")"
    [ -n "$row" ] || { echo "  $slug: agents/$slug.md exists but references/role-registry.md does not sanction it" >&2; n=$((n + 1)); }

    if [ -n "$row" ] && _is_generic "$row"; then
      # A generic still has to BE THERE in both forms — the exemption covers attribution, not presence.
      _listed "$root" "$slug"                || { echo "  $slug: generic, but the bare slug is absent from review-types.txt" >&2; n=$((n + 1)); }
      _listed "$root" "team-bootstrap:$slug" || { echo "  $slug: generic, but the prefixed slug is absent from review-types.txt" >&2; n=$((n + 1)); }
    else
      _has_slug "$root" "$slug"                || { echo "  $slug: no bare slug with a role column in review-types.txt" >&2; n=$((n + 1)); }
      _has_slug "$root" "team-bootstrap:$slug" || { echo "  $slug: no team-bootstrap:-prefixed slug with a role column in review-types.txt" >&2; n=$((n + 1)); }
    fi

    # Source-of-truth is AGENT-IS-SOURCE (milestone 148), transition-aware so a migration can proceed
    # role-by-role without the gate rejecting whatever has not moved yet:
    #   - playbook PRESENT  → LEGACY form: the agent is a thin shell, so it must reference the playbook
    #     and stay under the duplication ceiling (the pre-148 rule, kept for un-migrated agents).
    #   - playbook ABSENT   → SELF-CONTAINED form: the agent carries its own mind. No playbook to
    #     reference, no ceiling — but it must carry a NON-TRIVIAL body (>= BODY_MIN), or it is a shell
    #     that dropped its playbook without folding the criteria in.
    # The playbook is resolved through the ATTRIBUTION column, not the slug: tb-code-reviewer attributes
    # to code-reviewer and reads references/roles/code-reviewer.md — slug!=role indirection preserved.
    role="$(_role_of "$root" "$slug")"; [ -n "$role" ] || role="$slug"
    body="$(_body_lines "$f")"
    if [ -n "$row" ] && _is_generic "$row"; then
      :                                           # a generic has no playbook and no mind, by definition
    elif [ -f "$root/references/roles/$role.md" ]; then
      grep -qF "references/roles/$role.md" "$f" \
        || { echo "  $slug: legacy form (playbook present) but the agent body does not reference references/roles/$role.md" >&2; n=$((n + 1)); }
      [ "$body" -le "$BODY_MAX" ] \
        || { echo "  $slug: legacy form body is $body substantive lines (ceiling $BODY_MAX) — restating the playbook, or migrate to self-contained (delete the playbook)" >&2; n=$((n + 1)); }
    else
      [ "$body" -ge "$BODY_MIN" ] \
        || { echo "  $slug: self-contained form (no playbook) but body is only $body substantive lines (floor $BODY_MIN) — the agent must carry its own criteria" >&2; n=$((n + 1)); }
    fi

  done
  printf '%s' "$n"
}

# --- self-test ---------------------------------------------------------------
if [ "${1:-}" = "--self-test" ]; then
  fail=0
  _c() { if [ "$1" = "$2" ]; then printf '  PASS %s\n' "$3"
    else printf '  FAIL %s (got [%s] want [%s])\n' "$3" "$1" "$2" >&2; fail=$((fail + 1)); fi; }

  _fixture() { # → a root with ONE complete role
    local T; T="$(mktemp -d)"
    mkdir -p "$T/agents" "$T/references/roles"
    printf 'x\treviewer-x\nteam-bootstrap:x\treviewer-x\n' > "$T/references/review-types.txt"
    printf '# Reviewer X\n' > "$T/references/roles/reviewer-x.md"
    printf '| `x` | reviewer-x | `references/roles/reviewer-x.md` | routed from `ui` |\n' > "$T/references/role-registry.md"
    cat > "$T/agents/x.md" <<'A'
---
name: x
description: a reviewer
tools: Read, Grep
---

Read references/roles/reviewer-x.md and execute it.
A
    printf '%s' "$T"
  }

  T="$(_fixture)"; _c "$(_check "$T")" 0 "a complete triple passes"; rm -rf "$T"

  T="$(_fixture)"; printf 'x\treviewer-x\n' > "$T/references/review-types.txt"
  _c "$([ "$(_check "$T")" -ge 1 ] && echo caught || echo missed)" caught "a MISSING prefixed slug is caught"; rm -rf "$T"

  T="$(_fixture)"; printf 'team-bootstrap:x\treviewer-x\n' > "$T/references/review-types.txt"
  _c "$([ "$(_check "$T")" -ge 1 ] && echo caught || echo missed)" caught "a missing BARE slug is caught"; rm -rf "$T"

  T="$(_fixture)"; printf 'x\nteam-bootstrap:x\n' > "$T/references/review-types.txt"
  _c "$([ "$(_check "$T")" -ge 1 ] && echo caught || echo missed)" caught "a slug with NO role column is caught"; rm -rf "$T"

  # AGENT-IS-SOURCE (148), transition-aware: a missing playbook is NOT itself a failure — it is the
  # self-contained form. The _fixture body is a 1-line shell, so a bare removal is caught by the
  # BODY_MIN floor (a shell that dropped its playbook without folding the mind in) …
  T="$(_fixture)"; rm "$T/references/roles/reviewer-x.md"
  _c "$([ "$(_check "$T")" -ge 1 ] && echo caught || echo missed)" caught \
    "playbook removed but body still a 1-line shell → caught (self-contained BODY_MIN floor)"; rm -rf "$T"

  # … and the SAME role, once its mind is folded into a non-trivial body, PASSES with no playbook.
  T="$(_fixture)"; rm "$T/references/roles/reviewer-x.md"
  { for i in $(seq 1 20); do echo "folded criterion $i"; done; } >> "$T/agents/x.md"
  _c "$(_check "$T")" 0 "playbook removed AND mind folded into the agent body → PASSES (agent is source)"; rm -rf "$T"

  # A GENERIC passes without a role column and without a playbook — but only because the registry says
  # `generic`, never because both happen to be absent.
  T="$(_fixture)"; rm "$T/references/roles/reviewer-x.md"
  printf 'x\nteam-bootstrap:x\n' > "$T/references/review-types.txt"
  printf '| `x` | generic | — | satisfies the >=1 floor without attributing |\n' > "$T/references/role-registry.md"
  printf -- '---\nname: x\ndescription: d\ntools: Read\n---\n\nA generic reviewer.\n' > "$T/agents/x.md"
  _c "$(_check "$T")" 0 "a registry-marked generic passes with no role column and no playbook"; rm -rf "$T"

  # …and a generic that is not LISTED at all still fails: the exemption covers attribution, not presence.
  T="$(_fixture)"; rm "$T/references/roles/reviewer-x.md"
  printf 'x\n' > "$T/references/review-types.txt"
  printf '| `x` | generic | — | satisfies the >=1 floor without attributing |\n' > "$T/references/role-registry.md"
  printf -- '---\nname: x\ndescription: d\ntools: Read\n---\n\nA generic reviewer.\n' > "$T/agents/x.md"
  _c "$([ "$(_check "$T")" -ge 1 ] && echo caught || echo missed)" caught \
    "a generic missing its prefixed form is still caught"; rm -rf "$T"

  T="$(_fixture)"; printf 'a reviewer, with no playbook link\n' >> "$T/agents/x.md"
  printf -- '---\nname: x\ndescription: d\ntools: Read\n---\n\nno link here\n' > "$T/agents/x.md"
  _c "$([ "$(_check "$T")" -ge 1 ] && echo caught || echo missed)" caught "an agent that does not reference its playbook is caught"; rm -rf "$T"

  T="$(_fixture)"; : > "$T/references/role-registry.md"
  _c "$([ "$(_check "$T")" -ge 1 ] && echo caught || echo missed)" caught "an UNSANCTIONED agent is caught (AC-12)"; rm -rf "$T"

  T="$(_fixture)"; { echo; for i in $(seq 1 60); do echo "line $i"; done; } >> "$T/agents/x.md"
  _c "$([ "$(_check "$T")" -ge 1 ] && echo caught || echo missed)" caught "an agent over the duplication ceiling is caught"; rm -rf "$T"

  T="$(_fixture)"; sed -i.bak 's/^name: x$/name: wrong/' "$T/agents/x.md"; rm -f "$T/agents/x.md.bak"
  _c "$([ "$(_check "$T")" -ge 1 ] && echo caught || echo missed)" caught "a frontmatter name that disagrees with the filename is caught"; rm -rf "$T"

  if [ "$fail" -eq 0 ]; then echo "check-role-triples --self-test: OK"; exit 0; fi
  echo "check-role-triples --self-test: $fail case(s) FAILED" >&2; exit 1
fi

# --- main --------------------------------------------------------------------
case "${1:-}" in -*) echo "usage: check-role-triples.sh [project-dir] | --self-test" >&2; exit 64 ;; esac
root="${1:-.}"
[ -d "$root/agents" ] || { echo "check-role-triples: '$root' has no agents/ — nothing to check" >&2; exit 0; }

n="$(_check "$root")"
total="$(find "$root/agents" -maxdepth 1 -name '*.md' | grep -c . || true)"
if [ "${n:-0}" -eq 0 ]; then
  echo "check-role-triples: OK — all $total dispatchable role(s) complete (agent + both slug forms + a mind [self-contained body OR playbook] + registry row)."
  exit 0
fi
echo "check-role-triples: FAIL — $n incomplete-role problem(s) across $total agent file(s)." >&2
echo "  A role missing any one of these is not half-dispatchable, it is undispatchable in a way that" >&2
echo "  looks fine in a spot check. See references/role-registry.md for what each condition buys." >&2
exit 1
