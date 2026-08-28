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
_chk "$(printf '%s' "$_gate_err46" | grep -ciE 'REMOVED|durability breach')" 1 \
  "the gate NAMES the loss (durability breach) instead of silently reverting to 'unverified'"
rm -rf "$R46"

echo "3.1 — the closure gate reads the recorded verdicts:"
_chk "$(grep -qE '(^|[^a-z-])check-role-verdict\.sh' "$here/bin/verify-batch.sh" && echo yes || echo no)" yes \
  "check-role-verdict is wired into verify-batch"
_chk "$(bash "$V" --self-test >/dev/null 2>&1 && echo ok || echo red)" ok "check-role-verdict --self-test passes"

[ "$fail" -eq 0 ] && { echo "role-verdict.test.sh: OK"; exit 0; }
echo "role-verdict.test.sh: $fail failure(s)" >&2; exit 1
