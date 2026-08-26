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

# ---------------------------------------------------------------------------
# AC-21 (milestone 020) — an unavailable judgement is RECORDED, not merely absent.
#
# Every failure path above is inert, which is right. But inert and silent are different things: a run
# where the model was never asked, timed out, or answered gibberish is indistinguishable from a run
# where the judge was simply not registered. That is the same silent-degradation shape AC-47 removed
# from the sizing path — "returns emptiness instead of a decision" — and AC-48 requires every such path
# to declare its reason. The fallback behaviour does not change; only its visibility.
# ---------------------------------------------------------------------------
echo "AC-21 — a judgement that cannot be made is recorded as judgment=unavailable, with a reason:"

# _run_judge ENV... → run the hook against a real spec in a temp repo; echo the judgment file's body
_run_judge() {
  local D; D="$(mktemp -d)"
  ( cd "$D" || exit 1
    mkdir -p specs/jt .runs/jt
    printf '# Spec\n\nAn exactly-once distributed settlement calculation.\n' > specs/jt/spec.md
    env "$@" bash "$J" >/dev/null 2>&1 <<<'{"prompt":"/team-bootstrap:deliver specs/jt"}'
    cat .runs/jt/tier-judgment 2>/dev/null || true )
  rm -rf "$D"
}

# The force-skip switch is the cleanest "no judgement was made" path that needs no `claude` binary.
OUT_OFF="$(_run_judge TEAM_BOOTSTRAP_TIER_JUDGE=off)"
_chk "$([ -z "$OUT_OFF" ] && echo empty || echo written)" empty \
  "the explicit kill switch writes NOTHING (opting out is not a degradation)"

# An unreachable model. PATH is narrowed to the system directories — enough for bash and coreutils,
# not enough to find `claude`, which installs under the user's prefix. (A PATH of /nonexistent would
# also remove `bash` and test nothing but `env`.)
OUT_NOCLI="$(_run_judge TEAM_BOOTSTRAP_TIER_JUDGE_FORCE=1 PATH=/usr/bin:/bin)"
_chk "$(printf '%s' "$OUT_NOCLI" | grep -q '^judgment=unavailable' && echo yes || echo no)" yes \
  "no judgement obtainable ⇒ judgment=unavailable is RECORDED"
_chk "$(printf '%s' "$OUT_NOCLI" | grep -qE '^reason=.+' && echo yes || echo no)" yes \
  "  …with a non-empty reason"
_chk "$(printf '%s' "$OUT_NOCLI" | grep -q '^tier=' && echo yes || echo no)" no \
  "  …and NO tier line — an unavailable judgement must never look like a verdict"
_chk "$(printf '%s' "$OUT_NOCLI" | sed -n 's/^reason=//p')" "no-model-cli" \
  "  …and the reason NAMES the cause, so a missing install is not confused with a slow model"

# A model that runs and times out is a DIFFERENT fact from one that is not installed: the first is a
# calibration problem (R5/OQ-4 — does a 900-line spec fit in 60 s?), the second an install problem.
# A stub `claude` exiting 124 is exactly what coreutils' timeout returns.
STUB="$(mktemp -d)"
printf '#!/bin/sh\nexit 124\n' > "$STUB/claude"; chmod +x "$STUB/claude"
OUT_TO="$(_run_judge TEAM_BOOTSTRAP_TIER_JUDGE_FORCE=1 "PATH=$STUB:/usr/bin:/bin")"
_chk "$(printf '%s' "$OUT_TO" | sed -n 's/^reason=//p')" "timeout-60s" \
  "a timed-out judgement is recorded as a timeout, not as a generic failure"

# A model that answers, but not with one of the three known words. Not a transport failure at all.
printf '#!/bin/sh\necho "I think this is quite large"\n' > "$STUB/claude"
OUT_JUNK="$(_run_judge TEAM_BOOTSTRAP_TIER_JUDGE_FORCE=1 "PATH=$STUB:/usr/bin:/bin")"
_chk "$(printf '%s' "$OUT_JUNK" | sed -n 's/^reason=//p')" "unparseable-answer" \
  "prose instead of a verdict is recorded as unparseable, never as a guess"
rm -rf "$STUB"

echo "AC-21b — an unavailable record changes no outcome (it is a fact, not a floor):"
_mk_unavail() {
  local D; D="$(mktemp -d)"
  ( cd "$D" || exit 1
    git init -q; git config user.email a@b.c; git config user.name t
    printf 'x\n' > seed.txt; git add -A; git commit -q -m base
    B="$(git rev-parse --short HEAD)"
    mkdir -p src .runs/r; printf 'z\n' > src/x.ts; git add -A; git commit -q -m work
    printf '{"run":"r","pipeline":"full","intends_code":true,"baseline_sha":"%s"}\n' "$B" > .runs/r/RUN
    printf '{"id":"B1","kind":"code","status":"announced"}\n' > .runs/r/batches.jsonl
    printf 'judgment=unavailable\nreason=no-model\n' > .runs/r/tier-judgment
    . "$here/bin/delivery-lib.sh"; TEAM_BOOTSTRAP_RUN=r required_roles_for_batch B1 ) 2>/dev/null
  rm -rf "$D"
}
_chk "$(_mk_unavail)" "$BASE" "an 'unavailable' record sizes exactly as no record at all"

echo "AC-21c — the 60 s timeout is pinned in the registration, not only in the script:"
_chk "$(python3 -c "
import json; h=json.load(open('$here/hooks/hooks.json'))['hooks'].get('UserPromptExpansion',[])
hs=[x for g in h for x in g.get('hooks',[]) if 'judge-tier' in x.get('command','')]
print('yes' if hs and hs[0].get('timeout') else 'no')")" yes \
  "the judge-tier registration carries an explicit timeout"

[ "$fail" -eq 0 ] && { echo "tier-judgment.test.sh: OK"; exit 0; }
echo "tier-judgment.test.sh: $fail failure(s)" >&2; exit 1
