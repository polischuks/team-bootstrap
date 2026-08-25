#!/usr/bin/env bash
# harness-context-delivery.test.sh — the harness's sizing verdict reaches the MODEL, and the role set is
# fixed by CODE where the diff exists (Google-doc §5 steps 1–2; audit table rows 3, 6, 7).
#
# Two defects, one cause: the policy layer decides and has no channel to deliver the decision.
#
#   Step 1 — delivery-marker-init.sh printed its verdict to STDERR at exit 0. Per the hooks reference,
#            stdout on UserPromptSubmit is injected as context; stderr at exit 0 goes to the debug log
#            only. So the model never saw the tier it is expected to honour, and .runs/<id>/RUN — a
#            format built for scripts — was the only carrier (SWE-agent ACI: an interface designed for
#            scripts requires the model to VOLUNTEER to read it).
#   Step 2 — record_required_roles was requested in commands/deliver.md PROSE, at announce, where the
#            batch window is still empty. check-role-dispatch.sh:106 says so in its own comment: nothing
#            wired it, which made the whole recorded-set (enforce) branch unreachable in production.
#
# Written BEFORE the fix → red, then green.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
_chk() { if [ "$1" = "$2" ]; then printf '  PASS %s\n' "$3"
  else printf '  FAIL %s (got [%s] want [%s])\n' "$3" "$1" "$2" >&2; fail=$((fail + 1)); fi; }

PY() { python3 -c "$1" "${@:2}"; }

# ---------------------------------------------------------------------------
# Step 1 — the UserPromptSubmit context channel
# ---------------------------------------------------------------------------
T="$(mktemp -d)"
mkdir -p "$T/specs/ctx-demo"
printf '# Spec\n\nAn exactly-once distributed settlement calculation across two services.\n' > "$T/specs/ctx-demo/spec.md"
printf '# Plan\n' > "$T/specs/ctx-demo/plan.md"
printf '# Tasks\n\n## WS-A payment API\n\n- [ ] T1 a\n  - file: src/api/pay.ts · (feat)\n\n## WS-B settlement schema\n\n- [ ] T2 b\n  - file: db/schema.sql · (feat)\n' > "$T/specs/ctx-demo/tasks.md"
( cd "$T" || exit 1; git init -q; git config user.email a@b.c; git config user.name t
  printf 'x\n' > seed.txt; git add -A; git commit -q -m base ) >/dev/null 2>&1

# _emit PROMPT → the hook's STDOUT (the context channel), stderr discarded
_emit() { ( cd "$T" || exit 1; printf '%s' "$1" | "$here/bin/delivery-marker-init.sh" 2>/dev/null ); }
_rc()   { ( cd "$T" || exit 1; printf '%s' "$1" | "$here/bin/delivery-marker-init.sh" >/dev/null 2>&1 ); echo $?; }

echo "AC-1 — the verdict is delivered on the sanctioned channel (stdout JSON), not stderr:"
rm -rf "$T/.runs"
OUT="$(_emit '/team-bootstrap:deliver specs/ctx-demo')"
_chk "$([ -n "$OUT" ] && echo nonempty || echo empty)" nonempty "stdout is not empty on an armed run"
_chk "$(printf '%s' "$OUT" | sed -e 's/^[[:space:]]*//' | cut -c1)" '{' "first non-whitespace char is '{' (the JSON path of the parser)"
_chk "$(PY 'import json,sys
try:
    json.loads(sys.stdin.read()); print("valid")
except Exception: print("invalid")' <<<"$OUT")" valid "stdout parses as JSON"
_chk "$(PY 'import json,sys
d=json.loads(sys.stdin.read()).get("hookSpecificOutput",{})
print(d.get("hookEventName","<absent>"))' <<<"$OUT")" UserPromptSubmit "hookEventName is UserPromptSubmit"

CTX="$(PY 'import json,sys
print(json.loads(sys.stdin.read()).get("hookSpecificOutput",{}).get("additionalContext",""))' <<<"$OUT")"
_chk "$([ -n "$CTX" ] && echo nonempty || echo empty)" nonempty "additionalContext is non-empty"

echo "AC-2 — the context states the facts the model needs to honour the tier:"
for tok in 'ctx-demo' 'pipeline=' 'tier_source='; do
  _chk "$(printf '%s' "$CTX" | grep -qF "$tok" && echo yes || echo no)" yes "context states '$tok'"
done

echo "AC-3 — the per-work-stream role plan travels with it (not only the marker file):"
_chk "$(printf '%s' "$CTX" | grep -qiE 'ws[-=]|work.stream' && echo yes || echo no)" yes "context carries the work-stream plan"

echo "AC-4 — the verdict survives a SECOND prompt (idempotent path re-states it; compaction-safe):"
OUT2="$(_emit '/team-bootstrap:deliver specs/ctx-demo')"
CTX2="$(PY 'import json,sys
try: print(json.loads(sys.stdin.read()).get("hookSpecificOutput",{}).get("additionalContext",""))
except Exception: print("")' <<<"$OUT2")"
_chk "$([ -n "$CTX2" ] && echo nonempty || echo empty)" nonempty "marker already exists → context is STILL emitted"
_chk "$(printf '%s' "$CTX2" | grep -qF 'pipeline=' && echo yes || echo no)" yes "  …and still states the pipeline"

echo "AC-5 — phrased as FACTS (imperative phrasing trips the prompt-injection defence):"
_chk "$(printf '%s' "$CTX" | grep -qiE '\b(you must|do not|never |always |ignore |disregard|instruction)' && echo imperative || echo factual)" factual \
  "no imperative/out-of-band phrasing in additionalContext"

echo "AC-6 — the documented 10 000-character ceiling is respected:"
_chk "$([ "${#CTX}" -le 10000 ] && echo ok || echo over)" ok "additionalContext is <= 10000 chars (len=${#CTX})"

echo "AC-3b — a spec with NO work-stream sections still gets the verdict (plan optional, verdict not):"
mkdir -p "$T/specs/flat"
printf '# Spec\n\nA small change.\n' > "$T/specs/flat/spec.md"
printf '# Tasks\n\n- [ ] T1 a\n  - file: bin/a.sh \u00b7 (feat)\n' > "$T/specs/flat/tasks.md"
rm -rf "$T/.runs"
CTX3="$(PY 'import json,sys
try: print(json.loads(sys.stdin.read()).get("hookSpecificOutput",{}).get("additionalContext",""))
except Exception: print("")' <<<"$(_emit '/team-bootstrap:deliver specs/flat')")"
_chk "$(printf '%s' "$CTX3" | grep -qF 'pipeline=' && echo yes || echo no)" yes "no WS sections → context still states the pipeline"

echo "AC-7 — an unrelated prompt is never touched (no context, no marker, never blocks):"
rm -rf "$T/.runs"
_chk "$(_emit 'what does this repo do?')" "" "non-delivery prompt → stdout stays EMPTY"
_chk "$(_rc 'what does this repo do?')" 0 "non-delivery prompt → exit 0"
_chk "$(_rc '/team-bootstrap:deliver specs/ctx-demo')" 0 "armed prompt → exit 0 (never blocks)"
rm -rf "$T"

# ---------------------------------------------------------------------------
# Step 2 — the role set is fixed by CODE, where the diff exists
# ---------------------------------------------------------------------------
echo "AC-8 — commands/deliver.md no longer asks the MODEL to record the set at announce:"
_chk "$(grep -qE 'record_required_roles[^a-z]' "$here/commands/deliver.md" && echo present || echo absent)" absent \
  "deliver.md carries no record_required_roles instruction (prose lands ~70%, code ~100%)"

echo "AC-9 — verify-batch.sh records it in code, BEFORE the role-dispatch gate reads it:"
_chk "$(grep -qE '(^|[^a-z_])record_required_roles' "$here/bin/verify-batch.sh" && echo yes || echo no)" yes \
  "verify-batch.sh invokes record_required_roles"
_rec_ln="$(grep -nE '(^|[^a-z_])record_required_roles' "$here/bin/verify-batch.sh" | head -1 | cut -d: -f1)"
# anchor on the gate INVOCATION, not on any mention of the script (a comment naming it is not a call)
_gate_ln="$(grep -n '^gate "role-dispatch' "$here/bin/verify-batch.sh" | head -1 | cut -d: -f1)"
_chk "$([ -n "$_rec_ln" ] && [ -n "$_gate_ln" ] && [ "$_rec_ln" -lt "$_gate_ln" ] && echo before || echo after)" before \
  "the record happens BEFORE the check-role-dispatch gate (${_rec_ln:-?} < ${_gate_ln:-?})"

echo "AC-10 — behaviour: a batch closed WITHOUT any orchestrator call gains required_roles:"
T2="$(mktemp -d)"
( cd "$T2" || exit 1
  git init -q; git config user.email a@b.c; git config user.name t
  printf 'x\n' > seed.txt; git add -A; git commit -q -m base
  BASE="$(git rev-parse --short HEAD)"
  mkdir -p src/api .runs/r
  printf 'export const pay = 1\n' > src/api/pay.ts; git add -A; git commit -q -m work
  printf '{"run":"r","pipeline":"full","intends_code":true,"source":"harness","baseline_sha":"%s"}\n' "$BASE" > .runs/r/RUN
  printf '{"id":"B1","kind":"code","status":"announced","risk_rank":"reversible"}\n' > .runs/r/batches.jsonl
) >/dev/null 2>&1
( cd "$T2" || exit 1; TEAM_BOOTSTRAP_RUN=r "$here/bin/verify-batch.sh" ) >/dev/null 2>&1 || true
_chk "$(grep -q '"required_roles"' "$T2/.runs/r/batches.jsonl" 2>/dev/null && echo recorded || echo absent)" recorded \
  "verify-batch recorded required_roles on the in-flight entry with no orchestrator involvement"
rm -rf "$T2"

[ "$fail" -eq 0 ] && { echo "harness-context-delivery.test.sh: OK"; exit 0; }
echo "harness-context-delivery.test.sh: $fail failure(s)" >&2; exit 1
