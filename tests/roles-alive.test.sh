#!/usr/bin/env bash
# roles-alive.test.sh — a role is ALIVE only if the harness can select it, dispatch it, attribute it
# and enforce it. Doc "Как оживить роли", phases 0.4, 1.1 and 2.
#
# The structural root, verified before writing this: references/roles/ holds 51 playbooks and agents/
# holds 5 subagent definitions. A role with no agents/<slug>.md cannot carry a subagent_type, so it is
# invisible to record-dispatch.sh BY CONSTRUCTION — security-reviewer's 150-line playbook does not
# exist as far as the machine is concerned. Meanwhile the classifier ALREADY computes five risk
# categories (security/auth, data/schema, infra/deploy, api/contract, deps) and throws them away into
# `reasons=`: a ready signal with no addressee.
#
# Also pinned here: --per-batch used to return EMPTY with rc=0 when tasks.md carries no `## ` sections
# — a silent degradation, which the audit calls out as its own defect class (row 10).
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
_chk() { if [ "$1" = "$2" ]; then printf '  PASS %s\n' "$3"
  else printf '  FAIL %s (got [%s] want [%s])\n' "$3" "$1" "$2" >&2; fail=$((fail + 1)); fi; }

WAVE="security-reviewer data-schema-reviewer overengineering-reviewer"
MAP="$here/profiles/default.map"

# ---------------------------------------------------------------------------
# 0.4 — degradation never returns empty-and-green
# ---------------------------------------------------------------------------
echo "0.4 — silent degradation:"
T="$(mktemp -d)"; mkdir -p "$T/specs/flat" "$T/specs/ws"
printf '# Spec\n' > "$T/specs/flat/spec.md"
printf '# Tasks\n\n- [ ] T1 a\n  - file: bin/a.sh \xc2\xb7 (feat)\n' > "$T/specs/flat/tasks.md"
printf '# Spec\n' > "$T/specs/ws/spec.md"
printf '# Tasks\n\n## WS-A api\n\n- [ ] T1 a\n  - file: src/api/x.ts \xc2\xb7 (feat)\n' > "$T/specs/ws/tasks.md"
_pb() { ( cd "$T" || exit 1; "$here/bin/size-from-spec.sh" --per-batch "specs/$1/spec.md" 2>/dev/null ); }

_chk "$(_pb flat | grep -c 'degraded=1')" 1 "no '## ' sections → degraded=1 (was: empty and green)"
_chk "$(_pb flat | grep -c '^reason=')"   1 "  …with a machine-readable reason"
_chk "$(_pb ws | grep -c '^ws=')"         1 "sections present → still emits entries (no regression)"
_chk "$(_pb ws | grep -c 'degraded=1')"   0 "  …and does NOT claim degradation"
rm -rf "$T"

echo "0.4 — the degradation reaches the marker AND the model:"
T2="$(mktemp -d)"; mkdir -p "$T2/specs/flat"
( cd "$T2" || exit 1; git init -q; git config user.email a@b.c; git config user.name t
  printf 'x\n' > s.txt; git add -A; git commit -q -m b ) >/dev/null 2>&1
printf '# S\n' > "$T2/specs/flat/spec.md"
printf '# Tasks\n\n- [ ] T1 a\n  - file: bin/a.sh \u00b7 (feat)\n' > "$T2/specs/flat/tasks.md"
DOUT="$( ( cd "$T2" || exit 1; printf '/team-bootstrap:deliver specs/flat' | "$here/bin/delivery-marker-init.sh" 2>/dev/null ) )"
_chk "$(grep -c '"sizing_degraded"' "$T2/.runs/flat/RUN" 2>/dev/null)" 1 "marker records sizing_degraded"
_chk "$(printf '%s' "$DOUT" | grep -qi 'degraded' && echo yes || echo no)" yes "the model is told, not left to infer it from an absent plan"
rm -rf "$T2"

# ---------------------------------------------------------------------------
# 1.1 — dispatchable (agents/) + attributable (review-types.txt)
# ---------------------------------------------------------------------------
echo "1.1 — one slug = agent + attribution + playbook:"
for r in $WAVE; do
  _chk "$([ -f "$here/agents/$r.md" ] && echo yes || echo no)" yes "agents/$r.md exists (dispatchable)"
  _chk "$([ -f "$here/references/roles/$r.md" ] && echo yes || echo no)" yes "  playbook exists"
  # BOTH slug forms must attribute — the team-bootstrap: prefix is not reliably delivered
  for form in "team-bootstrap:$r" "$r"; do
    _chk "$(awk -F'\t' -v s="$form" '$1==s && $2!="" {print "yes"; exit}' "$here/references/review-types.txt")" yes \
      "  review-types.txt attributes '$form'"
  done
  # single source: the agent body must POINT at the playbook, not restate it
  _chk "$(grep -qF "references/roles/$r.md" "$here/agents/$r.md" && echo yes || echo no)" yes \
    "  agent body defers to the playbook (no duplicated criteria)"
done

echo "1.1 — every agents/*.md frontmatter is VALID YAML (criterion 1 fails invisibly otherwise):"
# A role is dispatchable only if its agent definition parses. agents/tb-code-reviewer.md shipped on
# main with `team-bootstrap: prefix` unquoted inside `description` — YAML reads the `: ` as a nested
# mapping and the whole block is invalid. Nothing caught it: eval-role --all validates
# references/roles/*.md frontmatter and never looks at agents/. A mandatory review role can therefore
# stop being registrable without one test going red, which is criterion 1 failing in silence.
_badfm="$(python3 - <<'PYEOF'
import yaml, glob, sys
bad=[]
for p in sorted(glob.glob("agents/*.md")):
    try:
        yaml.safe_load(open(p).read().split("---\n")[1])
    except Exception:
        bad.append(p.split("/")[-1])
print(" ".join(bad))
PYEOF
)"
_chk "${_badfm:-none}" none "every agents/*.md frontmatter parses as YAML"

echo "1.1 — anti-builder invariant (a builder must never satisfy the review floor):"
_builders=""
while IFS="$(printf '\t')" read -r slug role _rest; do
  case "$slug" in ''|'#'*) continue ;; esac
  [ -n "${role:-}" ] || continue
  pb="$here/references/roles/$role.md"; [ -f "$pb" ] || continue
  sed -n '/^tool_surface:/,/^permission_mode:/p' "$pb" | grep -qE '^[[:space:]]*deny:.*(Write|Edit)' \
    || _builders="${_builders:+$_builders }$role"
done < "$here/references/review-types.txt"
_chk "${_builders:-none}" none "every attributed role denies Write/Edit"

# ---------------------------------------------------------------------------
# 2 — selectable: risk category → roles, from a profile file
# ---------------------------------------------------------------------------
echo "2 — the profile map:"
_chk "$([ -f "$MAP" ] && echo yes || echo no)" yes "profiles/default.map exists"
[ -f "$MAP" ] || { echo "  FAIL map missing — every check below would pass VACUOUSLY; refusing" >&2; fail=$((fail + 1)); MAP=/dev/null; }

# no DEAD ENTRIES: every role the map names must be dispatchable
_dead=""
while read -r _cat _roles; do
  case "$_cat" in ''|'#'*) continue ;; esac
  for _r in $_roles; do [ -f "$here/agents/$_r.md" ] || _dead="${_dead:+$_dead }$_r"; done
done < "$MAP"
_chk "${_dead:-none}" none "every role named by the map has an agents/ file"

# no DEAD KEYS: every category must be one select-pipeline.sh actually emits.
#
# Read from `--categories`, which publishes the vocabulary beside the code that emits it, rather than
# scraping the source. The scrape this replaces matched `[a-z/]+` and therefore could not see a category
# containing a hyphen: `no-tests` was invisible to it and reported as a dead key while being emitted
# correctly. A check that reconstructs its expectation from source text drifts from the source the
# moment the source gains a character class the regex does not know about.
_emitted="$("$here/bin/select-pipeline.sh" --categories 2>/dev/null | tr ' ' '\n' | grep -v '^$' | sort -u)"
_deadk=""
while read -r _cat _rest; do
  case "$_cat" in ''|'#'*) continue ;; esac
  printf '%s\n' "$_emitted" | grep -qx "$_cat" || _deadk="${_deadk:+$_deadk }$_cat"
done < "$MAP"
_chk "${_deadk:-none}" none "every category key is one the classifier emits"

# Criterion 6: a role that cannot return a TYPED verdict cannot be confirmed at closure, so it must not
# be assignable yet. chaos-engineer is deliberately absent from the map for exactly this reason — its
# schema def declares no required field, and adding one is a new required handoff field, i.e. a MAJOR
# bump under references/versioning.md. infra/deploy therefore stays unmapped until that is decided.
_untyped=""
while read -r _cat _roles; do
  case "$_cat" in ''|'#'*) continue ;; esac
  for _r in $_roles; do
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["$defs"].get(sys.argv[2],{}); sys.exit(0 if any(b.get("required") for b in d.get("allOf",[])) else 1)' "$here/references/schemas/role-output.schema.json" "$_r" 2>/dev/null || _untyped="${_untyped:+$_untyped }$_r"
  done
done < "$MAP"
_chk "${_untyped:-none}" none "every mapped role declares a required verdict field (criterion 6)"

echo "2 — behaviour: the category reaches the role set:"
_roles_for() { # $1=path to touch → the sized role set
  local D; D="$(mktemp -d)"
  ( cd "$D" || exit 1
    git init -q; git config user.email a@b.c; git config user.name t
    printf 'x\n' > seed.txt; git add -A; git commit -q -m base
    B="$(git rev-parse --short HEAD)"
    mkdir -p "$(dirname "$1")" .runs/r
    printf 'z\n' > "$1"; git add -A; git commit -q -m work
    printf '{"run":"r","pipeline":"full","intends_code":true,"baseline_sha":"%s"}\n' "$B" > .runs/r/RUN
    printf '{"id":"B1","kind":"%s","status":"announced"}\n' "${2:-code}" > .runs/r/batches.jsonl
    . "$here/bin/delivery-lib.sh"; TEAM_BOOTSTRAP_RUN=r required_roles_for_batch B1
  ) 2>/dev/null
  rm -rf "$D"
}
SEC="$(_roles_for src/auth/login.ts)"
_chk "$(printf '%s' "$SEC" | grep -qw security-reviewer && echo yes || echo no)" yes \
  "auth path → security-reviewer is required (was: computed, then discarded)"
DAT="$(_roles_for db/schema.sql)"
_chk "$(printf '%s' "$DAT" | grep -qw data-schema-reviewer && echo yes || echo no)" yes \
  "schema path → data-schema-reviewer is required"

echo "2 — invariants the map must never break:"
_chk "$(printf '%s' "$SEC" | grep -qw code-reviewer && echo yes || echo no)" yes \
  "the >=1 independent reviewer floor survives (never sized away)"
_chk "$(printf '%s' "$SEC" | grep -qw integration-verifier && echo yes || echo no)" yes \
  "the tier-derived base set is ADDED to, never replaced"
_chk "$(_roles_for docs/x.md doc)" "" "a doc batch still earns no review fan-out"

[ "$fail" -eq 0 ] && { echo "roles-alive.test.sh: OK"; exit 0; }
echo "roles-alive.test.sh: $fail failure(s)" >&2; exit 1
