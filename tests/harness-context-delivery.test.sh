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

# ---------------------------------------------------------------------------
# Step 3 — SubagentStart: hand the role its plan, in ITS OWN context
# ---------------------------------------------------------------------------
# SubagentStart cannot block (established), so this channel CANNOT push review inline — the spec-169
# collapse a PreToolUse[Agent|Task] gate would risk is excluded by construction, not by discipline.
# Its additionalContext is addressed to the SUBAGENT, not the parent, which is exactly what "hand the
# role its brief" needs.
BRIEF="$here/bin/subagent-brief.sh"

echo "AC-11 — the hook exists and is registered on SubagentStart:"
_chk "$([ -x "$BRIEF" ] && echo yes || echo no)" yes "bin/subagent-brief.sh is executable"
_chk "$(PY 'import json,sys
h=json.load(open(sys.argv[1]))["hooks"]
print("yes" if "SubagentStart" in h else "no")' "$here/hooks/hooks.json")" yes "hooks.json registers SubagentStart"
_chk "$(PY 'import json,sys
h=json.load(open(sys.argv[1]))["hooks"].get("SubagentStart",[])
cmds=[c.get("command","") for g in h for c in g.get("hooks",[])]
print("yes" if any("subagent-brief" in c for c in cmds) else "no")' "$here/hooks/hooks.json")" yes "  …pointing at subagent-brief.sh"
_chk "$(PY 'import json,sys
h=json.load(open(sys.argv[1]))["hooks"].get("SubagentStart",[])
t=[c.get("type","command") for g in h for c in g.get("hooks",[])]
print(",".join(sorted(set(t))))' "$here/hooks/hooks.json")" command "  …as a command handler (prompt/agent support here is unconfirmed)"

T3="$(mktemp -d)"
( cd "$T3" || exit 1
  git init -q; git config user.email a@b.c; git config user.name t
  printf 'x\n' > seed.txt; git add -A; git commit -q -m base
  BASE="$(git rev-parse --short HEAD)"
  mkdir -p src/api .runs/r
  printf 'export const pay = 1\n' > src/api/pay.ts; git add -A; git commit -q -m work
  printf '{"run":"r","pipeline":"full","intends_code":true,"source":"harness","baseline_sha":"%s"}\n' "$BASE" > .runs/r/RUN
  printf '{"id":"B1","kind":"code","status":"announced","risk_rank":"reversible","required_roles":["integration-verifier","code-reviewer"]}\n' > .runs/r/batches.jsonl
  printf '{"batch":"B1","subagent_type":"team-bootstrap:integration-verifier"}\n' > .runs/r/dispatch.jsonl
) >/dev/null 2>&1

_brief() { ( cd "$T3" || exit 1; printf '%s' "${1:-{\"agent_type\":\"team-bootstrap:tb-code-reviewer\"\}}" \
  | TEAM_BOOTSTRAP_RUN=r "$BRIEF" 2>/dev/null ); }
_brief_rc() { ( cd "$T3" || exit 1; printf '%s' "$1" | TEAM_BOOTSTRAP_RUN=r "$BRIEF" >/dev/null 2>&1 ); echo $?; }

BOUT="$(_brief)"
echo "AC-12 — it emits the sanctioned context envelope:"
_chk "$(PY 'import json,sys
try:
    d=json.loads(sys.stdin.read())["hookSpecificOutput"]; print(d.get("hookEventName","<absent>"))
except Exception as e: print("invalid")' <<<"$BOUT")" SubagentStart "stdout is JSON with hookEventName SubagentStart"
BCTX="$(PY 'import json,sys
try: print(json.loads(sys.stdin.read())["hookSpecificOutput"].get("additionalContext",""))
except Exception: print("")' <<<"$BOUT")"
_chk "$([ -n "$BCTX" ] && echo nonempty || echo empty)" nonempty "additionalContext is non-empty"

echo "AC-13 — the brief names the SIZED set for the in-flight batch:"
for tok in 'B1' 'integration-verifier' 'code-reviewer'; do
  _chk "$(printf '%s' "$BCTX" | grep -qF "$tok" && echo yes || echo no)" yes "brief names '$tok'"
done

echo "AC-13b — the brief is ADDRESSED to the role that was spawned:"
_chk "$(printf '%s' "$BCTX" | grep -qF 'tb-code-reviewer' && echo yes || echo no)" yes \
  "brief names the spawned agent type (sed BRE alternation is GNU-only — it must not be used here)"

echo "AC-14 — and what has ALREADY been dispatched (so the role knows the gap):"
_chk "$(printf '%s' "$BCTX" | grep -qiE 'dispatch' && echo yes || echo no)" yes "brief states the dispatched-so-far set"

echo "AC-15/16 — same discipline as the UserPromptSubmit channel:"
_chk "$(printf '%s' "$BCTX" | grep -qiE '\b(you must|do not|never |always |ignore |disregard|instruction)' && echo imperative || echo factual)" factual \
  "no imperative/out-of-band phrasing"
_chk "$([ "${#BCTX}" -le 10000 ] && echo ok || echo over)" ok "brief is <= 10000 chars (len=${#BCTX})"

echo "AC-17 — it can never disrupt a dispatch:"
_chk "$(_brief_rc '{"agent_type":"team-bootstrap:tb-code-reviewer"}')" 0 "exit 0 on the happy path"
_chk "$(_brief_rc 'not json at all')" 0 "exit 0 on an unparseable payload"
_chk "$(_brief_rc '')" 0 "exit 0 on an empty payload"

echo "AC-18 — silent off-delivery and under the kill switch:"
T4="$(mktemp -d)"
_chk "$( ( cd "$T4" || exit 1; printf '{}' | "$BRIEF" 2>/dev/null ) )" "" "no active run → stdout EMPTY"
_chk "$( ( cd "$T3" || exit 1; printf '{}' | TEAM_BOOTSTRAP_RUN=r TEAM_BOOTSTRAP_DELIVERY_GATE=off "$BRIEF" 2>/dev/null ) )" "" "kill switch → stdout EMPTY"
rm -rf "$T3" "$T4"

echo "AC-19 — EVERY registered hook body is control surface (the class, not just this instance):"
# references/control-surface.txt names hook bodies one by one, so a NEW hook is covered only if someone
# remembers to add it — and an uncovered hook body can be gutted to `exit 0` as a silent gate-disable,
# which is the exact thing that file exists to make declarable. Assert the invariant instead.
_uncovered=""
while IFS= read -r _c; do
  _b="$(basename "$_c")"
  grep -qF "$_b" "$here/references/control-surface.txt" || _uncovered="${_uncovered:+$_uncovered }$_b"
done <<EOF
$(PY 'import json,sys
h=json.load(open(sys.argv[1]))["hooks"]
for ev in h:
    for g in h[ev]:
        for c in g.get("hooks", []):
            cmd = c.get("command", "")
            if cmd: print(cmd)' "$here/hooks/hooks.json")
EOF
_chk "${_uncovered:-none}" none "every hooks.json command body appears in references/control-surface.txt"

[ "$fail" -eq 0 ] && { echo "harness-context-delivery.test.sh: OK"; exit 0; }
echo "harness-context-delivery.test.sh: $fail failure(s)" >&2; exit 1
