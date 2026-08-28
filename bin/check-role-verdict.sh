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
#   well-formed verdict. A batch with ZERO captured verdicts is a REFUSAL (exit 1), not a degraded pass:
#   the gate says it cannot confirm and then declines to confirm (spec 021 D3, AC-6; F1; P10). This
#   header used to end "a gate that cannot see must say so, never pass quietly" while the code passed
#   quietly anyway — saying so was never the whole obligation. The single relief is a governed,
#   expiring run-scoped `role_verdict_waiver` (AC-7), consulted after the finding is printed.
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

[ "${TEAM_BOOTSTRAP_DELIVERY_GATE:-on}" = "off" ] && exit 0   # gate-integrity: sanctioned — explicit operator kill switch
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/delivery-lib.sh
# gate-integrity: sanctioned — THE SEPARATING PRINCIPLE (spec 021 AC-8, plan §8.5, ADR-0023). Clause 4
# of check-gate-integrity flags "declares blindness, then passes", and this line is that shape on
# purpose. The difference from the `seen == 0` branch B4 just made fail-closed is not severity, it is
# WAIVABILITY: a gate that cannot load delivery-lib.sh cannot evaluate ANYTHING, including its own
# governed waiver — governed_waiver_ok lives in the file that failed to load. Blocking here would
# therefore be unconditional and un-waivable, a gate no operator can ever clear by any means, which is
# a worse failure than the one it prevents. `seen == 0`, by contrast, is an evaluable state with a
# working escape, so it refuses. Absent (exit 0) and stating so is the honest report of a gate that
# could not start; a gate that CAN start and cannot confirm must refuse.
. "$here/delivery-lib.sh" 2>/dev/null || { echo "$(basename "$0"): delivery-lib.sh is unreadable — this gate cannot evaluate and is NOT passing; it is absent (AC-48)." >&2; exit 0; }
SCHEMA="$here/../references/schemas/role-output.schema.json"

# --- the operator door (spec 021 AC-7, T027) ---------------------------------
# `--waive BY REASON EXPIRES` records the governed waiver this gate reads. It exists because a waiver
# reachable only by hand-editing JSON inside a run marker is not a governed escape — nothing records
# who opened it or when it closes except the discipline of whoever was editing, and that is exactly the
# discipline under pressure when a batch will not close. Validation is record_governed_waiver's, which
# is governed_waiver_ok's, which is this gate's: one definition, so a waiver that records always works
# and one that would not work is refused here with a reason instead of failing later at the gate.
# Procedure and the standard for a good `reason`: references/enforcement.md.
if [ "${1:-}" = "--waive" ]; then
  shift
  if [ "$#" -ne 3 ]; then
    echo "usage: $(basename "$0") --waive BY REASON EXPIRES(YYYY-MM-DD)" >&2
    echo "  records role_verdict_waiver in the active run marker. Expiry is mandatory and must be in the future." >&2
    exit 64
  fi
  record_governed_waiver role_verdict_waiver "$1" "$2" "$3" || {
    echo "$(basename "$0"): REFUSED to record role_verdict_waiver — needs a non-empty by and reason, and a future YYYY-MM-DD expires, under an unambiguous active run." >&2
    exit 1
  }
  exit 0
fi


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
  local explicit_slug="${1:-}" payload role tr obj missing f rundir bid bline
  payload="$(cat 2>/dev/null || true)"
  # ISSUE #44 — where the role comes from. A SubagentStop/Stop payload does NOT carry the dispatched
  # subagent_type (that field lives in the PreToolUse[Agent] tool_input, which is exactly why
  # record-dispatch.sh reads it THERE and not here). So recovering the role from a payload field was
  # 0-of-7 in practice: role came back empty and this hook exited before reading a transcript or writing
  # a single verdict. The declaring frontmatter already KNOWS its role, so it names it: each review
  # agent's `Stop` hook is `check-role-verdict.sh --hook-role <its-own-slug>`. When that slug is given we
  # use it; the payload scan stays only as a back-compat fallback for a caller that does carry the field.
  if [ -n "$explicit_slug" ]; then
    role="$explicit_slug"
  else
    role="$(printf '%s' "$payload" \
      | grep -oE '"(agent_type|subagent_type|agentType|subagentType)"[[:space:]]*:[[:space:]]*"[^"]*"' \
      | head -1 | sed -E 's/.*"([^"]*)"[[:space:]]*$/\1/')"
  fi
  [ -n "$role" ] || exit 0   # gate-integrity: sanctioned — not a team-bootstrap review role: out of scope for this hook
  role="$(role_of_slug "$role" 2>/dev/null || true)"      # slug → attributed role; empty ⇒ not a review type
  [ -n "$role" ] || exit 0   # gate-integrity: sanctioned — not a team-bootstrap review role: out of scope for this hook
  tr="$(printf '%s' "$payload" | grep -oE '"transcript_path"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | head -1 | sed -E 's/.*"([^"]*)"[[:space:]]*$/\1/')"
  [ -n "$tr" ] && [ -f "$tr" ] || exit 0   # gate-integrity: sanctioned — no transcript to read. This is the HOOK, which must not block a subagent it cannot parse; the absence surfaces as zero captures, and --gate now REFUSES on that (AC-6) rather than reporting a degraded pass.
  obj="$(_verdict_obj "$tr" "$role")"
  [ -n "$obj" ] || exit 0   # gate-integrity: sanctioned — no verdict object to judge; the absence surfaces as zero captures and --gate refuses on it (AC-6)

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
  [ -n "$bid" ] || exit 0   # gate-integrity: sanctioned — no in-flight batch to confirm roles for
  rundir="$(dirname "$(resolve_marker 2>/dev/null || true)")"
  [ -n "$rundir" ] && [ -d "$rundir" ] || exit 0   # gate-integrity: sanctioned — no run directory: out of scope, and the --gate pass fails closed on a missing capture
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
    # A gate that declares its own blindness and then passes is the green-by-skip this whole tree exists
    # to refuse (spec 021 D3, AC-6; F1; constitution P10). The sentence below is UNCHANGED — it was
    # always right, and "UNVERIFIED for this batch, not satisfied" is a description of a failure. Only
    # the return value used to disagree with it. It no longer does.
    #
    # The counter-argument this branch used to make for itself — that enforcing would block every close
    # on a capability question — is true, and is not a reason to pass. It is a reason to have a governed
    # escape, which is what follows. Measured (plan §8.3): capture is 0 for 7 in this repo, so after this
    # change the waiver is the ONLY way a kind:code batch closes here until the capture channel is fixed,
    # and fixing it is out of this milestone's scope. That is stated in the CHANGELOG rather than
    # softened here, because softening it is the defect.
    echo "check-role-verdict: DEGRADED — no role verdict was captured for batch '$bid' (required: [$req]). The SubagentStop capture did not run or could not read a transcript; role confirmation is UNVERIFIED for this batch, not satisfied." >&2

    # AC-7 — the waiver is consulted AFTER the finding is printed, never instead of it: a governed
    # escape that silences its own finding is an invisible one. Run-scoped (OQ-2: per-batch invites one
    # per batch) and routed through the SAME governed_waiver_ok that backs gate_integrity_waiver — one
    # definition of "governed", already proven, so ack+by+reason+expires and an unexpired date are not
    # re-implemented here to drift. A bare `ack` is not a waiver.
    if governed_waiver_ok \
         "$(field_in_obj "$mk" role_verdict_waiver ack)" \
         "$(field_in_obj "$mk" role_verdict_waiver by)" \
         "$(field_in_obj "$mk" role_verdict_waiver reason)" \
         "$(field_in_obj "$mk" role_verdict_waiver expires)"; then
      echo "check-role-verdict: WAIVED by a governed role_verdict_waiver (finding surfaced above; by/reason/expires recorded, expiry forces re-review) — exit 0. See references/enforcement.md for the procedure." >&2
      return 0
    fi
    return 1
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
  # A failed `cd` used to be swallowed: the gate then evaluated the CURRENT directory instead of the
  # one it was handed, silently answering a different question. Fail loudly — a gate that runs
  # somewhere else is not a gate that passed.
  --gate) shift
          if [ -n "${1:-}" ]; then
            cd "$1" 2>/dev/null || { echo "check-role-verdict: bad project dir '$1'" >&2; exit 64; }
          fi
          _gate_mode; exit $? ;;
  # --hook-role SLUG: the SubagentStop hook that KNOWS its own role (declared in a review agent's
  # frontmatter). SLUG is resolved through role_of_slug exactly like the payload path, so the two agree.
  --hook-role) shift; _hook_mode "${1:-}" ;;
  *)      _hook_mode ;;
esac
