#!/usr/bin/env bash
# tests/dispatch-integrity.test.sh — behavioural test for the PreToolUse[Agent|Task] dispatch hook.
#
# The hook's job is to APPEND the harness's brief to a review dispatch's prompt, which it does by
# returning `hookSpecificOutput.updatedInput`. The defect this file pins down (spec 021 D1): it used to
# build that object FROM SCRATCH with a single key, `prompt`, so every other field of the call —
# `subagent_type`, `description` — was absent from the object the hook handed back.
#
# Whether that was inert or fatal depends on whether the vendor MERGES `updatedInput` into `tool_input`
# or REPLACES `tool_input` with it, and **that question is OPEN** (DC-1 — recorded in the milestone's
# plan.md §7, and to be re-homed in docs/adr/0023 when B8 ships it, because specs/ is gitignored and
# never reaches a clone). The hooks reference says merge. Against it: someone hand-patched the
# installed plugin cache with this same fix before the milestone began, leaving a comment in it that
# records the harness rejecting every dispatch with a schema error — a comment, note, not a transcript.
# A measurement that claimed to settle the question toward merge watched roles launch through that
# already-patched cache, so it settled nothing. Do not read this file as evidence either way, and do
# not let it talk anyone out of running the decisive experiment: one review dispatch through a
# verifiably UNPATCHED cache.
#
# Which is exactly why every assertion below is stated over the HOOK'S OWN OUTPUT and never over what
# the vendor does with it. They hold whichever way DC-1 falls: a hook that augments an input must hand
# back the input it augmented (F3).
#
# AC-1 — updatedInput carries every key of the original tool_input, and only `prompt` differs.
# AC-2 — subagent_type and description survive intact AS VALUES, quotes and non-ASCII included.
#        (Not byte-for-byte on the wire: json.dumps defaults to ensure_ascii=True, so non-ASCII
#        ships escaped and decodes back to itself. Every assertion below compares AFTER parsing,
#        which is the property that matters and the one the tool actually receives.)
# AC-3 — nothing is emitted at all when there is nothing to add: an empty brief, an unparseable
#        payload, or the killswitch. A partial object is worse than no object.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
hook="$here/bin/record-dispatch.sh"
fail=0
[ -x "$hook" ] || { echo "FAIL: $hook missing/not executable" >&2; exit 1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

_chk() { if [ "$1" = "$2" ]; then echo "  PASS $3"; else echo "  FAIL $3 (got '$1' want '$2')" >&2; fail=$((fail + 1)); fi; }

# _fixture DIR [BATCH_KIND] → an armed intends_code run with one in-flight batch. The brief is emitted
# only under exactly this state (subagent-brief.sh: armed marker + in-flight kind:code batch), so a
# fixture that gets it wrong would make every AC-1/AC-2 assertion pass vacuously against no output.
_fixture() {
  local d="$1" kind="${2:-code}" base
  mkdir -p "$d/.runs/r"
  ( cd "$d" && git init -q && git config user.email t@t && git config user.name t \
    && echo base > f && git add . && git commit -qm base ) >/dev/null 2>&1
  base="$( cd "$d" && git rev-parse --short HEAD )"
  printf '{"run":"r","pipeline":"full","intends_code":true,"source":"harness","baseline_sha":"%s"}\n' \
    "$base" > "$d/.runs/r/RUN"
  printf '{"id":"B1","kind":"%s","status":"announced"}\n' "$kind" > "$d/.runs/r/batches.jsonl"
}

# _emit PAYLOAD [DIR] [ENV...] → the hook's stdout for PAYLOAD. Stderr is dropped: the contract under
# test is what the hook RETURNS to the tool, and a hook that also logs is not thereby wrong.
_emit() {
  local payload="$1" d="${2:-$T/ok}"
  ( cd "$d" && printf '%s' "$payload" | TEAM_BOOTSTRAP_RUN=r "$hook" 2>/dev/null )
}

mkdir -p "$T/ok"; _fixture "$T/ok"

# The payload under test: the three fields a real reviewer dispatch carries. `description` and
# `subagent_type` are the two the hook USED TO drop.
PROMPT='Review the batch diff for correctness.'
PAYLOAD='{"tool_name":"Agent","tool_input":{"description":"code review","prompt":"'"$PROMPT"'","subagent_type":"code-reviewer"}}'

out="$(_emit "$PAYLOAD")"

# Guard: an EMPTY stdout would make the key-set comparison below trivially "equal" if it were written
# to tolerate absence. It is not — but the guard says so out loud, because a fixture that stops
# producing a brief is the way this whole file silently stops testing anything.
_chk "$([ -n "$out" ] && echo emitted || echo silent)" emitted \
  "AC-1 precondition: the hook emits updatedInput for a review dispatch under an in-flight code batch"

# AC-1 — key-set equality. Asserted as a set comparison, not a field checklist, so a FOURTH field
# added to a dispatch call by a future vendor is covered by this same assertion.
keys_verdict="$(printf '%s' "$out" | TB_PAYLOAD="$PAYLOAD" python3 -c '
import json,os,sys
try: out=json.loads(sys.stdin.read().strip() or "{}")
except Exception: print("unparseable"); sys.exit(0)
ui=(out.get("hookSpecificOutput") or {}).get("updatedInput")
if not isinstance(ui,dict): print("no-updatedInput"); sys.exit(0)
ti=json.loads(os.environ["TB_PAYLOAD"])["tool_input"]
print("equal" if set(ui)==set(ti) else "differs:"+",".join(sorted(set(ti)^set(ui))))' 2>/dev/null)"
_chk "$keys_verdict" equal "AC-1 updatedInput carries every key of the original tool_input"

# AC-1 — and the prompt is APPENDED to, never replaced: the orchestrator's task must survive.
prompt_verdict="$(printf '%s' "$out" | TB_PROMPT="$PROMPT" python3 -c '
import json,os,sys
try: out=json.loads(sys.stdin.read().strip() or "{}")
except Exception: print("unparseable"); sys.exit(0)
p=((out.get("hookSpecificOutput") or {}).get("updatedInput") or {}).get("prompt")
orig=os.environ["TB_PROMPT"]
if not isinstance(p,str): print("missing")
elif p==orig: print("unchanged")
elif p.startswith(orig): print("appended")
else: print("replaced")' 2>/dev/null)"
_chk "$prompt_verdict" appended "AC-1 updatedInput.prompt starts with the original prompt"

# AC-2 — value survival, on inputs chosen to break naive string splicing: an embedded quote and a
# non-ASCII character. A hook that rebuilt the object with printf rather than a JSON encoder passes
# AC-1 and fails here. Compared after parsing — see the ensure_ascii note in the header.
DESC='code review: "deep" — уровень high'
STYPE='team-bootstrap:tb-code-reviewer'
PAYLOAD2="$(DESC="$DESC" STYPE="$STYPE" PROMPT="$PROMPT" python3 -c '
import json,os
print(json.dumps({"tool_name":"Agent","tool_input":{
  "description":os.environ["DESC"],"prompt":os.environ["PROMPT"],
  "subagent_type":os.environ["STYPE"]}},ensure_ascii=False))')"
out2="$(_emit "$PAYLOAD2")"
survive_verdict="$(printf '%s' "$out2" | DESC="$DESC" STYPE="$STYPE" python3 -c '
import json,os,sys
try: out=json.loads(sys.stdin.read().strip() or "{}")
except Exception: print("unparseable"); sys.exit(0)
ui=(out.get("hookSpecificOutput") or {}).get("updatedInput")
if not isinstance(ui,dict): print("no-updatedInput"); sys.exit(0)
bad=[k for k,v in (("description",os.environ["DESC"]),("subagent_type",os.environ["STYPE"])) if ui.get(k)!=v]
print("intact" if not bad else "corrupted:"+",".join(bad))' 2>/dev/null)"
_chk "$survive_verdict" intact "AC-2 subagent_type and description survive intact as values, quote and non-ASCII included"

# AC-1 — "only `prompt` is changed" is about EVERY other key, not only the two this milestone happens to
# name. Key-set equality plus two named string fields is satisfied by an emitter that keeps every key
# and rewrites the values of fields it does not recognise: `{k: str(v) for k,v in ti.items()}` passes
# both, while turning `run_in_background: true` into the string "True" — a dispatch that quietly changes
# how the reviewer executes. So the survival assertion is made over the WHOLE object, types included.
PAYLOAD3='{"tool_name":"Agent","tool_input":{"description":"d","prompt":"'"$PROMPT"'","subagent_type":"code-reviewer","model":"opus","run_in_background":true,"max_turns":12}}'
whole_verdict="$(_emit "$PAYLOAD3" | TB_PAYLOAD="$PAYLOAD3" python3 -c '
import json,os,sys
try: out=json.loads(sys.stdin.read().strip() or "{}")
except Exception: print("unparseable"); sys.exit(0)
ui=(out.get("hookSpecificOutput") or {}).get("updatedInput")
if not isinstance(ui,dict): print("no-updatedInput"); sys.exit(0)
ti=json.loads(os.environ["TB_PAYLOAD"])["tool_input"]
# Every key except prompt must compare equal AND be of the same type — `True` and "True" are not the
# same argument, and == alone would not always say so.
bad=[k for k,v in ti.items()
     if k!="prompt" and (ui.get(k)!=v or type(ui.get(k)) is not type(v))]
print("intact" if not bad else "changed:"+",".join(sorted(bad)))' 2>/dev/null)"
_chk "$whole_verdict" intact "AC-1 every non-prompt field survives with its value AND its type, named or not"

# AC-3 — three no-emit paths. Each must produce EXACTLY nothing on stdout: a partial updatedInput is a
# call the vendor may reject or, under merge semantics, a silent narrowing of the call.

# (i) empty brief — the marker is armed but the in-flight batch is kind:doc, so subagent-brief.sh
#     produces nothing and there is no assignment to append.
mkdir -p "$T/doc"; _fixture "$T/doc" doc
_chk "$(_emit "$PAYLOAD" "$T/doc" | wc -c | tr -d ' ')" 0 \
  "AC-3 an empty brief emits nothing at all"

# (ii) unparseable payload — bytes that are not JSON must not produce a half-built object.
TRUNCATED='{"tool_name":"Agent","tool_input":{"prompt":'
_chk "$(_emit "$TRUNCATED" | wc -c | tr -d ' ')" 0 \
  "AC-3 an unparseable payload emits nothing at all"

# ROT GUARD for the case above. It only tests the DECODER while `subagent-brief.sh` keeps producing a
# brief for these bytes — the brief gate runs first, and it happens not to require a parseable payload
# or a subagent_type. If it ever does require either, `_brief` goes empty, python is never invoked, and
# case (ii) silently becomes a second copy of case (i): still PASS, no longer testing what it names.
# So pin PARSEABILITY as the only difference — the same bytes, closed into valid JSON, must emit.
_chk "$(_emit "${TRUNCATED}\"p\"}}" | wc -c | tr -d ' ' | awk '{print ($1>0)?"emits":"silent"}')" emits \
  "AC-3 the unparseable case is decided by the DECODER, not by an empty brief"

# (iii) the killswitch.
_chk "$( ( cd "$T/ok" && printf '%s' "$PAYLOAD" \
    | TEAM_BOOTSTRAP_RUN=r TEAM_BOOTSTRAP_DISPATCH_BRIEF=off "$hook" 2>/dev/null ) | wc -c | tr -d ' ')" 0 \
  "AC-3 the TEAM_BOOTSTRAP_DISPATCH_BRIEF killswitch emits nothing at all"

[ "$fail" -eq 0 ] && { echo "dispatch-integrity.test.sh: OK"; exit 0; }
echo "dispatch-integrity.test.sh: $fail failure(s)" >&2; exit 1
