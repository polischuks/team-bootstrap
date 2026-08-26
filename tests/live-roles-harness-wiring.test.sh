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
if [ "$fail" -eq 0 ]; then echo "live-roles-harness-wiring: OK"; exit 0; fi
echo "live-roles-harness-wiring: $fail check(s) FAILED" >&2; exit 1
