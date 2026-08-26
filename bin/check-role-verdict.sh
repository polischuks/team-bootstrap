#!/usr/bin/env bash
# check-role-verdict.sh — criterion 6: a dispatched review role is CONFIRMED, not merely counted.
#
# TWO MODES, one contract.
#
#   SubagentStop hook (declared in each review role's OWN frontmatter, where `Stop` is converted to
#   SubagentStop and lives only while that subagent runs): reads the finished subagent's transcript,
#   extracts its verdict object, validates it against the fields role-output.schema.json REQUIRES of
#   that role, records it to .runs/<run>/verdicts.jsonl, and BLOCKS (exit 2) a verdict that is present
#   but shapeless.
#
#   verify-batch gate (`--gate`): every role required for the in-flight batch must have a recorded,
#   well-formed verdict. Enforced only where extraction is known to work in this environment (at least
#   one verdict recorded for the batch); otherwise reported as a declared degradation rather than
#   pretended — a gate that cannot see must say so, never pass quietly.
#
# WHY IT BLOCKS ONLY ON PROVABLE MALFORMATION. Blocking on "no verdict found" would deadlock every
# review whose transcript this cannot parse, which is a worse failure than the one being prevented
# (same reasoning that makes record-dispatch.sh non-blocking). So: transcript unreadable, no verdict
# object, or a non-review agent type ⇒ exit 0. A verdict object for THIS role that lacks the fields its
# own schema requires ⇒ exit 2. We block what we can prove.
#
# HONEST LIMIT (ADR-0006/0008): this raises the FORGERY bar — a verdict must now carry the shape its
# role declares — it does not close forgery. A well-formed lie still passes. Dispatch ≠ completion
# ≠ honesty; this closes the middle gap only.
#
# Usage: hook (stdin payload) · check-role-verdict.sh --gate [dir] · --self-test
# Exit: 0 allow/OK · 1 gate failure · 2 blocking (malformed verdict)
set -uo pipefail

[ "${TEAM_BOOTSTRAP_DELIVERY_GATE:-on}" = "off" ] && exit 0
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/delivery-lib.sh
. "$here/delivery-lib.sh" 2>/dev/null || exit 0
SCHEMA="$here/../references/schemas/role-output.schema.json"

# required_fields_for ROLE → space-separated field names role-output.schema.json requires of ROLE.
# Empty when the role is unknown or declares none (in which case there is nothing to confirm and the
# role is not eligible for the profile map — see tests/roles-alive.test.sh criterion 6).
required_fields_for() {
  python3 -c 'import json,sys
try: d=json.load(open(sys.argv[1]))["$defs"].get(sys.argv[2],{})
except Exception: sys.exit(0)
out=[]
for b in d.get("allOf",[]): out += b.get("required",[])
print(" ".join(out))' "$SCHEMA" "$1" 2>/dev/null || true
}

# _verdict_obj TRANSCRIPT ROLE → the LAST JSON object in TRANSCRIPT whose "role" is ROLE (empty if none).
# Scans the raw text rather than assuming a transcript schema: the shape of a transcript file is not a
# contract we control, and guessing one would make this silently blind after any format change.
_verdict_obj() {
  python3 -c 'import json,re,sys
try: txt=open(sys.argv[1], errors="replace").read()
except Exception: sys.exit(0)
role=sys.argv[2]; found=None
for m in re.finditer(r"\{", txt):
    depth=0
    for i in range(m.start(), len(txt)):
        if txt[i]=="{": depth+=1
        elif txt[i]=="}":
            depth-=1
            if depth==0:
                try: o=json.loads(txt[m.start():i+1])
                except Exception: pass
                else:
                    if isinstance(o,dict) and o.get("role")==role: found=o
                break
    else: break
print(json.dumps(found) if found else "")' "$1" "$2" 2>/dev/null || true
}

_hook_mode() {
  local payload role tr obj missing f rundir bid bline
  payload="$(cat 2>/dev/null || true)"
  role="$(printf '%s' "$payload" \
    | grep -oE '"(agent_type|subagent_type|agentType|subagentType)"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | head -1 | sed -E 's/.*"([^"]*)"[[:space:]]*$/\1/')"
  [ -n "$role" ] || exit 0
  role="$(role_of_slug "$role" 2>/dev/null || true)"      # slug → attributed role; empty ⇒ not a review type
  [ -n "$role" ] || exit 0
  tr="$(printf '%s' "$payload" | grep -oE '"transcript_path"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | head -1 | sed -E 's/.*"([^"]*)"[[:space:]]*$/\1/')"
  [ -n "$tr" ] && [ -f "$tr" ] || exit 0                  # nothing to read ⇒ never block on ignorance
  obj="$(_verdict_obj "$tr" "$role")"
  [ -n "$obj" ] || exit 0                                 # no verdict object ⇒ cannot prove malformed

  missing=""
  for f in $(required_fields_for "$role"); do
    printf '%s' "$obj" | grep -qE "\"$f\"[[:space:]]*:" || missing="${missing:+$missing }$f"
  done
  if [ -n "$missing" ]; then
    echo "check-role-verdict: BLOCKED — the '$role' verdict is missing the field(s) its own contract requires: [$missing]." >&2
    echo "  references/schemas/role-output.schema.json requires them of this role. A verdict without them is not a review result — it is a shape the closure gate cannot confirm." >&2
    exit 2
  fi

  # Well-formed: record it as a HARNESS-OBSERVED fact for the in-flight batch, so closure reads
  # something the harness saw rather than something the orchestrator asserted.
  bline="$(inflight_batch 2>/dev/null || true)"; bid="$(field_str "$bline" id)"
  [ -n "$bid" ] || exit 0
  rundir="$(dirname "$(resolve_marker 2>/dev/null || true)")"
  [ -n "$rundir" ] && [ -d "$rundir" ] || exit 0
  printf '{"batch":"%s","role":"%s","fields_ok":true}\n' "$bid" "$role" >> "$rundir/verdicts.jsonl" 2>/dev/null || true
  exit 0
}

_gate_mode() {
  local marker mk bline bid pipeline rundir recorded req r missing seen
  marker="$(resolve_marker 2>/dev/null || true)"
  [ -n "$marker" ] && [ -f "$marker" ] || { echo "check-role-verdict: no active delivery run — skipping."; return 0; }
  mk="$(cat "$marker" 2>/dev/null || true)"
  [ "$(field_bool "$mk" intends_code)" = "true" ] || { echo "check-role-verdict: marker not intends_code — skipping."; return 0; }
  pipeline="$(field_str "$mk" pipeline)"
  [ "$pipeline" = "single-thread" ] && { echo "check-role-verdict: pipeline=single-thread — inline reviewers by contract (P1); skipping."; return 0; }
  bline="$(inflight_batch 2>/dev/null || true)"; bid="$(field_str "$bline" id)"
  [ -n "$bid" ] || { echo "check-role-verdict: no in-flight batch — nothing to check."; return 0; }
  [ "$(field_str "$bline" kind)" = "code" ] || { echo "check-role-verdict: batch '$bid' is not kind:code — skipping."; return 0; }

  rundir="$(dirname "$marker")"
  seen="$(grep -F "\"batch\":\"$bid\"" "$rundir/verdicts.jsonl" 2>/dev/null | wc -l | tr -d ' ')"
  req="$(required_roles_recorded "$bid" 2>/dev/null || true)"
  [ -n "$req" ] || req="$(required_roles_for_batch "$bid" 2>/dev/null || true)"
  [ -n "$req" ] || { echo "check-role-verdict: batch '$bid' requires no review roles — nothing to confirm."; return 0; }

  if [ "${seen:-0}" -eq 0 ]; then
    # DECLARED degradation, never a quiet pass: no verdict was captured for this batch at all, so the
    # extraction path is unproven HERE and enforcing would block every close on a capability question.
    echo "check-role-verdict: DEGRADED — no role verdict was captured for batch '$bid' (required: [$req]). The SubagentStop capture did not run or could not read a transcript; role confirmation is UNVERIFIED for this batch, not satisfied." >&2
    return 0
  fi
  missing=""
  for r in $req; do
    grep -qF "\"batch\":\"$bid\",\"role\":\"$r\"" "$rundir/verdicts.jsonl" 2>/dev/null \
      || missing="${missing:+$missing }$r"
  done
  if [ -n "$missing" ]; then
    echo "check-role-verdict: FAIL — batch '$bid' captured verdicts, but not from every required role. MISSING: [$missing] (required: [$req])." >&2
    return 1
  fi
  echo "check-role-verdict: batch '$bid' — every required role returned a well-formed typed verdict [$req]. OK."
  return 0
}

if [ "${1:-}" = "--self-test" ]; then
  fail=0
  _c() { if [ "$1" = "$2" ]; then echo "  PASS $3"; else echo "  FAIL $3 (got $1 want $2)" >&2; fail=$((fail + 1)); fi; }
  _c "$(required_fields_for security-reviewer | tr ' ' ',')" "severity_counts,secrets_audit_passed" "schema drives the required set"
  _c "$(required_fields_for overengineering-reviewer)" "verdict" "per-role required field is read"
  _c "$(required_fields_for no-such-role)" "" "unknown role ⇒ no requirement (never invents one)"
  T="$(mktemp -d)"
  printf '%s\n' '{"role":"security-reviewer","severity_counts":{},"secrets_audit_passed":false}' > "$T/t"
  _c "$(_verdict_obj "$T/t" security-reviewer | grep -c secrets_audit_passed)" 1 "verdict object is extracted"
  _c "$(_verdict_obj "$T/t" data-schema-reviewer)" "" "another role's object is not mistaken for this one"
  printf '%s\n' 'garbage { not json' > "$T/t2"
  _c "$(_verdict_obj "$T/t2" security-reviewer)" "" "unparseable transcript ⇒ empty, never a crash"
  rm -rf "$T"
  [ "$fail" -eq 0 ] && { echo "check-role-verdict --self-test: OK"; exit 0; }
  echo "check-role-verdict --self-test: $fail FAILED" >&2; exit 1
fi

case "${1:-}" in
  --gate) shift; [ -n "${1:-}" ] && cd "$1" 2>/dev/null; _gate_mode; exit $? ;;
  *)      _hook_mode ;;
esac
