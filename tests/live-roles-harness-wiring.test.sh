#!/usr/bin/env bash
# live-roles-harness-wiring.test.sh — milestone 020, WS-A: the context channel says everything the
# model needs, and it never loses a decision to a silent cut.
#
# Two gaps left open by v2.35.0, both in the same channel:
#
#   AC-1 — the additionalContext the harness emits carries run / depth / tier_source / marker, but NOT
#          the two facts the whole selector exists to produce: which RISK CATEGORIES the classifier
#          detected, and which ROLE COMPOSITION they earned. Д2 Ф0.1 spells the target text out:
#          "Risk categories detected: security/auth, data/schema. Assigned review roles for this run:
#          …". Without them the model is told a depth and left to guess the cast.
#
#   AC-3 — emit_hook_context CUTS at 9000 characters. The vendor ceiling is 10 000, and the hooks
#          reference says the over-limit path is "запись в файл и передача пути" — spill, not truncate.
#          A cut is a silent degradation: the tail of the verdict vanishes with no reason recorded,
#          which is the exact failure mode P10 and AC-48 exist to refuse.
#
#   AC-2 — the phrasing discipline (facts, never imperatives) is honoured by habit today. A denylist
#          that no gate reads is a convention, not a control; check-context-phrasing.sh makes it one.
#
# Written BEFORE the fix → red, then green.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
_chk() { if [ "$1" = "$2" ]; then printf '  PASS %s\n' "$3"
  else printf '  FAIL %s (got [%s] want [%s])\n' "$3" "$1" "$2" >&2; fail=$((fail + 1)); fi; }

PY() { python3 -c "$1" "${@:2}"; }
_ctx_of() { PY 'import json,sys
try: print(json.loads(sys.stdin.read()).get("hookSpecificOutput",{}).get("additionalContext",""))
except Exception: print("")'; }

# ---------------------------------------------------------------------------
# AC-1 — the six facts, in the channel, at the moment they are needed
# ---------------------------------------------------------------------------
T="$(mktemp -d)"
mkdir -p "$T/specs/live-demo"
printf '# Spec\n\nAn auth rewrite that also moves the settlement schema.\n' > "$T/specs/live-demo/spec.md"
printf '# Plan\n' > "$T/specs/live-demo/plan.md"
# WS-A hits security/auth paths, WS-B hits data/schema paths — two categories, two distinct roles.
printf '# Tasks\n\n## WS-A auth\n\n- [ ] T1 a\n  - file: src/auth/login.ts \xc2\xb7 (feat)\n\n## WS-B schema\n\n- [ ] T2 b\n  - file: db/migrations/002.sql \xc2\xb7 (feat)\n' \
  > "$T/specs/live-demo/tasks.md"
( cd "$T" || exit 1; git init -q; git config user.email a@b.c; git config user.name t
  printf 'x\n' > seed.txt; git add -A; git commit -q -m base ) >/dev/null 2>&1

_emit() { ( cd "$T" || exit 1; printf '%s' "$1" | "$here/bin/delivery-marker-init.sh" 2>/dev/null ); }

rm -rf "$T/.runs"
CTX="$(_emit '/team-bootstrap:deliver specs/live-demo' | _ctx_of)"

echo "AC-1 — additionalContext states all six mandated facts:"
_chk "$([ -n "$CTX" ] && echo nonempty || echo empty)" nonempty "additionalContext is non-empty"
# The four that v2.35.0 already delivers — asserted here so a regression on them is caught by THIS file
# too, not only by harness-context-delivery.test.sh.
for tok in 'for run ' 'Review depth:' 'tier_source=' 'marker='; do
  _chk "$(printf '%s' "$CTX" | grep -qF "$tok" && echo yes || echo no)" yes "states '$tok'"
done
# The two that are missing — the red of this file.
# NOT a bare 'risk categories' grep: the shipped text already contains the boilerplate phrase
# "the risk categories set composition", which would make this assertion pass without the fact
# ever being stated. Anchor on the Д2 Ф0.1 wording, which can only appear if the fact is emitted.
_chk "$(printf '%s' "$CTX" | grep -qiF 'Risk categories detected:' && echo yes || echo no)" yes \
  "states the DETECTED RISK CATEGORIES by name (AC-1)"
_chk "$(printf '%s' "$CTX" | grep -qiF 'assigned review roles' && echo yes || echo no)" yes \
  "states the ASSIGNED ROLE COMPOSITION (AC-1)"

echo "AC-1b — the stated categories are the ones the classifier actually found:"
_chk "$(printf '%s' "$CTX" | grep -qF 'security/auth' && echo yes || echo no)" yes \
  "the auth work-stream's category appears in the context"
_chk "$(printf '%s' "$CTX" | grep -qF 'data/schema' && echo yes || echo no)" yes \
  "the schema work-stream's category appears in the context"

echo "AC-1c — the stated roles are the ones those categories earn (profiles/default.map):"
_chk "$(printf '%s' "$CTX" | grep -qF 'security-reviewer' && echo yes || echo no)" yes \
  "security/auth ⇒ security-reviewer is named"
_chk "$(printf '%s' "$CTX" | grep -qF 'data-schema-reviewer' && echo yes || echo no)" yes \
  "data/schema ⇒ data-schema-reviewer is named"

echo "AC-1d — the same two facts are on the marker, so a later gate reads them without recomputing:"
MK="$(ls "$T"/.runs/*/RUN 2>/dev/null | head -1)"
_chk "$([ -n "$MK" ] && echo yes || echo no)" yes "a marker exists"
_chk "$(grep -qF '"risk_categories"' "$MK" 2>/dev/null && echo yes || echo no)" yes "marker carries risk_categories"
_chk "$(grep -qF '"assigned_roles"' "$MK" 2>/dev/null && echo yes || echo no)" yes "marker carries assigned_roles"

echo "AC-1e — no categories detected is stated as a fact, never as an absent field:"
mkdir -p "$T/specs/plain"
printf '# Spec\n\nA README wording change.\n' > "$T/specs/plain/spec.md"
printf '# Tasks\n\n## WS-A docs\n\n- [ ] T1 a\n  - file: README.md \xc2\xb7 (docs)\n' > "$T/specs/plain/tasks.md"
rm -rf "$T/.runs"
CTXP="$(_emit '/team-bootstrap:deliver specs/plain' | _ctx_of)"
_chk "$(printf '%s' "$CTXP" | grep -qiF 'Risk categories detected: none' && echo yes || echo no)" yes \
  "a run with no risk category still STATES that (none is not silence)"

echo "AC-1g — an empty result and an UNCOMPUTED result are different facts, never both \"none\":"
# tier_source=operator (the tier word is the FIRST argument) + a tasks.md with no `## ` headings ⇒
# neither the per-work-stream loop nor the
# harness branch consults the classifier. Saying "none" there would report a result that was never
# computed — the silent degradation AC-47 removed from the sizing path, re-entering via the context.
mkdir -p "$T/specs/uncomputed"
printf '# Spec\n\nA change.\n' > "$T/specs/uncomputed/spec.md"
printf '# Tasks\n\n- [ ] T1 a\n  - file: src/auth/login.ts\n' > "$T/specs/uncomputed/tasks.md"
rm -rf "$T/.runs"
CTXU="$(_emit '/team-bootstrap:deliver mvp specs/uncomputed' | _ctx_of)"
_chk "$(printf '%s' "$CTXU" | grep -qiF 'not computed' && echo yes || echo no)" yes \
  "an unconsulted classifier is reported as 'not computed', not as 'none'"
_chk "$(printf '%s' "$CTXU" | grep -qiE 'Risk categories detected: none' && echo yes || echo no)" no \
  "  …and never as the false fact 'none'"

echo "AC-1f — the additions do not break the phrasing or the ceiling:"
_chk "$(printf '%s' "$CTX" | grep -qiE '\b(you must|do not|never |always |ignore |disregard)' && echo imperative || echo factual)" factual \
  "still phrased as facts, not imperatives"
_chk "$([ "${#CTX}" -le 10000 ] && echo ok || echo over)" ok "still <= 10000 chars (len=${#CTX})"
rm -rf "$T"

# ---------------------------------------------------------------------------
# AC-3 — over the ceiling, SPILL to a file and hand over the path; never cut in silence
# ---------------------------------------------------------------------------
echo "AC-3 — emit_hook_context spills instead of truncating:"
S="$(mktemp -d)"
( cd "$S" || exit 1; git init -q; git config user.email a@b.c; git config user.name t
  printf 'x\n' > seed.txt; git add -A; git commit -q -m base ) >/dev/null 2>&1
mkdir -p "$S/.runs/spill"

BIG="$(PY 'print("category-" + "x"*40 + " ", end="")
print(("role-name-that-is-long " * 600), end="")')"
OUT="$( cd "$S" || exit 1
  TEAM_BOOTSTRAP_RUN=spill bash -c '
    . "$1/bin/delivery-lib.sh"
    emit_hook_context UserPromptSubmit "$(json_esc "$2")"' _ "$here" "$BIG" 2>/dev/null )"

_chk "$([ "${#BIG}" -gt 10000 ] && echo yes || echo no)" yes "the fixture really is over the ceiling (len=${#BIG})"
SPILLCTX="$(printf '%s' "$OUT" | _ctx_of)"
_chk "$([ -n "$SPILLCTX" ] && echo nonempty || echo empty)" nonempty "an over-length context still emits something"
_chk "$([ "${#SPILLCTX}" -le 10000 ] && echo ok || echo over)" ok "what is emitted respects the ceiling (len=${#SPILLCTX})"
_chk "$([ -f "$S/.runs/spill/context.txt" ] && echo yes || echo no)" yes \
  "the full text is written to .runs/<id>/context.txt (AC-3)"
_chk "$(printf '%s' "$SPILLCTX" | grep -qF 'context.txt' && echo yes || echo no)" yes \
  "the emitted context hands over the PATH to the spill file"
_chk "$(wc -c < "$S/.runs/spill/context.txt" 2>/dev/null | tr -d ' ')" "$(printf '%s' "$BIG" | wc -c | tr -d ' ')" \
  "the spill file holds the WHOLE text, not the cut"

echo "AC-3b — under the ceiling nothing spills and nothing changes:"
rm -f "$S/.runs/spill/context.txt"
SMALL="a short verdict"
OUT2="$( cd "$S" || exit 1
  TEAM_BOOTSTRAP_RUN=spill bash -c '
    . "$1/bin/delivery-lib.sh"
    emit_hook_context UserPromptSubmit "$(json_esc "$2")"' _ "$here" "$SMALL" 2>/dev/null )"
_chk "$(printf '%s' "$OUT2" | _ctx_of)" "$SMALL" "a short context is passed through verbatim"
_chk "$([ -f "$S/.runs/spill/context.txt" ] && echo yes || echo no)" no "no spill file is created below the ceiling"

echo "AC-3c — the spill is still valid JSON on one line:"
# printf '%s' drops the trailing newline that command substitution already stripped, so count the
# emission's own line breaks: exactly one line means zero embedded newlines.
_chk "$(printf '%s' "$OUT" | grep -c '' | tr -d ' ')" 1 "the over-length emission is exactly one line"
_chk "$(PY 'import json,sys
try:
    json.loads(sys.stdin.read()); print("valid")
except Exception: print("invalid")' <<<"$OUT")" valid "the over-length emission parses as JSON"
rm -rf "$S"

# ---------------------------------------------------------------------------
# AC-2 — the phrasing rule becomes a gate, not a habit
# ---------------------------------------------------------------------------
echo "AC-2 — check-context-phrasing.sh exists, self-tests, and is wired:"
_chk "$([ -x "$here/bin/check-context-phrasing.sh" ] && echo yes || echo no)" yes \
  "bin/check-context-phrasing.sh exists and is executable"
_chk "$( "$here/bin/check-context-phrasing.sh" --self-test >/dev/null 2>&1 && echo pass || echo fail )" pass \
  "check-context-phrasing.sh --self-test passes"
_chk "$( "$here/bin/check-context-phrasing.sh" "$here" >/dev/null 2>&1 && echo pass || echo fail )" pass \
  "the shipped additionalContext producers are clean under the gate"

echo "AC-2b — the gate actually catches an imperative (it is not a no-op):"
P="$(mktemp -d)"; mkdir -p "$P/bin"
cat > "$P/bin/bad-hook.sh" <<'EOS'
#!/usr/bin/env bash
_ctx="You must dispatch the security-reviewer before closing this batch."
printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"%s"}}\n' "$_ctx"
EOS
chmod +x "$P/bin/bad-hook.sh"
_chk "$( "$here/bin/check-context-phrasing.sh" "$P" >/dev/null 2>&1 && echo pass || echo fail )" fail \
  "an imperative additionalContext FAILS the gate"
rm -rf "$P"

# ---------------------------------------------------------------------------
# WS-C — the second wave: a role is dispatchable, attributable, TYPED, and routed by a real signal.
#
# Four roles have a playbook, a role-matrix row and a schema branch, and are invisible to the harness:
# no agents/<slug>.md means no subagent_type, and no required verdict field means nothing to confirm at
# closure. R2 is the reason the order is fixed — a dispatchable role with no confirmable verdict is one
# more way to dispatch a decoy, so the TYPE lands before the agent does.
#
# The routing signals come from Д2 §1.2, which supplies what the tree lacked: test-designer on a diff
# with no test file, the legal pair on licences and dependency manifests, chaos-engineer alongside
# devops-platform on infra/deploy.
# ---------------------------------------------------------------------------
WAVE2="chaos-engineer test-designer legal-compliance-checker ip-contracts-reviewer"

echo "AC-24 — every revived role declares its OWN required verdict field:"
for r in $WAVE2; do
  _chk "$(PY '
import json,sys
d=json.load(open("references/schemas/role-output.schema.json"))["$defs"].get(sys.argv[1],{})
req=[f for b in d.get("allOf",[]) for f in b.get("required",[])]
print("yes" if req else "no")' "$r")" yes "$r has a required field (confirmable at closure)"
done

echo "AC-24b — the required field is the ROLE own, never one inherited from base:"
_own="$(PY '
import json,sys
d=json.load(open("references/schemas/role-output.schema.json"))["$defs"]
base=set(d["base"].get("required",[]))
bad=[]
for r in sys.argv[1].split():
    req=[f for b in d[r].get("allOf",[]) for f in b.get("required",[])]
    if not [f for f in req if f not in base]:
        bad.append(r)
print(",".join(bad) or "none")' "$WAVE2")"
_chk "$_own" none "every wave-2 role names a field of its own"

echo "AC-9/AC-10 — the triple exists: agent + BOTH slug forms with attribution + playbook:"
for r in $WAVE2; do
  _chk "$([ -f "$here/agents/$r.md" ] && echo yes || echo no)" yes "$r: agents/$r.md exists"
  _chk "$(awk -F'\t' -v s="$r" '$1==s && $2!="" {f=1} END{exit !f}' "$here/references/review-types.txt" && echo yes || echo no)" yes \
    "$r: bare slug carries an attribution column"
  _chk "$(awk -F'\t' -v s="team-bootstrap:$r" '$1==s && $2!="" {f=1} END{exit !f}' "$here/references/review-types.txt" && echo yes || echo no)" yes \
    "$r: prefixed slug carries an attribution column"
  _chk "$([ -f "$here/references/roles/$r.md" ] && echo yes || echo no)" yes "$r: playbook exists"
done

echo "AC-8 — the agent body does not restate the playbook (single source of truth):"
for r in $WAVE2; do
  [ -f "$here/agents/$r.md" ] || continue
  _chk "$(grep -qF "references/roles/$r.md" "$here/agents/$r.md" && echo yes || echo no)" yes \
    "$r: the agent points at its playbook"
  _chk "$(awk 'BEGIN{fm=0} /^---$/{fm++; next} fm>=2 && NF>0 {n++} END{v=(n+0)<=40 ? "ok" : "over"; print v}' "$here/agents/$r.md")" ok \
    "$r: agent body is within the calibrated 40-line duplication ceiling"
done

echo "AC-12 — anti-builder invariant holds for every new slug (no builder is dispatchable as a reviewer):"
for r in $WAVE2; do
  [ -f "$here/references/roles/$r.md" ] || continue
  _chk "$(grep -qE '^[[:space:]]*deny:.*(Write|Edit)' "$here/references/roles/$r.md" && echo yes || echo no)" yes \
    "$r: the playbook denies Write/Edit"
done

echo "AC-10b — each new role is routed by a category the classifier actually emits:"
VOCAB="$("$here/bin/select-pipeline.sh" --categories 2>/dev/null)"
while read -r cat _rest; do
  case "$cat" in ''|'#'*) continue ;; esac
  _in=no; case " $VOCAB " in *" $cat "*) _in=yes ;; esac
  _chk "$_in" yes "profile category '$cat' is one select-pipeline emits"
done < "$here/profiles/default.map"

echo "AC-27 — every routed binding is ALIVE (removing it turns something red):"
_chk "$( "$here/bin/eval-role.sh" --liveness >/dev/null 2>&1 && echo alive || echo dead )" alive \
  "eval-role --liveness reports every binding load-bearing"

echo "AC-10c — the new slugs collide with nothing (R10):"
_chk "$(awk -F'\t' '!/^#/ && NF && $1!="" {print $1}' "$here/references/review-types.txt" | sort | uniq -d | tr '\n' ' ' | sed 's/ *$//')" "" \
  "no duplicate slug in review-types.txt"

# ---------------------------------------------------------------------------
# AC-29 — bin/tdd-red.sh is gone; the observation lives in the gate that consumes it.
#
# Д2 Фаза 4: "bin/tdd-red.sh удаляется (/test делает то же), check-tdd.sh остаётся, но наблюдает
# результат, а не воспроизводит его." The duplication is real — `/test` is how you REACH red, and a
# second script that also drives the suite is the Ф4 finding. What `/test` does NOT do is record the
# red anchored to a sha, and check-tdd.sh REQUIRES that record: deleting the producer without moving
# the observation makes every code batch fail closed with no way to satisfy the gate.
#
# So the observation moves INTO check-tdd.sh as `--record-red`. The driving is `/test`'s; the
# recording is the gate's; there is no second script.
# ---------------------------------------------------------------------------
echo "AC-29 — the separate driver script is gone and the gate carries the observation:"
_chk "$([ -e "$here/bin/tdd-red.sh" ] && echo present || echo absent)" absent "bin/tdd-red.sh is deleted"
_chk "$(grep -q -- '--record-red' "$here/bin/check-tdd.sh" && echo yes || echo no)" yes \
  "check-tdd.sh carries a --record-red entry point"
_chk "$( "$here/bin/check-tdd.sh" --self-test >/dev/null 2>&1 && echo pass || echo fail )" pass \
  "check-tdd --self-test still passes"

echo "AC-29b — --record-red REFUSES to record when the suite is green (no red, no record):"
R="$(mktemp -d)"
( cd "$R" || exit 1
  git init -q; git config user.email a@b.c; git config user.name t
  printf -- '- Test: `sh ./t.sh`\n' > AGENTS.md
  printf '#!/bin/sh\nexit 0\n' > t.sh; chmod +x t.sh
  mkdir -p tests .runs/r
  printf 'x\n' > tests/a.test.sh
  git add -A; git commit -q -m base
  printf '{"run":"r","pipeline":"mvp","intends_code":true,"baseline_sha":"%s"}\n' "$(git rev-parse HEAD)" > .runs/r/RUN
  TEAM_BOOTSTRAP_RUN=r bash "$here/bin/check-tdd.sh" --record-red --batch B1 >/dev/null 2>&1
  echo $? > rc; [ -f .runs/r/tdd.jsonl ] && echo yes > wrote || echo no > wrote )
_chk "$(cat "$R/wrote" 2>/dev/null)" no "a GREEN suite records nothing — you cannot record red when nothing failed"
_chk "$([ "$(cat "$R/rc" 2>/dev/null)" != "0" ] && echo nonzero || echo zero)" nonzero "  …and it says so with a non-zero exit"
rm -rf "$R"

echo "AC-29c — a real red IS recorded, anchored to the sha, and only from a committed test change:"
R="$(mktemp -d)"
( cd "$R" || exit 1
  git init -q; git config user.email a@b.c; git config user.name t
  printf -- '- Test: `sh ./t.sh`\n' > AGENTS.md
  printf '#!/bin/sh\nexit 0\n' > t.sh; chmod +x t.sh
  git add -A; git commit -q -m base
  BASE="$(git rev-parse HEAD)"
  mkdir -p tests .runs/r
  printf 'x\n' > tests/a.test.sh
  printf '#!/bin/sh\nexit 1\n' > t.sh                # the suite is now RED
  git add -A; git commit -q -m 'red test'
  printf '{"run":"r","pipeline":"mvp","intends_code":true,"baseline_sha":"%s"}\n' "$BASE" > .runs/r/RUN
  TEAM_BOOTSTRAP_RUN=r bash "$here/bin/check-tdd.sh" --record-red --batch B1 >/dev/null 2>&1
  echo $? > rc
  cat .runs/r/tdd.jsonl 2>/dev/null > rec || : )
_chk "$(cat "$R/rc" 2>/dev/null)" 0 "a red suite records successfully"
_chk "$(grep -q '"observed":"red"' "$R/rec" 2>/dev/null && echo yes || echo no)" yes "the record says observed=red"
_chk "$(grep -q '"red_sha"' "$R/rec" 2>/dev/null && echo yes || echo no)" yes "  …anchored to a git sha"
_chk "$(grep -q '"batch":"B1"' "$R/rec" 2>/dev/null && echo yes || echo no)" yes "  …and attributed to the batch"
rm -rf "$R"

echo "AC-29d — the self-test cases tdd-red.sh used to hold are not lost with the file:"
R="$(mktemp -d)"
( cd "$R" || exit 1
  git init -q; git config user.email a@b.c; git config user.name t
  printf -- '- Test: `sh ./t.sh`\n' > AGENTS.md
  printf '#!/bin/sh\nexit 1\n' > t.sh; chmod +x t.sh
  git add -A; git commit -q -m base
  BASE="$(git rev-parse HEAD)"
  mkdir -p .runs/r
  printf '{"run":"r","pipeline":"mvp","intends_code":true,"baseline_sha":"%s"}\n' "$BASE" > .runs/r/RUN
  # a red that changed NO committed test file
  printf 'x\n' > src.sh; git add -A; git commit -q -m 'code only'
  TEAM_BOOTSTRAP_RUN=r bash "$here/bin/check-tdd.sh" --record-red --batch B1 >/dev/null 2>&1; echo $? > rc_nontest
  # …and no Test: command at all
  printf -- '- Lint: `true`\n' > AGENTS.md; git add -A; git commit -q -m 'no test cmd'
  TEAM_BOOTSTRAP_RUN=r bash "$here/bin/check-tdd.sh" --record-red --batch B1 >/dev/null 2>&1; echo $? > rc_nocmd )
_chk "$(cat "$R/rc_nontest" 2>/dev/null)" 4 "a red that changed no committed test file is refused (F1)"
_chk "$(cat "$R/rc_nocmd" 2>/dev/null)" 3 "no Test: command ⇒ an honest exit 3, never a silent pass"
rm -rf "$R"

# ---------------------------------------------------------------------------
if [ "$fail" -eq 0 ]; then echo "live-roles-harness-wiring: OK"; exit 0; fi
echo "live-roles-harness-wiring: $fail check(s) FAILED" >&2; exit 1
