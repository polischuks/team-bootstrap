#!/usr/bin/env bash
# role-verdict.test.sh — criterion 6: a dispatched role is CONFIRMED, not merely counted.
#
# review-types.txt states the limit in its own header: the dispatch signal is degradation-proof but NOT
# forgery-proof — a decoy no-op dispatch under the right type satisfies the floor. Widening the role set
# (roles-alive phase 1) multiplies that: fifteen roles are fifteen ways to dispatch a shell.
#
# The closable half of that gap: a role's verdict has a REQUIRED SHAPE in role-output.schema.json
# (security-reviewer → severity_counts + secrets_audit_passed; data-schema-reviewer → migration_safe;
# overengineering-reviewer → verdict; integration-verifier → integration_verified + orphans_found), and
# nothing checked it. A shapeless "looks fine" passed exactly like a real review.
#
# Scope honestly stated: this raises the FORGERY bar (a verdict must now have the shape its role
# declares), it does not close forgery (a well-formed lie still passes — ADR-0006/0008).
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
_chk() { if [ "$1" = "$2" ]; then printf '  PASS %s\n' "$3"
  else printf '  FAIL %s (got [%s] want [%s])\n' "$3" "$1" "$2" >&2; fail=$((fail + 1)); fi; }
V="$here/bin/check-role-verdict.sh"

echo "1.3 — the checker exists and each review role carries it as its own SubagentStop hook:"
_chk "$([ -x "$V" ] && echo yes || echo no)" yes "bin/check-role-verdict.sh is executable"
for a in security-reviewer data-schema-reviewer overengineering-reviewer integration-verifier \
         architecture-reviewer regression-guardian tb-code-reviewer; do
  # A `Stop` hook in subagent frontmatter is converted to SubagentStop and lives only while that
  # subagent runs — the check stays in its own role's scope and never pollutes global settings.
  _chk "$(awk '/^---$/{n++; next} n==1' "$here/agents/$a.md" | grep -qE '^hooks:' && echo yes || echo no)" yes \
    "agents/$a.md declares frontmatter hooks"
  _chk "$(awk '/^---$/{n++; next} n==1' "$here/agents/$a.md" | grep -qF 'check-role-verdict.sh' && echo yes || echo no)" yes \
    "  …wired to check-role-verdict.sh"
done

echo "1.3 — it validates the SHAPE the role's own schema requires:"
T="$(mktemp -d)"
( cd "$T" || exit 1; git init -q; git config user.email a@b.c; git config user.name t
  printf 'x\n' > s.txt; git add -A; git commit -q -m b; mkdir -p .runs/r
  printf '{"run":"r","pipeline":"full","intends_code":true}\n' > .runs/r/RUN
  printf '{"id":"B1","kind":"code","status":"announced"}\n' > .runs/r/batches.jsonl ) >/dev/null 2>&1

# _verdict ROLE TRANSCRIPT_BODY → exit code of the SubagentStop check
_verdict() {
  local tr="$T/tr.jsonl"; printf '%s\n' "$2" > "$tr"
  ( cd "$T" || exit 1
    printf '{"agent_type":"%s","transcript_path":"%s"}' "$1" "$tr" \
      | TEAM_BOOTSTRAP_RUN=r "$V" >/dev/null 2>&1 ); echo $?
}
GOOD='{"role":"security-reviewer","status":"completed","severity_counts":{"critical":0,"high":0,"medium":1,"low":2},"secrets_audit_passed":true}'
BAD='{"role":"security-reviewer","status":"completed","summary":"looks fine"}'

_chk "$(_verdict security-reviewer "$GOOD")" 0 "well-formed verdict → allows the subagent to finish"
_chk "$(_verdict security-reviewer "$BAD")"  2 "verdict present but MISSING required fields → exit 2 (blocks)"

echo "1.3 — it never deadlocks a review on ignorance:"
_chk "$(_verdict security-reviewer 'not json at all')" 0 "unparseable transcript → exit 0 (cannot prove malformed ⇒ never block)"
_chk "$( ( cd "$T" || exit 1; printf '{"agent_type":"security-reviewer","transcript_path":"/nope"}' | TEAM_BOOTSTRAP_RUN=r "$V" >/dev/null 2>&1 ); echo $? )" 0 \
  "missing transcript → exit 0"
_chk "$( ( cd "$T" || exit 1; printf '{}' | TEAM_BOOTSTRAP_RUN=r "$V" >/dev/null 2>&1 ); echo $? )" 0 "empty payload → exit 0"
_chk "$( ( cd "$T" || exit 1; printf '{"agent_type":"backend-engineer","transcript_path":"%s"}' "$T/tr.jsonl" | TEAM_BOOTSTRAP_RUN=r "$V" >/dev/null 2>&1 ); echo $? )" 0 \
  "a non-review agent type is not this hook's business → exit 0"
_chk "$( ( cd "$T" || exit 1; printf '{"agent_type":"security-reviewer","transcript_path":"%s"}' "$T/tr.jsonl" | TEAM_BOOTSTRAP_RUN=r TEAM_BOOTSTRAP_DELIVERY_GATE=off "$V" >/dev/null 2>&1 ); echo $? )" 0 \
  "kill switch → exit 0"

echo "1.3 — a confirmed verdict becomes a HARNESS-OBSERVED fact, not a self-report:"
rm -f "$T/.runs/r/verdicts.jsonl"
_verdict security-reviewer "$GOOD" >/dev/null
_chk "$([ -f "$T/.runs/r/verdicts.jsonl" ] && echo yes || echo no)" yes "the verdict is recorded to .runs/<run>/verdicts.jsonl"
_chk "$(grep -c '"role":"security-reviewer"' "$T/.runs/r/verdicts.jsonl" 2>/dev/null)" 1 "  …attributed to the role"
_chk "$(grep -c '"batch":"B1"' "$T/.runs/r/verdicts.jsonl" 2>/dev/null)" 1 "  …and to the in-flight batch"
rm -rf "$T"

echo "1.3b — a role that CARRIES the verdict hook must have something for it to check:"
# The hook is only a confirmation if the role's schema requires something. A role that declares
# `properties` and no `required` gets a hook that finds nothing to demand and exits 0 on every
# invocation — a check that cannot fail, which is exactly what check-gate-integrity exists to catch.
# The criterion-6 invariant in roles-alive.test.sh covers only roles the PROFILE MAP names, so it
# cannot see this: the four mandatory roles come from the tier base set, not the map. Cover them here.
_inert=""
for _a in "$here"/agents/*.md; do
  # frontmatter only: the file's PROSE may name the script (independent-reviewer explains why it has
  # no hook), and matching that would report a role as carrying a check it does not carry.
  # Match the DECLARATION (`command: …/check-role-verdict.sh`), not a mention. The prompt handler's own
  # text names the script, and the prose of a role that has no hook explains why — matching either
  # would report a role as carrying a check it does not carry.
  awk '/^---$/{n++; next} n==1' "$_a" | grep -qE '^[[:space:]]*command:.*check-role-verdict\.sh' || continue
  _slug="${_a##*/}"; _slug="${_slug%.md}"
  _role="$(awk -F'\t' -v s="$_slug" '$1==s && $2!=""{print $2; exit}' "$here/references/review-types.txt")"
  [ -n "$_role" ] || _role="$_slug"
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["$defs"].get(sys.argv[2],{}); sys.exit(0 if any(b.get("required") for b in d.get("allOf",[])) else 1)' \
    "$here/references/schemas/role-output.schema.json" "$_role" 2>/dev/null || _inert="${_inert:+$_inert }$_slug"
done
_chk "${_inert:-none}" none "no role carries a verdict hook that cannot fail"

echo "#44 — the hook identifies its role from the frontmatter, NOT from a payload field a real SubagentStop lacks:"
# The 0-of-7 root cause: _hook_mode recovered the role ONLY from an agent_type/subagent_type field in
# the hook stdin. A real SubagentStop/Stop payload does not carry that field (the same reason
# record-dispatch.sh uses PreToolUse, which DOES). The frontmatter knows its own role, so it passes it
# with --hook-role <slug>; the old tests hid the gap by fabricating agent_type in the synthetic payload.
R44="$(mktemp -d)"
( cd "$R44" || exit 1; git init -q; git config user.email a@b.c; git config user.name t
  printf 'x\n' > s.txt; git add -A; git commit -q -m b; mkdir -p .runs/r
  printf '{"run":"r","pipeline":"full","intends_code":true}\n' > .runs/r/RUN
  printf '{"id":"B1","kind":"code","status":"announced"}\n' > .runs/r/batches.jsonl ) >/dev/null 2>&1
printf '%s\n' '{"role":"security-reviewer","status":"completed","severity_counts":{"critical":0,"high":0,"medium":0,"low":0},"secrets_audit_passed":true}' > "$R44/tr.jsonl"
# A realistic SubagentStop payload: transcript_path + event name, and NO agent_type/subagent_type.
REAL_PAYLOAD="$(printf '{"hook_event_name":"SubagentStop","session_id":"s","stop_hook_active":false,"cwd":"%s","transcript_path":"%s"}' "$R44" "$R44/tr.jsonl")"

rm -f "$R44/.runs/r/verdicts.jsonl"
( cd "$R44" || exit 1; printf '%s' "$REAL_PAYLOAD" | TEAM_BOOTSTRAP_RUN=r "$V" --hook-role security-reviewer >/dev/null 2>&1 )
_chk "$(grep -c '"role":"security-reviewer"' "$R44/.runs/r/verdicts.jsonl" 2>/dev/null || echo 0)" 1 \
  "--hook-role names the role from the frontmatter → a realistic SubagentStop payload is captured"
_chk "$(grep -c '"batch":"B1"' "$R44/.runs/r/verdicts.jsonl" 2>/dev/null || echo 0)" 1 \
  "  …attributed to the in-flight batch"
# Documents the honest limit: with no --hook-role AND a payload that lacks the type field, nothing is
# captured — which is exactly the 0-of-7 production behaviour this fix removes.
rm -f "$R44/.runs/r/verdicts.jsonl"
( cd "$R44" || exit 1; printf '%s' "$REAL_PAYLOAD" | TEAM_BOOTSTRAP_RUN=r "$V" >/dev/null 2>&1 )
_chk "$([ -f "$R44/.runs/r/verdicts.jsonl" ] && echo present || echo absent)" absent \
  "no --hook-role and no type in the payload → nothing captured (the pre-fix production behaviour)"
# Every review agent's frontmatter passes its own slug to --hook-role (no reliance on the payload):
for _fa in "$here"/agents/*.md; do
  awk '/^---$/{n++; next} n==1' "$_fa" | grep -qE '^[[:space:]]*command:.*check-role-verdict\.sh' || continue
  _fs="${_fa##*/}"; _fs="${_fs%.md}"
  _chk "$(awk '/^---$/{n++; next} n==1' "$_fa" | grep -qE "check-role-verdict\.sh --hook-role[[:space:]]+$_fs([[:space:]\"]|$)" && echo yes || echo no)" yes \
    "agents/$_fs.md passes --hook-role $_fs"
done
rm -rf "$R44"

echo "#46 — a captured verdict leaves a durable, tamper-evident record; losing verdicts.jsonl is DETECTED, not silent:"
# Run 096 lost verdicts.jsonl mid-run while the RUN marker survived, and the loss was invisible — the
# gate merely reverted to "unverified". The plugin never deletes the file itself, so it cannot prevent
# an external removal; it CAN leave a record the removal does not erase. Each capture is mirrored into
# the marker's append-only verdicts_captured list, and the gate names the loss when the file is gone.
R46="$(mktemp -d)"
( cd "$R46" || exit 1; git init -q; git config user.email a@b.c; git config user.name t
  printf 'x\n' > s.txt; git add -A; git commit -q -m b; mkdir -p .runs/r
  printf '{"run":"r","pipeline":"full","intends_code":true}\n' > .runs/r/RUN
  printf '{"id":"B1","kind":"code","status":"announced","required_roles":["security-reviewer"]}\n' > .runs/r/batches.jsonl ) >/dev/null 2>&1
printf '%s\n' '{"role":"security-reviewer","status":"completed","severity_counts":{"critical":0,"high":0,"medium":0,"low":0},"secrets_audit_passed":true}' > "$R46/tr.jsonl"
R46_PAYLOAD="$(printf '{"hook_event_name":"SubagentStop","transcript_path":"%s"}' "$R46/tr.jsonl")"
# Capture the verdict through the REAL hook (creates verdicts.jsonl AND the durable marker tally):
( cd "$R46" || exit 1; printf '%s' "$R46_PAYLOAD" | TEAM_BOOTSTRAP_RUN=r "$V" --hook-role security-reviewer >/dev/null 2>&1 )
_chk "$(grep -c '"role":"security-reviewer"' "$R46/.runs/r/verdicts.jsonl" 2>/dev/null || echo 0)" 1 "capture wrote verdicts.jsonl"
_chk "$(grep -c 'B1/security-reviewer' "$R46/.runs/r/RUN" 2>/dev/null || echo 0)" 1 "capture ALSO recorded a durable tally in the RUN marker"
# Sanity: with the file present, the gate confirms and passes.
_chk "$( ( cd "$R46" || exit 1; TEAM_BOOTSTRAP_RUN=r "$V" --gate >/dev/null 2>&1 ); echo $? )" 0 "gate passes while verdicts.jsonl is present"
# Now the failure mode from #46: verdicts.jsonl vanishes; the marker survives.
rm -f "$R46/.runs/r/verdicts.jsonl"
_gate_err46="$( ( cd "$R46" || exit 1; TEAM_BOOTSTRAP_RUN=r "$V" --gate 2>&1 >/dev/null ) )"
_chk "$( ( cd "$R46" || exit 1; TEAM_BOOTSTRAP_RUN=r "$V" --gate >/dev/null 2>&1 ); echo $? )" 1 "a removed verdict file cannot pass the gate"
# >=1 (was ==1): #60 adds a second breach-naming line — the captured-then-lost diagnosis pointing at the
# verdict-capture.jsonl trace — so what matters is that the loss IS named, not that it is named exactly once.
_chk "$(printf '%s' "$_gate_err46" | grep -qiE 'REMOVED|durability breach' && echo yes || echo no)" yes \
  "the gate NAMES the loss (durability breach) instead of silently reverting to 'unverified'"
rm -rf "$R46"

echo "#60 — capture reads the SUBAGENT transcript (agent_transcript_path), not the main-session transcript:"
# Claude Code hooks reference: a SubagentStop payload carries BOTH transcript_path (the MAIN session
# transcript) AND agent_transcript_path (the finished subagent's OWN transcript). The verdict object lives
# in the SUBAGENT transcript. Reading transcript_path scans the wrong file, finds no verdict for the role,
# and exits 0 — the 0-of-N silent miss EVEN WHEN the hook fires. Prefer agent_transcript_path.
S60="$(mktemp -d)"
( cd "$S60" || exit 1; git init -q; git config user.email a@b.c; git config user.name t
  printf 'x\n' > s.txt; git add -A; git commit -q -m b; mkdir -p .runs/r
  printf '{"run":"r","pipeline":"full","intends_code":true}\n' > .runs/r/RUN
  printf '{"id":"B1","kind":"code","status":"announced"}\n' > .runs/r/batches.jsonl ) >/dev/null 2>&1
# the subagent's OWN transcript holds the well-formed verdict; the main-session transcript is a decoy with
# NO verdict object for this role.
printf '%s\n' '{"role":"integration-verifier","status":"completed","integration_verified":true,"orphans_found":[]}' > "$S60/sub.jsonl"
printf '%s\n' '{"role":"orchestrator","note":"main session, no reviewer verdict here"}' > "$S60/main.jsonl"
S60_PAYLOAD="$(printf '{"hook_event_name":"SubagentStop","agent_type":"team-bootstrap:integration-verifier","agent_transcript_path":"%s","transcript_path":"%s","stop_hook_active":false}' "$S60/sub.jsonl" "$S60/main.jsonl")"
rm -f "$S60/.runs/r/verdicts.jsonl"
( cd "$S60" || exit 1; printf '%s' "$S60_PAYLOAD" | TEAM_BOOTSTRAP_RUN=r "$V" >/dev/null 2>&1 )
_chk "$(grep -c '"role":"integration-verifier"' "$S60/.runs/r/verdicts.jsonl" 2>/dev/null || echo 0)" 1 \
  "verdict captured from the SUBAGENT transcript (agent_transcript_path), main-session decoy ignored"
_chk "$(grep -c '"batch":"B1"' "$S60/.runs/r/verdicts.jsonl" 2>/dev/null || echo 0)" 1 \
  "plain hook mode: role recovered from agent_type, attributed to the in-flight batch"
# firing the SAME capture twice (frontmatter Stop AND the plugin-level SubagentStop can both fire) records once.
( cd "$S60" || exit 1; printf '%s' "$S60_PAYLOAD" | TEAM_BOOTSTRAP_RUN=r "$V" >/dev/null 2>&1 )
_chk "$(grep -c '"role":"integration-verifier"' "$S60/.runs/r/verdicts.jsonl" 2>/dev/null || echo 0)" 1 \
  "idempotent: a repeated capture for the same batch+role does not double-record"
# back-compat: a payload with ONLY transcript_path (no agent_transcript_path) still captures.
rm -f "$S60/.runs/r/verdicts.jsonl"
S60_LEGACY="$(printf '{"hook_event_name":"SubagentStop","agent_type":"team-bootstrap:integration-verifier","transcript_path":"%s"}' "$S60/sub.jsonl")"
( cd "$S60" || exit 1; printf '%s' "$S60_LEGACY" | TEAM_BOOTSTRAP_RUN=r "$V" >/dev/null 2>&1 )
_chk "$(grep -c '"role":"integration-verifier"' "$S60/.runs/r/verdicts.jsonl" 2>/dev/null || echo 0)" 1 \
  "back-compat: only transcript_path present → still captured"
rm -rf "$S60"

echo "#60 — a PLUGIN-LEVEL SubagentStop registration carries capture off the Agent/Task-tool completion event:"
# The capture path used to be ONLY each review agent's frontmatter Stop. A plugin-level SubagentStop keyed
# to the review agent types is the documented event that fires for Agent/Task-tool subagents (hooks
# reference: SubagentStop matches agent_type, same values as SubagentStart). This asserts the registration
# EXISTS and is wired to check-role-verdict; it does NOT — and a bash test CANNOT — prove the host delivers
# the event for an Agent-tool dispatch. That end-to-end firing stays host-dependent (see the report).
_hooks="$here/hooks/hooks.json"
_chk "$(python3 -c 'import json,sys; h=json.load(open(sys.argv[1]))["hooks"]; sys.exit(0 if "SubagentStop" in h else 1)' "$_hooks" 2>/dev/null && echo yes || echo no)" yes \
  "hooks.json registers a plugin-level SubagentStop event"
_chk "$(python3 -c 'import json,sys
h=json.load(open(sys.argv[1]))["hooks"].get("SubagentStop",[])
cmds=[hk.get("command","") for e in h for hk in e.get("hooks",[])]
sys.exit(0 if any("check-role-verdict.sh" in c for c in cmds) else 1)' "$_hooks" 2>/dev/null && echo yes || echo no)" yes \
  "  …wired to check-role-verdict.sh"
_chk "$(python3 -c 'import json,sys
h=json.load(open(sys.argv[1]))["hooks"].get("SubagentStop",[])
ms=" ".join(e.get("matcher","") for e in h)
sys.exit(0 if ("verifier" in ms) and ("reviewer" in ms) and ("team-bootstrap" in ms) else 1)' "$_hooks" 2>/dev/null && echo yes || echo no)" yes \
  "  …matched on the review-role agent types"

echo "#60 — the batch-close gate writes a diagnosable trace (proven-firing path), not a guess:"
# Acceptance #60(2): when capture produced nothing, a trace must record WHY, written by a path proven to
# fire. verify-batch calls this gate at batch close, so THE GATE writes it. dispatch.jsonl makes the two
# old possibilities ("hook never ran" vs "ran but blind") distinguishable, so the record names the
# observable state instead of the "did not run OR could not read" guess.
G60="$(mktemp -d)"
( cd "$G60" || exit 1; git init -q; git config user.email a@b.c; git config user.name t
  printf 'x\n' > s.txt; git add -A; git commit -q -m b; mkdir -p .runs/r
  printf '{"run":"r","pipeline":"full","intends_code":true}\n' > .runs/r/RUN
  printf '{"id":"B1","kind":"code","status":"announced","required_roles":["integration-verifier","code-reviewer"]}\n' > .runs/r/batches.jsonl
  # reviewers WERE dispatched for B1 (dispatch.jsonl), but NO verdicts.jsonl exists — the live 3.4.0 state.
  printf '%s\n%s\n' '{"batch":"B1","subagent_type":"team-bootstrap:integration-verifier","outcome":"attempted"}' '{"batch":"B1","subagent_type":"team-bootstrap:tb-code-reviewer","outcome":"attempted"}' > .runs/r/dispatch.jsonl ) >/dev/null 2>&1
_g60_err="$( ( cd "$G60" || exit 1; TEAM_BOOTSTRAP_RUN=r "$V" --gate 2>&1 >/dev/null ) )"
_chk "$( ( cd "$G60" || exit 1; TEAM_BOOTSTRAP_RUN=r "$V" --gate >/dev/null 2>&1 ); echo $? )" 1 "seen==0 still refuses (no waiver)"
_chk "$([ -f "$G60/.runs/r/verdict-capture.jsonl" ] && echo yes || echo no)" yes \
  "the gate WROTE a diagnostic trace to verdict-capture.jsonl"
_chk "$(grep -c 'capture-channel-did-not-fire' "$G60/.runs/r/verdict-capture.jsonl" 2>/dev/null || echo 0)" 1 \
  "  …diagnosing capture-channel-did-not-fire (reviewers dispatched, zero verdicts, no decline trace)"
_chk "$(grep -c '"batch":"B1"' "$G60/.runs/r/verdict-capture.jsonl" 2>/dev/null || echo 0)" 1 "  …for the in-flight batch"
_chk "$(printf '%s' "$_g60_err" | grep -ciE 'did not run or could not read')" 0 \
  "the gate no longer prints the 'did not run OR could not read' guess"
_chk "$(printf '%s' "$_g60_err" | grep -ciE 'verdict-capture\.jsonl')" 1 "  …it points the operator at the trace file"
# idempotent: verify-batch retries the gate; the trace records once per (batch,diagnosis), not per retry.
( cd "$G60" || exit 1; TEAM_BOOTSTRAP_RUN=r "$V" --gate >/dev/null 2>&1 )
( cd "$G60" || exit 1; TEAM_BOOTSTRAP_RUN=r "$V" --gate >/dev/null 2>&1 )
_chk "$(grep -c 'capture-channel-did-not-fire' "$G60/.runs/r/verdict-capture.jsonl" 2>/dev/null || echo 0)" 1 \
  "  …and does not balloon on the gate's retries (deduped per batch+diagnosis)"
rm -rf "$G60"

echo "3.1 — the closure gate reads the recorded verdicts:"
_chk "$(grep -qE '(^|[^a-z-])check-role-verdict\.sh' "$here/bin/verify-batch.sh" && echo yes || echo no)" yes \
  "check-role-verdict is wired into verify-batch"
_chk "$(bash "$V" --self-test >/dev/null 2>&1 && echo ok || echo red)" ok "check-role-verdict --self-test passes"

[ "$fail" -eq 0 ] && { echo "role-verdict.test.sh: OK"; exit 0; }
echo "role-verdict.test.sh: $fail failure(s)" >&2; exit 1
