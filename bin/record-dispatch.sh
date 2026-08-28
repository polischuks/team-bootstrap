#!/usr/bin/env bash
# record-dispatch.sh — NON-BLOCKING PreToolUse[Agent] recorder (milestone exec-role-integrity, v2.21.0).
#
# team-bootstrap's full/mvp pipelines exist to give each batch a fresh, INDEPENDENT mind (builder ≠
# reviewer). That separation used to be prose the orchestrator could silently collapse — and did
# (spec-169: the orchestrator absorbed builder AND reviewer, the machine backstop still went green, the
# user was told "delivered, gates passed" while the role pipeline never ran). This hook makes "a
# reviewer-typed subagent was DISPATCHED" a harness-observed fact instead of a claim.
#
# Registered as a PreToolUse hook matched on the subagent-dispatch tool (hooks.json matcher `Agent|Task`,
# covering both the current `Agent` tool name and the legacy `Task` name). On each dispatch it
# reads tool_input.subagent_type from the hook stdin; when that type is a dedicated review type
# (delivery-lib is_review_type ← references/review-types.txt, the N3 single source) it appends
#   {"batch":"<in-flight batch id>","subagent_type":"<type>"}
# to .runs/<run>/dispatch.jsonl. The batch is the one IN FLIGHT when the reviewer is launched (last
# announced ledger entry) — dispatch-time attribution (soundness B4: a reviewer runs within its own
# batch, before verify-batch closes it, so this credits the correct batch).
#
# WHY PreToolUse, no completion status (probe-confirmed, plan §signal):
#   - Subagents run background-by-default, so PostToolUse[Agent] returns status:"async_launched", never
#     "completed" — any completed-gated recorder would false-block a healthy parallel-reviewer batch (N1).
#   - SubagentStop is flaky (#27755). PreToolUse[Agent] reliably carries tool_input.subagent_type at
#     dispatch, foreground and background. So the signal is dispatch OCCURRENCE of a review type.
#
# HONEST LIMIT (ADR-0008): subagent_type is model-authored → degradation-proof, NOT forgery-proof; and
# recording at dispatch proves an INVOCATION WAS REQUESTED — not that it launched, not that it
# completed, not that it was good (NF1). This hook is PreToolUse: it runs BEFORE the tool does, and
# returns before anything is known about the outcome. The word used to be "LAUNCHED", which is one
# claim further than the mechanism reaches (spec 021 D2, AC-4) — the record now says `attempted` in
# the line itself, and this comment says the same thing.
#
# Safety: this hook must never disrupt a dispatch. It ALWAYS exits 0 (recording only — no deadlock, per
# references/hooks.md). Marker-gated: no active run ⇒ no-op. Disable with TEAM_BOOTSTRAP_DELIVERY_GATE=off.
#
# Usage: (hook) echo '<PreToolUse json>' | bin/record-dispatch.sh   ·   bin/record-dispatch.sh --self-test
# Exit:  always 0 (0 on --self-test only reflects pass/fail).
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/delivery-lib.sh
. "$here/delivery-lib.sh"

# _inflight_batch_id → the id of the in-flight ledger entry (last announced; else last non-empty; else "").
_inflight_batch_id() {
  local ledger line
  ledger="$(resolve_ledger)"; [ -n "$ledger" ] && [ -f "$ledger" ] || return 0
  line="$(grep '"status":[[:space:]]*"announced"' "$ledger" 2>/dev/null | tail -1)"
  [ -n "$line" ] || line="$(grep -v '^[[:space:]]*$' "$ledger" 2>/dev/null | tail -1)"
  [ -n "$line" ] && field_str "$line" id
}

# record_dispatch PAYLOAD → the pure core (own function so the self-test can drive it): parse the
# subagent_type, and on a review type under an active marker, append a dispatch record. Always rc 0.
record_dispatch() {
  local payload="$1" stype marker rundir bid
  [ -n "$payload" ] || return 0
  stype="$(field_str "$payload" subagent_type)"
  [ -n "$stype" ] || return 0
  is_review_type "$stype" || return 0            # a builder-typed dispatch never records
  marker="$(resolve_marker)"                     # marker-gated: no active run ⇒ no-op
  [ -n "$marker" ] && [ -f "$marker" ] || return 0
  rundir="$(dirname "$marker")"
  bid="$(_inflight_batch_id)"
  # outcome:"attempted" — the record says what this hook actually SAW (spec 021 D2, AC-4). PreToolUse
  # fires BEFORE the tool runs, so the only observable here is that a dispatch was requested: not that
  # it launched, not that the reviewer ran, not that anything came back. The field is the record's own
  # semantics, carried in the line rather than left to references/review-types.txt — a reader holding
  # one line must be able to see what it is worth without opening a second file.
  #
  # It is ADDITIVE and no reader may require it (AC-4 back-compat): every consumer reads named fields
  # through field_str and ignores the rest, so pre-3.3.0 records with no `outcome` keep counting toward
  # the anti-collapse floor. Requiring it would empty that floor of a long-lived ledger's whole history
  # on the day the field appeared.
  #
  # There is no second value. If a later change ever learns an outcome, it belongs in a record written
  # by whatever observed it — not by this hook, which by construction cannot.
  #
  # `ts` — the wall-clock second this dispatch was requested (issue #61). PreToolUse fires at dispatch,
  # so this is an honest per-role START timestamp; there is no matching end (SubagentStop does not fire
  # for Agent-tool subagents — #60), so this stamps a WHEN, never a duration. delivery-metrics derives
  # the per-batch review window and per-role dispatch timing from it. ADDITIVE: readers use field_str/
  # field_num and ignore unknown keys, so pre-#61 records with no `ts` still count toward the floor.
  printf '{"batch":"%s","subagent_type":"%s","outcome":"attempted","ts":%s}\n' \
    "$bid" "$stype" "$(_now_epoch)" >> "$rundir/dispatch.jsonl" 2>/dev/null || true
  return 0
}

# --- self-test ---------------------------------------------------------------
if [ "${1:-}" = "--self-test" ]; then
  fail=0; T="$(mktemp -d)"; mkdir -p "$T/.runs/r"
  ( cd "$T" && git init -q && git config user.email t@t && git config user.name t
    echo base > f && git add . && git commit -qm base ) >/dev/null 2>&1
  base="$(cd "$T" && git rev-parse --short HEAD)"
  printf '{"run":"r","pipeline":"full","intends_code":true,"source":"harness","baseline_sha":"%s"}\n' "$base" > "$T/.runs/r/RUN"
  printf '{"id":"B1","kind":"code","status":"announced"}\n' > "$T/.runs/r/batches.jsonl"
  disp="$T/.runs/r/dispatch.jsonl"
  _run() { ( cd "$T" && printf '%s' "$1" | TEAM_BOOTSTRAP_RUN=r "$here/record-dispatch.sh" ); }
  _chk() { if [ "$1" = "$2" ]; then echo "  PASS $3"; else echo "  FAIL ($1 want $2) $3" >&2; fail=$((fail + 1)); fi; }

  # a review-typed dispatch (host review slug in review-types.txt) → recorded, credited to B1
  _run '{"tool_name":"Agent","tool_input":{"subagent_type":"code-reviewer","prompt":"review"}}'
  _chk "$([ -f "$disp" ] && grep -c '"subagent_type":"code-reviewer"' "$disp" || echo 0)" 1 "review-typed dispatch recorded"
  _chk "$([ -f "$disp" ] && grep -c '"batch":"B1"' "$disp" || echo 0)" 1 "recorded against the in-flight batch B1"
  # the dedicated plugin-scoped type is also recorded
  _run '{"tool_name":"Agent","tool_input":{"subagent_type":"independent-reviewer","prompt":"review"}}'
  _chk "$(grep -c '"subagent_type":"independent-reviewer"' "$disp" 2>/dev/null || echo 0)" 1 "dedicated review type recorded"
  # a builder-typed dispatch → NOT recorded (count unchanged at 2)
  _run '{"tool_name":"Agent","tool_input":{"subagent_type":"backend-developer","prompt":"build"}}'
  _chk "$(grep -c . "$disp" 2>/dev/null || echo 0)" 2 "builder-typed dispatch NOT recorded"
  # empty stdin → no-op, exit 0
  ec="$(printf '' | ( cd "$T" && TEAM_BOOTSTRAP_RUN=r "$here/record-dispatch.sh" ); echo $?)"
  _chk "$ec" 0 "empty stdin → non-blocking exit 0"
  # no active marker → no-op (nothing appended); use an isolated empty run
  rm -f "$T/.runs/r/RUN"; before="$(grep -c . "$disp" 2>/dev/null || echo 0)"
  _run '{"tool_name":"Agent","tool_input":{"subagent_type":"code-reviewer","prompt":"review"}}'
  _chk "$(grep -c . "$disp" 2>/dev/null || echo 0)" "$before" "no active marker → no record appended"
  # a review-typed dispatch ALWAYS exits 0 (non-blocking), even under an active marker
  printf '{"run":"r","pipeline":"full","intends_code":true,"source":"harness","baseline_sha":"%s"}\n' "$base" > "$T/.runs/r/RUN"
  ec2="$(_run '{"tool_name":"Agent","tool_input":{"subagent_type":"code-reviewer"}}'; echo $?)"
  _chk "$ec2" 0 "review dispatch under active marker → non-blocking exit 0"

  rm -rf "$T"
  if [ "$fail" -eq 0 ]; then echo "record-dispatch --self-test: OK"; exit 0; fi
  echo "record-dispatch --self-test: $fail case(s) FAILED" >&2; exit 1
fi

# --- hook entry: read the PreToolUse payload from stdin, record, never block ----
[ "${TEAM_BOOTSTRAP_DELIVERY_GATE:-on}" = "off" ] && exit 0
# Bound the read: a dispatch payload with a large prompt is still only a few KB of leading JSON, and
# subagent_type sits near the front of tool_input. Reading a bounded prefix keeps this recording hook
# cheap and caps a pathological stdin; the head-of-object fields we parse are always within it.
payload="$(head -c 1048576 2>/dev/null || true)"
record_dispatch "$payload"

# updatedInput (hooks reference §"PreToolUse"): rewrite the tool's arguments before it executes. Used
# here to APPEND the harness's plan facts to a review dispatch's prompt — the role gets its assignment
# in the argument itself, so it arrives even where SubagentStart context does not.
#
# Why appending and never replacing: the orchestrator's prompt is the task. Overwriting it would make a
# recording hook silently authoritative over what the reviewer was asked to do, which is a far larger
# power than this hook is entitled to. It also stays NON-blocking — the project already rejected a
# blocking PreToolUse[Agent|Task] gate because refusing a dispatch pushes review inline (spec-169).
#
# TWO DIFFERENT OBJECTS, and this comment used to conflate them (spec 021 D1, AC-1). "Append, never
# replace" is true of the PROMPT TEXT. It was NOT true of the returned OBJECT: the emitter below used
# to build `updatedInput` from scratch with a single key, so the object handed back was not the call it
# was given — `subagent_type` and `description` were simply absent from it.
#
# Whether that is FATAL or merely wrong depends on a vendor contract, and the contract is genuinely
# unsettled — DC-1 (specs/021-…/plan.md §7) is OPEN, and deliberately so:
#   - for MERGE: the hooks reference, verbatim — "only the fields you include are changed; other
#     fields stay the same";
#   - for REPLACE: a comment left BY that cache patch records the harness rejecting every dispatch with
#     a schema error (observed 2026-08-26..27). Note what that evidence is and is not — a string
#     hand-written into an untracked plugin-cache file, not a transcript — because weighing it against
#     a vendor document requires knowing which it is. What is independently checkable is that someone
#     found it necessary to hand-patch the installed cache with this same fix on 2026-08-27, before
#     this milestone began.
# A measurement that claimed to settle it did not: the review roles it watched start were dispatched
# through that already-patched cache, so they say nothing about the unpatched shape.
#
# So this code does not depend on the answer, and that is the point. Returning the ORIGINAL tool_input
# with `prompt` replaced is a no-op under merge, is what keeps the call valid under replace, and is
# correct under F3 either way: a hook that augments an input must preserve the input. Correctness that
# rested on the merge being true would be one vendor release away from dropping `subagent_type` off
# every review dispatch in the tree.
#
# Emitted only when there is something true to add, and skipped entirely on anything unexpected.
if [ "${TEAM_BOOTSTRAP_DISPATCH_BRIEF:-on}" != "off" ]; then
  _brief="$(printf '%s' "$payload" | "$(dirname "$0")/subagent-brief.sh" 2>/dev/null \
    | sed -n 's/.*"additionalContext":"\([^"]*\)".*/\1/p' | head -1)"
  if [ -n "$_brief" ]; then
    # `VAR=x cmd1 | cmd2` scopes VAR to cmd1 only — export it, or python3 never sees the brief.
    export TB_BRIEF="$_brief"
    printf '%s' "$payload" | python3 -c 'import json,os,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
ti=d.get("tool_input")
if not isinstance(ti,dict): sys.exit(0)
p=ti.get("prompt")
b=os.environ.get("TB_BRIEF","")
if not isinstance(p,str) or not p or not b: sys.exit(0)
# The ORIGINAL call, with one field replaced — not a fresh object carrying one field (AC-1, AC-2).
# dict(ti) is a copy, so nothing that follows can mutate the parsed payload; json.dumps re-encodes
# every other value through a conformant codec, which keeps quotes and non-ASCII intact AS VALUES
# where a printf-built object would corrupt them. Not byte-identical on the wire, and it does not need
# to be: json.dumps defaults to ensure_ascii=True, so "уровень" ships as an escape sequence and decodes
# back to itself. The property that matters — and the one the test asserts, after parsing — is that the
# value handed back is the value handed in.
ui=dict(ti)
ui["prompt"]=p+"\n\n[harness assignment] "+b
print(json.dumps({"hookSpecificOutput":{"hookEventName":"PreToolUse","updatedInput":ui}}))' 2>/dev/null || true
  fi
fi
exit 0
