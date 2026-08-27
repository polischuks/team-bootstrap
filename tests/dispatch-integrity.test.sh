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


# =============================================================================
# D2 — a dispatch record is an ATTEMPT, never a completed review (spec 021, B3)
#
# The hook fires at PreToolUse. It observes a dispatch REQUEST and cannot observe what became of it —
# not the launch, not the run, not the result. `dispatch.jsonl` is therefore a record of attempts, and
# the defect is that nothing in the record said so, leaving every reader free to spend it as evidence
# that a review happened.
#
# AC-4 — the record carries its own semantics: `"outcome":"attempted"` sits in the line, not only in a
#        reference file a reader may never open.
# AC-5 — no gate concludes "reviewed" from the ledger alone. Dispatches for every required role plus
#        zero verdicts must not close the batch.
# =============================================================================

# _ledger_fixture DIR → an armed intends_code run with one in-flight kind:code batch that RECORDS the
# roles it requires, so `required_roles_recorded` has something to return and the AC-5 gate reaches its
# verdict check instead of skipping on "requires no review roles" (which would pass vacuously).
_ledger_fixture() {
  local d="$1" base
  mkdir -p "$d/.runs/r"
  ( cd "$d" && git init -q && git config user.email t@t && git config user.name t \
    && echo base > f && git add . && git commit -qm base ) >/dev/null 2>&1
  base="$( cd "$d" && git rev-parse --short HEAD )"
  printf '{"run":"r","pipeline":"full","intends_code":true,"source":"harness","baseline_sha":"%s"}\n' \
    "$base" > "$d/.runs/r/RUN"
  # The recorded role and the dispatch slug must be a REAL pair from references/review-types.txt:
  # `role_of_slug` maps only the dedicated plugin-scoped types, so a plausible-looking `code-reviewer`
  # dispatch attributes to no role at all and the per-role floor would fail for a reason that has
  # nothing to do with AC-5. tb-code-reviewer → code-reviewer is such a pair.
  printf '{"id":"B1","kind":"code","status":"announced","required_roles":["code-reviewer"]}\n' \
    > "$d/.runs/r/batches.jsonl"
  rm -f "$d/.runs/r/dispatch.jsonl" "$d/.runs/r/verdicts.jsonl"
}

mkdir -p "$T/led"; _ledger_fixture "$T/led"

# AC-4 — drive the real hook and read back what it appended. Asserted over EVERY line rather than the
# first, so a future second write path that omits the field is caught here and not in production.
( cd "$T/led" && printf '%s' "$PAYLOAD" | TEAM_BOOTSTRAP_RUN=r "$hook" >/dev/null 2>&1 )
( cd "$T/led" && printf '{"tool_name":"Agent","tool_input":{"description":"d","prompt":"p","subagent_type":"independent-reviewer"}}' \
    | TEAM_BOOTSTRAP_RUN=r "$hook" >/dev/null 2>&1 )
_disp_file="$T/led/.runs/r/dispatch.jsonl"
_chk "$([ -s "$_disp_file" ] && echo recorded || echo empty)" recorded \
  "AC-4 precondition: the hook appended dispatch records to drive the assertion against"
outcome_verdict="$(python3 -c '
import json,sys
bad=0; n=0
for line in open(sys.argv[1]):
    line=line.strip()
    if not line: continue
    n+=1
    try: rec=json.loads(line)
    except Exception: bad+=1; continue
    if rec.get("outcome")!="attempted": bad+=1
print("all-attempted" if n and not bad else "missing:%d/%d"%(bad,n))' "$_disp_file" 2>/dev/null)"
_chk "$outcome_verdict" all-attempted \
  "AC-4 every appended dispatch record declares outcome:attempted — the ledger says what it saw"

# AC-5 — the phantom, stated end to end. Every role the batch requires has a dispatch record; not one
# verdict was captured. The anti-collapse floor is SATISFIED and must stay satisfied (that count is an
# honest count of attempts), and the batch must still not close.
printf '{"batch":"B1","subagent_type":"tb-code-reviewer","outcome":"attempted"}\n' > "$_disp_file"
_dispatch_rc="$( ( cd "$T/led" && TEAM_BOOTSTRAP_RUN=r "$here/bin/check-role-dispatch.sh" . ) >/dev/null 2>&1; echo $?)"
_chk "$_dispatch_rc" 0 \
  "AC-5 the anti-collapse floor still passes on attempts alone — counting dispatches is not the defect"
_verdict_rc="$( ( cd "$T/led" && TEAM_BOOTSTRAP_RUN=r "$here/bin/check-role-verdict.sh" --gate . ) >/dev/null 2>&1; echo $?)"
_chk "$([ "$_verdict_rc" -ne 0 ] && echo refused || echo closed)" refused \
  "AC-5 dispatches for every required role and ZERO verdicts does not close the batch"

# AC-4/AC-5 back-compat — a `dispatch.jsonl` written by a pre-3.3.0 plugin has no `outcome` field. No
# consumer may REQUIRE the new field: a long-lived ledger would otherwise stop counting its own history
# the day the field appeared, silently emptying the anti-collapse floor it exists to hold.
printf '{"batch":"B1","subagent_type":"tb-code-reviewer"}\n' > "$_disp_file"
_legacy_rc="$( ( cd "$T/led" && TEAM_BOOTSTRAP_RUN=r "$here/bin/check-role-dispatch.sh" . ) >/dev/null 2>&1; echo $?)"
_chk "$_legacy_rc" 0 \
  "AC-4 a pre-3.3.0 record with no outcome field still counts toward the anti-collapse floor"
_legacy_count="$( cd "$T/led" && TEAM_BOOTSTRAP_RUN=r bash -c '. "'"$here"'/bin/delivery-lib.sh"; reviewer_dispatch_count B1' 2>/dev/null )"
_chk "$_legacy_count" 1 \
  "AC-5 reviewer_dispatch_count reads a legacy record as one attempt — the shared definition is unchanged"


# =============================================================================
# D3 — a gate that cannot verify does not pass (spec 021, B4)
#
# check-role-verdict --gate used to print, on stderr, that role confirmation was "UNVERIFIED for this
# batch, not satisfied" — and then return 0. That is the one thing a gate may never do: declare its own
# blindness and pass anyway. F1 settles it — "cannot verify" is a refusal, and the only relief is a
# GOVERNED waiver.
#
# The wording is deliberately kept: what changes is the outcome, not the sentence.
#
# AC-6 — zero captured verdicts for the batch ⇒ non-zero exit.
# AC-7 — a run-scoped role_verdict_waiver with ack+by+reason+expires relieves it; the finding is still
#        printed BEFORE the waiver is consulted, and an absent or expired expiry does not relieve.
# =============================================================================

_verdict_gate() {  # [ENV=...] → exit code of --gate in the AC-5/AC-6 fixture
  ( cd "$T/led" && TEAM_BOOTSTRAP_RUN=r "$here/bin/check-role-verdict.sh" --gate . ) >/dev/null 2>&1
  echo $?
}
_verdict_gate_err() {  # → stderr of --gate, to prove the finding is printed even when waived
  ( cd "$T/led" && TEAM_BOOTSTRAP_RUN=r "$here/bin/check-role-verdict.sh" --gate . ) 2>&1 >/dev/null
}

# _marker_with WAIVER_JSON → rewrite the run marker with (or, empty, without) a role_verdict_waiver.
_marker_with() {
  local extra="$1" base
  base="$( cd "$T/led" && git rev-parse --short HEAD )"
  printf '{"run":"r","pipeline":"full","intends_code":true,"source":"harness","baseline_sha":"%s"%s}\n' \
    "$base" "${extra:+,$extra}" > "$T/led/.runs/r/RUN"
}

# The reproduction, exactly as the spec states it: a full run, a kind:code batch with required_roles,
# a dispatch record for every one of them, and no verdicts.jsonl at all.
printf '{"batch":"B1","subagent_type":"tb-code-reviewer","outcome":"attempted"}\n' > "$_disp_file"
rm -f "$T/led/.runs/r/verdicts.jsonl"
_marker_with ''
_chk "$([ "$(_verdict_gate)" -ne 0 ] && echo refused || echo passed)" refused \
  "AC-6 zero captured verdicts — the gate refuses instead of passing on its own declared blindness"

# AC-6 — and it still SAYS the same thing. Changing the outcome must not cost the diagnosis; an
# operator who reads only stderr should see no regression in what they are told.
case "$(_verdict_gate_err)" in
  *UNVERIFIED*) echo "  PASS AC-6 the UNVERIFIED/not-satisfied wording is preserved verbatim" ;;
  *) echo "  FAIL AC-6 the UNVERIFIED wording was lost when the outcome flipped" >&2; fail=$((fail + 1)) ;;
esac

# AC-7 — the waiver, in the four states that matter. `expires` is mandatory precisely so that a waiver
# is an event with an end date and not a posture (R2).
_marker_with '"role_verdict_waiver":{"ack":true,"by":"founder","reason":"capture channel is out of scope for 021"}'
_chk "$([ "$(_verdict_gate)" -ne 0 ] && echo refused || echo passed)" refused \
  "AC-7 a waiver with no expires does not relieve the refusal"

_marker_with '"role_verdict_waiver":{"ack":true,"by":"founder","reason":"capture channel","expires":"2020-01-01"}'
_chk "$([ "$(_verdict_gate)" -ne 0 ] && echo refused || echo passed)" refused \
  "AC-7 an expired waiver does not relieve the refusal"

_marker_with '"role_verdict_waiver":{"ack":true,"by":"founder","reason":"capture channel","expires":"2099-01-01"}'
_chk "$(_verdict_gate)" 0 \
  "AC-7 a governed, unexpired waiver relieves the refusal"

# AC-7 — and the finding is printed BEFORE the waiver is consulted. A waiver that silences its own
# finding is how a governed escape becomes an invisible one.
case "$(_verdict_gate_err)" in
  *UNVERIFIED*WAIVED*|*UNVERIFIED*waived*) echo "  PASS AC-7 the finding is printed first, then the waiver is announced" ;;
  *) echo "  FAIL AC-7 the waived run does not surface the finding ahead of the waiver" >&2; fail=$((fail + 1)) ;;
esac

# AC-7 — a bare ack is not a waiver. The whole point of `governed` is that three more fields are
# required, and this pins that the gate uses governed_waiver_ok rather than reading `ack` alone.
_marker_with '"role_verdict_waiver":{"ack":true}'
_chk "$([ "$(_verdict_gate)" -ne 0 ] && echo refused || echo passed)" refused \
  "AC-7 a bare ack with no by/reason/expires does not relieve the refusal"

# AC-6 — the refusal is SCOPED to blindness, not to everything. A batch that DID capture every required
# verdict must still pass, or the flip is not a fail-closed gate but a permanently red one.
_marker_with ''
printf '{"batch":"B1","role":"code-reviewer","fields_ok":true}\n' > "$T/led/.runs/r/verdicts.jsonl"
_chk "$(_verdict_gate)" 0 \
  "AC-6 a batch whose required roles DID return verdicts still passes — the refusal is scoped to blindness"
rm -f "$T/led/.runs/r/verdicts.jsonl"


# =============================================================================
# AC-8 — the one-off becomes a class (spec 021, T024/T025)
#
# Fixing check-role-verdict's `seen == 0` branch removes ONE instance. Clause 4 of check-gate-integrity
# is what stops it coming back anywhere: a `bin/check-*.sh` path that prints its own inability to
# verify (DEGRADED / UNVERIFIED / cannot) and then returns 0 is a finding.
#
# The discriminator is the RETURN, not the vocabulary. "cannot" appears in a dozen honest FAIL messages
# in this tree, and flagging those would be the cries-wolf failure F4 warns about. What is flagged is
# declaring blindness and then passing.
# =============================================================================

_gi() {  # DIR → exit code of check-gate-integrity in DIR
  ( "$here/bin/check-gate-integrity.sh" "$1" ) >/dev/null 2>&1; echo $?
}
_gi_err() { ( "$here/bin/check-gate-integrity.sh" "$1" ) 2>&1 >/dev/null; }

# A clean scratch root: only the fixture gate exists, so a finding can come from nowhere else.
_gi_fixture() {
  local d="$1" body="$2"
  rm -rf "$d"; mkdir -p "$d/bin"
  cat > "$d/bin/check-fixture.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
_evaluate() {
$body
}
_evaluate
EOF
  chmod +x "$d/bin/check-fixture.sh"
}

G="$T/gi"

# (a) THE DEFECT — declares blindness, returns 0.
_gi_fixture "$G" '  echo "check-fixture: DEGRADED — nothing was captured; this is UNVERIFIED, not satisfied." >&2
  return 0'
_chk "$([ "$(_gi "$G")" -ne 0 ] && echo flagged || echo missed)" flagged \
  "AC-8 a gate that prints DEGRADED/UNVERIFIED and then returns 0 is a finding"
case "$(_gi_err "$G")" in
  *check-fixture.sh*) echo "  PASS AC-8 the finding names the offending file" ;;
  *) echo "  FAIL AC-8 the finding does not name the file" >&2; fail=$((fail + 1)) ;;
esac

# (b) THE CORRECT SHAPE — declares blindness, refuses. Must NOT be flagged, or the rule punishes the
#     very fix it exists to require.
_gi_fixture "$G" '  echo "check-fixture: DEGRADED — nothing was captured; this is UNVERIFIED, not satisfied." >&2
  return 1'
_chk "$(_gi "$G")" 0 \
  "AC-8 declaring blindness and REFUSING is not a finding"

# (c) THE GOVERNED SHAPE — declares blindness, then passes only through a governed waiver. This is
#     exactly what B4 just built into check-role-verdict, and it must be distinguishable from (a) by
#     something in the code rather than by a hand-stamped exception.
_gi_fixture "$G" '  echo "check-fixture: DEGRADED — nothing captured; UNVERIFIED, not satisfied." >&2
  if governed_waiver_ok "$ack" "$by" "$reason" "$expires"; then
    echo "check-fixture: WAIVED by a governed waiver." >&2
    return 0
  fi
  return 1'
_chk "$(_gi "$G")" 0 \
  "AC-8 passing only through a governed, expiring waiver is not a finding"

# (d) THE SANCTION — an inline `gate-integrity: sanctioned` marker, the convention this file already
#     uses everywhere else, still works. Without it there is no door for a genuine AC-48 design.
_gi_fixture "$G" '  echo "check-fixture: cannot evaluate — its own library is unreadable." >&2
  return 0   # gate-integrity: sanctioned — a gate that cannot load its library cannot evaluate its own waiver either'
_chk "$(_gi "$G")" 0 \
  "AC-8 an inline gate-integrity: sanctioned marker is honoured on the returning line"

# (e) NO CRY-WOLF — an honest failure message containing the word "cannot" while returning non-zero is
#     not a finding. There are a dozen of these in the tree and flagging them is how a gate gets
#     switched off (F4).
_gi_fixture "$G" '  echo "  FAIL: batch cites a commit git cannot resolve — closure not backed by real commits." >&2
  return 1'
_chk "$(_gi "$G")" 0 \
  "AC-8 an honest FAIL message using the word 'cannot' is not a finding"

# (f) THE WHOLE TREE — clause 4 run against this repo's own gates. Every hit must be brought to the
#     rule or sanctioned WITH its principle (T025); a green here is the standing assertion that none
#     was left behind.
_chk "$(_gi "$here")" 0 \
  "AC-8 every bin/check-*.sh in this tree is at the rule — none declares blindness and passes"


# =============================================================================
# AC-7 — the waiver has a DOOR (spec 021, T027/T028)
#
# A waiver reachable only by hand-editing JSON inside a run marker is not a governed escape. Until this
# milestone `gate_integrity_waiver` had no writer anywhere in the tree — its only occurrence outside
# the gate that read it was a fixture in a test. Both waivers now have one, and it is the same one.
# =============================================================================

_door_fixture() {
  rm -rf "$T/door"; mkdir -p "$T/door/.runs/r"
  printf '{"run":"r","pipeline":"full","intends_code":true,"source":"harness"}\n' > "$T/door/.runs/r/RUN"
}
_door() {  # GATE ARGS… → exit code of the --waive door
  local gate="$1"; shift
  ( cd "$T/door" && TEAM_BOOTSTRAP_RUN=r "$here/bin/$gate" --waive "$@" ) >/dev/null 2>&1; echo $?
}

_door_fixture
_chk "$(_door check-role-verdict.sh founder "capture is 0-for-7 in this repo" 2099-01-01)" 0 \
  "AC-7 the operator door records a governed role_verdict_waiver"

# It must record something the GATE then honours — a writer and a reader that disagree would leave the
# operator holding a waiver that reads as armed and is not.
cp "$T/door/.runs/r/RUN" "$T/led/.runs/r/RUN"
rm -f "$T/led/.runs/r/verdicts.jsonl"
printf '{"batch":"B1","subagent_type":"tb-code-reviewer","outcome":"attempted"}\n' > "$_disp_file"
_chk "$(_verdict_gate)" 0 \
  "AC-7 a waiver written by the door is honoured by the gate — one definition of governed, not two"

# The door refuses exactly what the gate would refuse. Validating at write time is the whole reason the
# door is better than hand-editing: the operator finds out now, not at the gate.
_door_fixture
_chk "$([ "$(_door check-role-verdict.sh founder "no expiry given" "")" -ne 0 ] && echo refused || echo wrote)" refused \
  "AC-7 the door refuses a waiver with no expires"
_chk "$([ "$(_door check-role-verdict.sh founder "already lapsed" 2020-01-01)" -ne 0 ] && echo refused || echo wrote)" refused \
  "AC-7 the door refuses an already-expired waiver"
_chk "$([ "$(_door check-role-verdict.sh "" "no author" 2099-01-01)" -ne 0 ] && echo refused || echo wrote)" refused \
  "AC-7 the door refuses a waiver with no author"

# Both waivers share the writer, and writing one must not clobber the other — an operator who waives
# the integrity gate and then the verdict gate must end up holding both.
_door_fixture
_door check-role-verdict.sh founder "verdict capture" 2099-01-01 >/dev/null
_door check-gate-integrity.sh founder "pre-existing CI skips" 2099-02-01 >/dev/null
_both="$(python3 -c '
import json,sys
try: mk=json.load(open(sys.argv[1]))
except Exception: print("unparseable"); sys.exit(0)
have=[k for k in ("role_verdict_waiver","gate_integrity_waiver") if isinstance(mk.get(k),dict)]
print("both" if len(have)==2 else "only:"+",".join(have or ["none"]))' "$T/door/.runs/r/RUN" 2>/dev/null)"
_chk "$_both" both \
  "AC-7 the two waivers coexist — recording one leaves the other intact and the marker parseable"

# R2's mitigation is a NUMBER, and a number nobody computes is a mitigation nobody has.
_waive_metric="$( ( cd "$T/door" && "$here/bin/delivery-metrics.sh" --json . ) 2>/dev/null \
  | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: print("no-json"); sys.exit(0)
print("reported" if "waived_share_pct" in d else "absent")' 2>/dev/null)"
_chk "$_waive_metric" reported \
  "AC-7 delivery-metrics reports the share of code runs closed under a waiver (R2's own mitigation)"

[ "$fail" -eq 0 ] && { echo "dispatch-integrity.test.sh: OK"; exit 0; }
echo "dispatch-integrity.test.sh: $fail failure(s)" >&2; exit 1
