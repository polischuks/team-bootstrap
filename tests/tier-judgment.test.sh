#!/usr/bin/env bash
# tier-judgment.test.sh — phase 2.1 / step 4: judgement where paths are blind, as a LIFT-ONLY floor.
#
# size-from-spec.sh admits the blind spot in its own comment: a spec about exactly-once distributed
# settlement sized to single-thread because it touched two files in one directory. Paths and words
# cannot see what a milestone DOES. Anthropic's Routing pattern names the missing half — classification
# by a model rather than an algorithm — and it was unused.
#
# The discipline is ADR-0018's, with a new signal source: the judgement may RAISE the tier and can never
# lower it. One-directional on purpose — a wrong judgement can then only cost review, never skip it.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
_chk() { if [ "$1" = "$2" ]; then printf '  PASS %s\n' "$3"
  else printf '  FAIL %s (got [%s] want [%s])\n' "$3" "$1" "$2" >&2; fail=$((fail + 1)); fi; }
J="$here/bin/judge-tier.sh"

echo "2.1 — the judge exists, is registered, and is deterministically launched:"
_chk "$([ -x "$J" ] && echo yes || echo no)" yes "bin/judge-tier.sh is executable"
_chk "$(python3 -c "
import json,sys; h=json.load(open('$here/hooks/hooks.json'))['hooks']
print('yes' if 'UserPromptExpansion' in h else 'no')")" yes "hooks.json registers UserPromptExpansion"
_chk "$(python3 -c "
import json; h=json.load(open('$here/hooks/hooks.json'))['hooks'].get('UserPromptExpansion',[])
c=[x.get('command','') for g in h for x in g.get('hooks',[])]
print('yes' if any('judge-tier' in x for x in c) else 'no')")" yes "  …pointing at judge-tier.sh"
_chk "$(bash "$J" --self-test >/dev/null 2>&1 && echo ok || echo red)" ok "judge-tier --self-test passes"

echo "2.1 — LIFT-ONLY: the judgement may raise the tier and can never lower it:"
_mk() { # $1=judged tier $2=path to touch → the sized role set
  local D; D="$(mktemp -d)"
  ( cd "$D" || exit 1
    git init -q; git config user.email a@b.c; git config user.name t
    printf 'x\n' > seed.txt; git add -A; git commit -q -m base
    B="$(git rev-parse --short HEAD)"
    mkdir -p "$(dirname "$2")" .runs/r; printf 'z\n' > "$2"; git add -A; git commit -q -m work
    printf '{"run":"r","pipeline":"full","intends_code":true,"baseline_sha":"%s"}\n' "$B" > .runs/r/RUN
    printf '{"id":"B1","kind":"code","status":"announced"}\n' > .runs/r/batches.jsonl
    [ -n "$1" ] && printf 'tier=%s\nreason=test\n' "$1" > .runs/r/tier-judgment
    . "$here/bin/delivery-lib.sh"; TEAM_BOOTSTRAP_RUN=r required_roles_for_batch B1 ) 2>/dev/null
  rm -rf "$D"
}
BASE="$(_mk "" src/x.ts)"
UP="$(_mk full src/x.ts)"
DOWN="$(_mk single-thread src/api/openapi.yaml)"
FULLSET="$(_mk "" src/api/openapi.yaml)"
_chk "$(printf '%s' "$BASE" | grep -qw architecture-reviewer && echo yes || echo no)" no "baseline: a one-file change is not full"
_chk "$(printf '%s' "$UP" | grep -qw architecture-reviewer && echo yes || echo no)" yes "judgement 'full' RAISES a light batch"
_chk "$(printf '%s' "$DOWN" | grep -qw architecture-reviewer && echo yes || echo no)" yes "judgement 'single-thread' CANNOT lower a full batch"
_chk "$DOWN" "$FULLSET" "  …the set is byte-identical to the unjudged one"

echo "2.1 — inert on every failure path (fallback is exactly today's behaviour):"
_chk "$(_mk nonsense src/x.ts)" "$BASE" "an unparseable tier is ignored"
_chk "$( ( printf '{}' | TEAM_BOOTSTRAP_DELIVERY_GATE=off bash "$J" >/dev/null 2>&1 ); echo $? )" 0 "kill switch → exit 0"
_chk "$( ( printf 'not json' | bash "$J" >/dev/null 2>&1 ); echo $? )" 0 "unparseable payload → exit 0"
_chk "$( ( printf '{}' | bash "$J" >/dev/null 2>&1 ); echo $? )" 0 "empty payload → exit 0"
_chk "$( ( cd "$(mktemp -d)" || exit 1; printf '{"prompt":"/team-bootstrap:deliver specs/none"}' | bash "$J" >/dev/null 2>&1 ); echo $? )" 0 "no spec on disk → exit 0"

[ "$fail" -eq 0 ] && { echo "tier-judgment.test.sh: OK"; exit 0; }
echo "tier-judgment.test.sh: $fail failure(s)" >&2; exit 1
