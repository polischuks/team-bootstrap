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
# Its --self-test is run once by run-tests' bin/*.sh --self-test sweep; re-running it here only re-forked
# it (issue #79 — the dedup #51 applied to gates-wiring). Assert the wiring fact (it declares a
# --self-test, so the sweep picks it up) instead of the re-run. The two behavioural checks this file
# UNIQUELY owns — the gate against this repo's shipped producers (next) and against a bad fixture
# (AC-2b) — are not re-runs of the self-test and stay.
_chk "$(grep -qE -- '(--self-test\)|= "--self-test" \]|=--self-test)' "$here/bin/check-context-phrasing.sh" && echo yes || echo no)" yes \
  "check-context-phrasing.sh declares a --self-test (run-tests runs it)"
# Dropping the re-runs here (and the check-tdd / check-version-sync self-test re-runs below) is safe ONLY
# because run-tests really sweeps every bin/*.sh --self-test. Assert that once, rather than assuming it.
_chk "$(grep -qE 'bin/\*\.sh|for f in .*bin' "$here/bin/run-tests.sh" && grep -q -- '--self-test' "$here/bin/run-tests.sh" && echo yes || echo no)" yes \
  "run-tests sweeps bin/*.sh --self-test (so this file need not re-run peer self-tests)"
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
  case "$cat" in ''|'#'*|tier:*) continue ;; esac   # tier: is the depth base, not a category
  _in=no; case " $VOCAB " in *" $cat "*) _in=yes ;; esac
  _chk "$_in" yes "profile category '$cat' is one select-pipeline emits"
done < "$here/profiles/default.map"

echo "AC-27 — every routed binding is ALIVE (removing it turns something red):"
# The eval that PROVES this — eval-role --liveness going red when a binding is not load-bearing — is a
# ~9s full-tree mutation over every binding. It is OWNED by two standalone members that run-tests already
# runs: tests/role-liveness.test.sh (asserts it is green on the shipped profile AND can say DEAD) and
# bin/check-role-liveness.sh (the P12 gate, swept via --self-test). Re-running the whole eval a third
# time here duplicated ~9s of work (issue #79). Assert instead that the canonical coverage EXISTS: if a
# dead binding is introduced, role-liveness.test.sh turns red — this file need not re-prove it.
_chk "$(grep -qE 'eval-role\.sh"? *--liveness' "$here/tests/role-liveness.test.sh" && echo yes || echo no)" yes \
  "AC-27 is owned by tests/role-liveness.test.sh (it runs eval-role --liveness; a dead binding reddens THERE)"
_chk "$(grep -q 'check-role-liveness.sh' "$here/bin/verify-batch.sh" && echo yes || echo no)" yes \
  "…and by the check-role-liveness gate, wired into verify-batch so every delivery re-checks liveness"

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
# check-tdd --self-test is run once by run-tests' sweep (asserted above); re-running it here only
# re-forked it (issue #79). Assert the wiring fact. The --record-red behaviour this AC actually cares
# about is exercised end-to-end in the fixtures below (AC-29b/c/d) — those are not self-test re-runs.
_chk "$(grep -qE -- '(--self-test\)|= "--self-test" \]|=--self-test)' "$here/bin/check-tdd.sh" && echo yes || echo no)" yes \
  "check-tdd.sh declares a --self-test (run-tests runs it)"

echo "AC-29e — no command playbook still instructs the deleted driver:"
# Deleting the producer while commands/deliver.md kept telling the model to run it left the red step
# of every code batch pointing at a script that does not exist. The instruction must name the gate's
# own entry point (check-tdd.sh --record-red); the deleted name may survive only in code comments and
# in this test's own history, never in a command playbook.
_chk "$(grep -l 'tdd-red' "$here/commands/"*.md 2>/dev/null | xargs -n1 basename 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')" "" \
  "no commands/*.md references bin/tdd-red.sh"
_chk "$(grep -q -- 'check-tdd.sh --record-red' "$here/commands/deliver.md" && echo yes || echo no)" yes \
  "deliver.md's red step instructs check-tdd.sh --record-red"

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
# WS-D — the tier stops deciding composition anywhere, and the per-role floor stops being advisory.
#
# AC-13: composition is read from the profile, not from a `case` in delivery-lib.sh. ADR-0020 split
# depth from composition and delivered only half of it: the risk categories moved to the profile while
# the tier's own BASE SET stayed a hardcoded three-branch case, which is the same "tier decides who
# reviews" the split was supposed to end — just smaller.
#
# AC-18/F4: the >=1 independent-reviewer floor is asserted AFTER the map is read, outside any profile's
# reach. A profile that ships an empty composition must not be able to size the anti-collapse floor away.
# ---------------------------------------------------------------------------
echo "AC-13 — no tier→roles case survives in delivery-lib.sh:"
# Scoped to the WHOLE file, not to required_roles_for_batch: batch 1 moved the case into
# tier_base_roles, which satisfies "no case in required_roles_for_batch" while leaving the mapping
# exactly as hardcoded as it was. An assertion that a refactor can satisfy by relocation is not an
# assertion about the property it names.
_chk "$(grep -qE "^ *(full|mvp)\)[[:space:]]+printf 'integration-verifier" "$here/bin/delivery-lib.sh" \
        && echo present || echo absent)" absent \
  "no hardcoded tier→roles list survives anywhere in delivery-lib.sh"
_chk "$(grep -qE '^tier:(full|mvp|single-thread)' "$here/profiles/default.map" && echo yes || echo no)" yes \
  "profiles/default.map carries tier: keys"

echo "AC-13b — changing the profile changes the base set (the mapping is really read from the file):"
_sized() { # $1=profile  $2=touch path → the sized role set for a code batch
  local D; D="$(mktemp -d)"
  ( cd "$D" || exit 1
    git init -q; git config user.email a@b.c; git config user.name t
    printf 'x\n' > seed.txt; git add -A; git commit -q -m base
    B="$(git rev-parse --short HEAD)"
    mkdir -p "$(dirname "$2")" .runs/r; printf 'z\n' > "$2"; git add -A; git commit -q -m work
    printf '{"run":"r","pipeline":"full","intends_code":true,"baseline_sha":"%s"}\n' "$B" > .runs/r/RUN
    printf '{"id":"B1","kind":"code","status":"announced"}\n' > .runs/r/batches.jsonl
    . "$here/bin/delivery-lib.sh"
    TEAM_BOOTSTRAP_PROFILE="$1" TEAM_BOOTSTRAP_RUN=r required_roles_for_batch B1 ) 2>/dev/null
  rm -rf "$D"
}
SHIPPED="$here/profiles/default.map"
_chk "$(printf '%s' "$(_sized "$SHIPPED" src/api/openapi.yaml)" | grep -qw architecture-reviewer && echo yes || echo no)" yes \
  "the shipped profile gives a full batch its architecture-reviewer"

ALT="$(mktemp)"
{ grep -v '^tier:' "$SHIPPED"; printf 'tier:full\tintegration-verifier code-reviewer\n'; } > "$ALT"
_chk "$(printf '%s' "$(_sized "$ALT" src/api/openapi.yaml)" | grep -qw architecture-reviewer && echo yes || echo no)" no \
  "an org profile that narrows tier:full really narrows it (the file is the source, not a mirror)"
rm -f "$ALT"

echo "AC-18/F4 — the >=1 floor is outside every profile's reach:"
EMPTY="$(mktemp)"; printf '# a profile that declares nothing at all\n' > "$EMPTY"
_chk "$(printf '%s' "$(_sized "$EMPTY" src/api/openapi.yaml)" | grep -qw code-reviewer && echo yes || echo no)" yes \
  "an EMPTY profile still yields the invariant floor — it cannot be sized away"
rm -f "$EMPTY"

# The case that matters now that the base list is org-editable. Before AC-13 the floor held only
# INCIDENTALLY: every branch of the hardcoded case happened to contain code-reviewer. A profile that
# names a base WITHOUT it would size the anti-collapse floor away — the exact thing F4 forbids — so
# the floor has to be asserted in code, after the map is read, or moving the list to a file removes it.
HOSTILE="$(mktemp)"
{ grep -v '^tier:' "$SHIPPED"; printf 'tier:full\tintegration-verifier\n'; } > "$HOSTILE"
_chk "$(printf '%s' "$(_sized "$HOSTILE" src/api/openapi.yaml)" | grep -qw code-reviewer && echo yes || echo no)" yes \
  "a profile that OMITS the floor role from its base still gets it back (F4 is code, not luck)"
rm -f "$HOSTILE"

echo "AC-17 — a profile that cannot answer fails CLOSED (strictest), never to an empty set:"
NOTIER="$(mktemp)"; grep -v '^tier:' "$SHIPPED" > "$NOTIER"
NT="$(_sized "$NOTIER" src/x.ts)"
_chk "$([ -n "$NT" ] && echo nonempty || echo empty)" nonempty "a profile with no tier: key never yields an empty set"
_chk "$(printf '%s' "$NT" | grep -qw architecture-reviewer && echo yes || echo no)" yes \
  "  …it falls back to the STRICTEST base (enforce until we know), not the lightest"
rm -f "$NOTIER"

# An ANSWERLESS key — `tier:full` with only whitespace after it — is not an answer. Treating it as one
# would hand back a blank base, which is the silent empty set the fallback exists to prevent.
BLANK="$(mktemp)"; { grep -v '^tier:' "$SHIPPED"; printf 'tier:full\t   \n'; } > "$BLANK"
_chk "$(printf '%s' "$(_sized "$BLANK" src/api/openapi.yaml)" | grep -qw architecture-reviewer && echo yes || echo no)" yes \
  "a tier: key with a whitespace-only value falls back to the strictest base, not to blank"
rm -f "$BLANK"

echo "AC-26 — the per-role floor enforces by default:"
_chk "$([ -f "$here/references/role-dispatch-enforce" ] && echo yes || echo no)" yes \
  "references/role-dispatch-enforce is committed"
_chk "$( . "$here/bin/delivery-lib.sh"; role_floor_mode )" enforce \
  "role_floor_mode reports enforce with no env override"

# ---------------------------------------------------------------------------
# WS-E — the documentation stops disagreeing with the code, and silent degradation gets a gate.
# ---------------------------------------------------------------------------
echo "AC-37 — a version literal in README.md cannot drift from VERSION:"
_chk "$(grep -q 'README' "$here/bin/check-version-sync.sh" && echo yes || echo no)" yes \
  "check-version-sync.sh covers README.md"
# check-version-sync --self-test is run once by run-tests' sweep (asserted above); re-running it here
# only re-forked it (issue #79). The README-coverage fact this AC names is the grep on the line above;
# assert the wiring fact here instead of re-running the whole self-test.
_chk "$(grep -qE -- '(--self-test\)|= "--self-test" \]|=--self-test)' "$here/bin/check-version-sync.sh" && echo yes || echo no)" yes \
  "check-version-sync.sh declares a --self-test (run-tests runs it, with the README case)"
_p8=no
grep -qF 'P1–P8' "$here/README.md" && _p8=yes
grep -qF 'P1-P8' "$here/README.md" && _p8=yes
_chk "$_p8" no "README does not still advertise P1-P8 (the constitution reaches P12)"

echo "AC-48 — a script that returns emptiness instead of a decision declares why:"
_chk "$(grep -q 'silent-degradation\|SILENT DEGRADATION' "$here/bin/check-gate-integrity.sh" && echo yes || echo no)" yes \
  "check-gate-integrity carries the silent-degradation audit"
D="$(mktemp -d)"; mkdir -p "$D/bin"
# A gate that returns 0 with no output and no recorded reason is the shape AC-48 refuses.
cat > "$D/bin/check-quiet.sh" <<'EOS'
#!/usr/bin/env bash
[ -f nothing ] || exit 0
EOS
chmod +x "$D/bin/check-quiet.sh"
_chk "$( "$here/bin/check-gate-integrity.sh" "$D" >/dev/null 2>&1 && echo pass || echo fail )" fail \
  "a check-*.sh that exits 0 on an unmet precondition without saying so is caught"
# …and the same script with a stated reason passes.
cat > "$D/bin/check-quiet.sh" <<'EOS'
#!/usr/bin/env bash
[ -f nothing ] || { echo "check-quiet: skipping — no 'nothing' file in this project (reason recorded)."; exit 0; }
EOS
_chk "$( "$here/bin/check-gate-integrity.sh" "$D" >/dev/null 2>&1 && echo pass || echo fail )" pass \
  "  …and the same skip WITH a stated reason passes"
rm -rf "$D"

echo "AC-32/33 — the docs state what the code does:"
_chk "$(grep -qiE '^\| *(Layer|Слой) *\|' "$here/ARCHITECTURE.md" && echo yes || echo no)" yes \
  "ARCHITECTURE.md carries the layer → who → what table"
_chk "$(grep -q 'four Claude Code hook points' "$here/SECURITY.md" && echo stale || echo current)" current \
  "SECURITY.md no longer says four hook points"
_chk "$(python3 -c "
import json
n=len(json.load(open('$here/hooks/hooks.json'))['hooks'])
import re
t=open('$here/SECURITY.md').read()
print('yes' if str(n) in t else 'no')")" yes "  …it states the real number of registered events"

echo "AC-34/AC-46 — the two deferred decisions are ADRs, not assumptions:"
_chk "$(ls "$here/docs/adr/"*containment* >/dev/null 2>&1 && echo yes || echo no)" yes "ADR on the containment posture exists"
_chk "$(ls "$here/docs/adr/"*task-events* >/dev/null 2>&1 && echo yes || echo no)" yes "ADR on native Task events exists"

echo "AC-44/AC-45 — the vendor facts that change what a gate can promise are written down:"
_chk "$(grep -qi 'timeout' "$here/references/hooks.md" && grep -qi 'does not block' "$here/references/hooks.md" && echo yes || echo no)" yes \
  "references/hooks.md records that a PreToolUse hook timeout does not block"
_chk "$(grep -q 'allowManagedHooksOnly' "$here/INSTALL.md" && echo yes || echo no)" yes \
  "INSTALL.md documents the managed-policy path"

echo "AC-6 — no step REQUIRES the model to read the marker to learn its assignment:"
# This assertion USED TO PASS while deliver.md:19 said, verbatim, "Read the verdict out of the run
# marker". The pattern was `read (the )?(run )?marker`, which demands the words be adjacent, and the
# real sentence has "the verdict out of" between them. A test whose pattern cannot match the line it
# was written to catch is decoration — it certified this AC as met for a whole milestone.
#
# Two traps in the correction itself, both hit before this settled:
#   * `read` without \b matches the middle of "already", so every "already" scored a hit;
#   * `bin/delivery-marker-init.sh` contains "marker", so naming the script in a sentence that also
#     contains "read" looked like an instruction to go and read the marker. Code spans are stripped.
_ac6() { sed 's/`[^`]*`//g' "$1" | grep -cEi '\bread\b[^.]{0,40}\bmarker\b|\bread\b[^.]{0,40}\.runs/[^ ]*/RUN' | tr -d ' '; }
_chk "$(_ac6 "$here/commands/deliver.md")" 0 "deliver.md carries no obligation to read the marker for the verdict"

echo "AC-6b — that assertion can actually fail (it certified a false pass for a whole milestone):"
_poison="$(mktemp)"
printf 'Read the verdict out of the run marker (pipeline, tier_source); do not recompute it.\n' > "$_poison"
_chk "$(_ac6 "$_poison")" 1 "the real sentence that slipped through is caught now"
printf 'The harness has already decided by the time you read this.\n' > "$_poison"
_chk "$(_ac6 "$_poison")" 0 "  …and \"already\" + \"read this\" is not a false positive"
rm -f "$_poison"

# ---------------------------------------------------------------------------
# Observed live on run 176-withgauge-platform-integration (2026-08-27). Two defects, one shape:
# the harness states a WEAKER fact than the one it acted on.
# ---------------------------------------------------------------------------
echo "AC-1h — a DEGRADED sizing is 'not computed', never 'none':"
# size-from-spec returns `degraded=1 reason=no-tasks-md` — non-empty output, so sel_ran was set and the
# context printed "Risk categories detected: none". The classifier did not classify anything; reporting
# none is a computed result that was never computed. Same defect AC-1g fixed for the UNCONSULTED case,
# walking straight through the DEGRADED branch.
G="$(mktemp -d)"; mkdir -p "$G/specs/degraded"
printf '# Spec\n\nAn auth rewrite touching src/auth/login.ts.\n' > "$G/specs/degraded/spec.md"
# No tasks.md at all ⇒ size-from-spec degrades.
( cd "$G" || exit 1; git init -q; git config user.email a@b.c; git config user.name t
  printf 'x\n' > seed.txt; git add -A; git commit -q -m base ) >/dev/null 2>&1
CTXD="$( cd "$G" || exit 1; printf '%s' '/team-bootstrap:deliver specs/degraded' \
        | "$here/bin/delivery-marker-init.sh" 2>/dev/null | _ctx_of )"
_chk "$(printf '%s' "$CTXD" | grep -qiF 'Risk categories detected: not computed' && echo yes || echo no)" yes \
  "a degraded sizing reports 'not computed'"
_chk "$(printf '%s' "$CTXD" | grep -qiF 'Risk categories detected: none' && echo yes || echo no)" no \
  "  …and never the false fact 'none'"
_chk "$(printf '%s' "$CTXD" | grep -qiF 'DEGRADED' && echo yes || echo no)" yes \
  "  …and still states the degradation and its reason"

echo "AC-16b — an UNRESOLVED tier buys the STRICTEST depth, not the shallowest:"
# The same marker said "every tier-reading gate fails closed until Phase A resolves it" AND
# "Review depth: low". Fail-closed means strictest; AC-13 applied that to tier_base_roles and the depth
# mapping was left answering `auto` with the shallowest level the scale has.
_depth_of() { ( . "$here/bin/delivery-lib.sh"; review_depth_for_tier "$1" ); }
_chk "$(_depth_of full)" high "full ⇒ high (unchanged)"
_chk "$(_depth_of mvp)" medium "mvp ⇒ medium (unchanged)"
_chk "$(_depth_of single-thread)" low "single-thread ⇒ low — a RESOLVED light tier really is light"
_chk "$(_depth_of auto)" high "auto ⇒ high — unresolved means enforce until we know"
_chk "$(_depth_of '')" high "an empty tier ⇒ high, never a shallow default"
_chk "$(_depth_of nonsense-tier)" high "an unrecognised tier ⇒ high"

echo "AC-16c — the marker states the same depth the library computes (one mapping, not two):"
_chk "$(grep -cE '_depth=(high|medium|low)' "$here/bin/delivery-marker-init.sh" | tr -d ' ')" 0 \
  "delivery-marker-init.sh carries no second copy of the depth mapping"
CTXD2="$( cd "$G" || exit 1; rm -rf .runs; printf '%s' '/team-bootstrap:deliver specs/degraded' \
         | "$here/bin/delivery-marker-init.sh" 2>/dev/null | _ctx_of )"
_chk "$(printf '%s' "$CTXD2" | grep -qF 'Review depth: high' && echo yes || echo no)" yes \
  "an unresolved run states depth=high in the context, matching its fail-closed gates"
rm -rf "$G"

# ---------------------------------------------------------------------------
# Observed on run 176-withgauge-platform-integration (2026-08-27), Phase A onward.
# ---------------------------------------------------------------------------
echo "AC-19b — a declared role is VALIDATED; an unknown word is ignored with a record:"
# `⚠ <word>` was unioned into the required set unvalidated. The observed tasks.md carried, in its
# CONVENTIONS legend, "`⚠ reviewer` where a review lens is load-bearing" — the harness read the
# documentation OF the notation as a USE of it and assigned a role called `reviewer`: no playbook, no
# agent, no slug, nothing that can dispatch it. Same discipline judge-tier already applies to a tier
# word it does not recognise: no guess, and say so.
V="$(mktemp -d)"; mkdir -p "$V/specs/decl"
printf '# Spec\n\nA change.\n' > "$V/specs/decl/spec.md"
printf '# Tasks\n\n## Conventions\n\n- `\xe2\x9a\xa0 reviewer` where a review lens is load-bearing.\n\n## WS-A\n\n- [ ] T1 a `src/auth/x.ts` \xe2\x9a\xa0 security-reviewer\n- [ ] T2 b `src/auth/y.ts` \xe2\x9a\xa0 not-a-role\n' \
  > "$V/specs/decl/tasks.md"
( cd "$V" || exit 1; git init -q; git config user.email a@b.c; git config user.name t
  printf 'x\n' > seed.txt; git add -A; git commit -q -m base ) >/dev/null 2>&1
ROUT="$( cd "$V" || exit 1; bash "$here/bin/size-from-spec.sh" specs/decl 2>/dev/null | sed -n 's/^roles=//p' )"
_chk "$(printf '%s' "$ROUT" | grep -qw security-reviewer && echo yes || echo no)" yes \
  "a REAL declared role is still honoured"
# NOT `grep -w reviewer`: `-` is a word boundary, so that matches code-reviewer and data-schema-reviewer
# and would pass whatever the code did. Compare whole tokens.
_has_token() { printf '%s' "$1" | tr ' ' '\n' | grep -qx "$2"; }
_chk "$(_has_token "$ROUT" reviewer && echo yes || echo no)" no \
  "the legend's '⚠ reviewer' does not become an assignment"
_chk "$(_has_token "$ROUT" not-a-role && echo yes || echo no)" no \
  "an unknown word after ⚠ is not assigned"
_chk "$(_has_token "$ROUT" code-reviewer && echo yes || echo no)" yes \
  "  …and the token check can still SEE a real role (it is not vacuously false)"
RSN="$( cd "$V" || exit 1; bash "$here/bin/size-from-spec.sh" specs/decl 2>/dev/null | sed -n 's/^reasons=//p' )"
_chk "$(printf '%s' "$RSN" | grep -qF 'declared-unknown' && echo yes || echo no)" yes \
  "  …and the rejection is RECORDED, not silent"

echo "AC-47b — a task id wrapped in markdown emphasis still counts:"
printf '# Tasks\n\n## WS-A\n\n' > "$V/specs/decl/tasks.md"
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13; do
  printf -- '- [ ] **T%03d** `[B0]` work on `src/a%s.ts`\n' "$i" "$i" >> "$V/specs/decl/tasks.md"
done
_chk "$( cd "$V" || exit 1; bash "$here/bin/size-from-spec.sh" specs/decl 2>/dev/null | sed -n 's/^tasks=//p' )" 13 \
  "bold-wrapped task ids are counted (the observed tasks.md reported 0 of 30+)"
rm -rf "$V"

echo "AC-1i — the 'not computed' reason distinguishes NOT CONSULTED from DEGRADED:"
G2="$(mktemp -d)"; mkdir -p "$G2/specs/dg"
printf '# Spec\n\nA change.\n' > "$G2/specs/dg/spec.md"
( cd "$G2" || exit 1; git init -q; git config user.email a@b.c; git config user.name t
  printf 'x\n' > seed.txt; git add -A; git commit -q -m base ) >/dev/null 2>&1
CTXG="$( cd "$G2" || exit 1; printf '%s' '/team-bootstrap:deliver specs/dg' \
        | "$here/bin/delivery-marker-init.sh" 2>/dev/null | _ctx_of )"
_chk "$(printf '%s' "$CTXG" | grep -qiF 'could not classify' && echo yes || echo no)" yes \
  "a classifier that RAN and degraded says so, not 'was not consulted'"
rm -rf "$G2"

echo "AC-25b — a DEGRADED sizing is recomputed when the artefacts arrive:"
# The root defect, observed on run 176-withgauge-platform-integration. The marker is written ONCE, on
# the first arm — and for a description-form run that moment is always BEFORE Phase A produces
# tasks.md, so the sizing degrades. Re-arms then take the `[ -f "$marker" ]` branch, re-state the
# stored context and exit, so the degraded verdict never recovers: the run stays `pipeline=auto`
# forever while a perfectly sizable tasks.md sits on disk beside it. That is why the observed run had
# its marker hand-edited — the orchestrator was doing the harness's job because the harness had
# stopped doing it.
E="$(mktemp -d)"; mkdir -p "$E/specs/ed"
printf '# Spec\n\nAn auth change.\n' > "$E/specs/ed/spec.md"
( cd "$E" || exit 1; git init -q; git config user.email a@b.c; git config user.name t
  printf 'x\n' > seed.txt; git add -A; git commit -q -m base ) >/dev/null 2>&1
# First arm: no tasks.md yet — exactly Phase A's starting state.
( cd "$E" || exit 1; printf '%s' '/team-bootstrap:deliver specs/ed' | "$here/bin/delivery-marker-init.sh" >/dev/null 2>&1 )
_chk "$(python3 -c "import json;print(json.load(open('$E/.runs/ed/RUN'))['pipeline'])")" auto \
  "first arm with no tasks.md ⇒ pipeline=auto (unchanged)"
_chk "$(python3 -c "import json;print(json.load(open('$E/.runs/ed/RUN')).get('sizing_degraded',''))")" no-tasks-md \
  "  …and the degradation is recorded"

# Phase A produces the artefacts, and some OTHER gate has meanwhile written to the marker.
printf '# Tasks\n\n## WS-A\n\n- [ ] T1 a `src/auth/x.ts`\n' > "$E/specs/ed/tasks.md"
python3 - "$E/.runs/ed/RUN" <<'PYE'
import json,sys
p=sys.argv[1]; m=json.load(open(p))
m['preflight']={'exit':0,'gaps':[],'ack':True}; m['repro_env']=['container:docker']
json.dump(m, open(p,'w'))
PYE
CTXR="$( cd "$E" || exit 1; printf '%s' '/team-bootstrap:deliver specs/ed' \
        | "$here/bin/delivery-marker-init.sh" 2>/dev/null | _ctx_of )"
_chk "$(python3 -c "import json;print(json.load(open('$E/.runs/ed/RUN'))['pipeline'])")" full \
  "a re-arm RESIZES once the artefacts exist — the run stops being stuck at auto"
_chk "$(python3 -c "import json;print(json.load(open('$E/.runs/ed/RUN')).get('sizing_degraded',''))")" "" \
  "  …and the degradation is cleared"
_chk "$(printf '%s' "$CTXR" | grep -qiF 're-sized' && echo yes || echo no)" yes \
  "  …and the context says the run was re-sized, rather than silently changing under the reader"

echo "AC-25c — the re-size preserves every field the hook does not own:"
_chk "$(python3 -c "import json;print(json.load(open('$E/.runs/ed/RUN')).get('preflight',{}).get('ack'))")" True \
  "another gate's preflight ack survives"
_chk "$(python3 -c "import json;print(','.join(json.load(open('$E/.runs/ed/RUN')).get('repro_env',[])))")" "container:docker" \
  "another gate's repro_env survives"
_chk "$(python3 -c "import json;m=json.load(open('$E/.runs/ed/RUN'));print(m.get('baseline_sha','')!='')")" True \
  "baseline_sha survives (the standing never-clobber invariant)"

echo "AC-25d — an already-sized run is not re-sized on every prompt:"
B1="$(python3 -c "import json;print(json.load(open('$E/.runs/ed/RUN'))['baseline_sha'])")"
CTXQ="$( cd "$E" || exit 1; printf '%s' '/team-bootstrap:deliver specs/ed' \
        | "$here/bin/delivery-marker-init.sh" 2>/dev/null | _ctx_of )"
_chk "$(printf '%s' "$CTXQ" | grep -qiF 're-sized' && echo yes || echo no)" no \
  "a run whose sizing already succeeded says nothing about re-sizing"
_chk "$(python3 -c "import json;print(json.load(open('$E/.runs/ed/RUN'))['baseline_sha'])")" "$B1" \
  "  …and its baseline is untouched"
rm -rf "$E"

# ---------------------------------------------------------------------------
if [ "$fail" -eq 0 ]; then echo "live-roles-harness-wiring: OK"; exit 0; fi
echo "live-roles-harness-wiring: $fail check(s) FAILED" >&2; exit 1
