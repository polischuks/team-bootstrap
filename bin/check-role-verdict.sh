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
# required_fields_for lives in delivery-lib.sh (#88) — ONE source, shared with subagent-brief.sh so the
# reviewer's brief can state the verdict shape upfront and this gate validates against the same schema.

# _record_verdict_tally BATCH ROLE — ISSUE #46: mirror a confirmed capture into a DURABLE, tamper-evident
# record that survives a removal of verdicts.jsonl. That file lost 4 records mid-run (run 096) while the
# RUN marker survived, and the loss was INVISIBLE: the gate simply reverted to "unverified". This plugin
# never deletes verdicts.jsonl itself — every run-file rewrite is a temp+mv on ONE named file (RUN,
# batches.jsonl, the marker), never a whole-dir operation — so it cannot PREVENT an external removal
# (cleanup, worktree teardown, a `rm -rf .runs`). What it can do is leave a record the removal does not
# erase: an append-only `verdicts_captured` set in the marker (rewritten atomically like every other
# marker field, via record_marker_list). The gate then reads the two together and can tell "captured
# then lost" from "never captured" — the same durability the project already gives gate outcomes.
# ISSUE #83 — the durable tally must survive a marker rewrite. #46 mirrored each capture into a
# `verdicts_captured` RUN-marker FIELD, but the marker is rewritten on many events (re-arm, resize,
# operator reconcile) and a rewrite that reconstructs it from a fixed field list drops the tally
# silently — observed live on run 177, where closed batches' entries were gone from the field while
# verdicts.jsonl kept all. The exact dropping writer was not reproducible in a fixture, so the fix does
# not depend on naming it: the tally now ALSO lives in a marker-INDEPENDENT append-only sidecar that no
# marker rewrite can touch. It is a DIFFERENT file from verdicts.jsonl, so #46's whole point — proving a
# capture happened after verdicts.jsonl is wiped — still holds.
_captured_sidecar() {
  local marker; marker="$(resolve_marker 2>/dev/null || true)"
  [ -n "$marker" ] || return 0
  printf '%s' "$(dirname "$marker")/verdicts-captured.jsonl"
}

# _captured_all → every captured token ("bid/role", quoted), the UNION of the durable sidecar and the
# legacy marker field, deduped. ONE reader for the tally so the count and the breach checks agree, and
# so a run written before the sidecar existed (marker field only) still reads correctly.
_captured_all() {
  local sc; sc="$(_captured_sidecar 2>/dev/null || true)"
  {
    [ -n "$sc" ] && [ -f "$sc" ] && grep -oE '"[^"]+/[^"]+"' "$sc" 2>/dev/null
    marker_list verdicts_captured 2>/dev/null | grep -oE '"[^"]+/[^"]+"'
  } | sort -u
}

_record_verdict_tally() {
  local bid="$1" role="$2" token sc cur body
  [ -n "$bid" ] && [ -n "$role" ] || return 0
  token="\"$bid/$role\""
  case "$(_captured_all 2>/dev/null)" in *"$token"*) return 0 ;; esac   # a set: never double-count a re-run
  # The durable store: append-only, marker-independent. This is the write #83 makes load-bearing.
  sc="$(_captured_sidecar 2>/dev/null || true)"
  [ -n "$sc" ] && { printf '{"token":%s}\n' "$token" >> "$sc" 2>/dev/null || true; }
  # The legacy marker mirror is kept best-effort: backward compatibility for readers that still look at
  # the field, and belt-and-suspenders durability. A drop of THIS no longer loses the tally (#83).
  cur="$(marker_list verdicts_captured 2>/dev/null || true)"
  [ -n "$cur" ] || cur="[]"
  case "$cur" in *"$token"*) return 0 ;; esac
  if [ "$cur" = "[]" ]; then
    record_marker_list verdicts_captured "[$token]" 2>/dev/null || true
  else
    body="${cur%]}"
    record_marker_list verdicts_captured "$body,$token]" 2>/dev/null || true
  fi
}

# _tallied_for BATCH → count of durable-tally entries recorded for BATCH (sidecar ∪ marker field, #83).
_tallied_for() {
  _captured_all 2>/dev/null | grep -oE "\"$1/[^\"]*\"" | grep -c . || true
}

# _persist_verdict BATCH ROLE RUNDIR — the ONE write that makes a confirmed verdict a fact the --gate
# reader sees: append the gate's own shape line to verdicts.jsonl (idempotent per batch+role) AND mirror
# it into the durable, tamper-evident marker tally (#46). Shared by BOTH capture paths — the SubagentStop
# hook (_hook_mode) and the synchronous orchestrator channel (_record_mode, #81) — so the two write
# byte-identical records and the gate cannot tell (or need to tell) which channel produced a verdict.
_persist_verdict() {
  local bid="$1" role="$2" rundir="$3"
  [ -n "$bid" ] && [ -n "$role" ] && [ -n "$rundir" ] && [ -d "$rundir" ] || return 0
  if ! grep -qF "{\"batch\":\"$bid\",\"role\":\"$role\",\"fields_ok\":true}" "$rundir/verdicts.jsonl" 2>/dev/null; then
    printf '{"batch":"%s","role":"%s","fields_ok":true}\n' "$bid" "$role" >> "$rundir/verdicts.jsonl" 2>/dev/null || true
  fi
  _record_verdict_tally "$bid" "$role"   # ISSUE #46 — durable, tamper-evident twin of the append above
}

# _record_capture_decline RUNDIR BATCH "REQUIRED" "DISPATCHED" DIAG — ISSUE #60. Append a diagnostic
# trace to .runs/<run>/verdict-capture.jsonl, written by THIS gate — a path that PROVENLY fires
# (verify-batch calls it at every batch close, and CI runs it). Before this, a seen==0 close left NOTHING
# behind: no verdict, and no decline record either, so the operator's only evidence was the gate's own
# guess ("the capture did not run OR could not read a transcript") — two very different failures it could
# not tell apart. dispatch.jsonl CAN tell them apart: if reviewers were dispatched and zero verdicts
# landed and no decline was traced, the capture channel did not fire (or fired blind and recorded
# nothing). The record names that observable state instead of guessing at it.
#
# De-duped per (batch, diagnosis): verify-batch retries the gate on every close attempt, so an
# append-per-call would balloon the file with identical lines. One line per distinct diagnosis is the
# signal; repeats are not.
_record_capture_decline() {
  local rundir="$1" bid="$2" req="$3" disp="$4" diag="$5" f
  [ -n "$rundir" ] && [ -d "$rundir" ] || return 0
  [ -n "$bid" ] && [ -n "$diag" ] || return 0
  f="$rundir/verdict-capture.jsonl"
  if [ -f "$f" ] && grep -F "\"batch\":\"$bid\"" "$f" 2>/dev/null | grep -qF "\"diagnosis\":\"$diag\""; then
    return 0
  fi
  printf '{"event":"gate-decline","batch":"%s","required":"%s","dispatched":"%s","verdicts_seen":0,"diagnosis":"%s"}\n' \
    "$bid" "$(json_esc "$req")" "$(json_esc "$disp")" "$diag" >> "$f" 2>/dev/null || true
}

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


# required_fields_for ROLE — moved to delivery-lib.sh (#88) as the single source shared with
# subagent-brief.sh. Empty when the role is unknown or declares none (nothing to confirm; the role is
# not eligible for the profile map — see tests/roles-alive.test.sh criterion 6).

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
  # ISSUE #44/#60 — where the role comes from. Two role sources, in order:
  #   1. --hook-role <slug> from the DECLARING FRONTMATTER: each review agent's own `Stop` hook (converted
  #      to SubagentStop while that subagent runs) already KNOWS its role and names it. This is primary and
  #      needs nothing from the payload.
  #   2. the payload's `agent_type`: the Claude Code hooks reference documents SubagentStop as carrying
  #      `agent_type` (the dispatched subagent type) — which is exactly what the PLUGIN-LEVEL SubagentStop
  #      registration (hooks.json, #60) relies on, since one registration covers many agent types and
  #      cannot pass a static --hook-role. (#44's earlier reading — that the payload carries NO type —
  #      held for the frontmatter-Stop shape it measured; the documented SubagentStop payload does carry
  #      `agent_type`, so the fallback is a real capture path for the plugin-level event, not dead code.)
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
  # ISSUE #60 — read the SUBAGENT's OWN transcript. A SubagentStop payload carries TWO transcript paths:
  # `transcript_path` is the MAIN SESSION transcript, and `agent_transcript_path` is the finished
  # subagent's own transcript (hooks reference). The verdict object lives in the SUBAGENT transcript, so a
  # hook reading `transcript_path` scanned the wrong file, found no verdict for the role, and exited 0 —
  # the 0-of-N silent miss EVEN WHEN the hook fired. Prefer `agent_transcript_path`; fall back to
  # `transcript_path` for a caller (e.g. a --hook-role frontmatter Stop on a host that supplies only it).
  tr="$(printf '%s' "$payload" | grep -oE '"agent_transcript_path"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | head -1 | sed -E 's/.*"([^"]*)"[[:space:]]*$/\1/')"
  [ -n "$tr" ] || tr="$(printf '%s' "$payload" | grep -oE '"transcript_path"[[:space:]]*:[[:space:]]*"[^"]*"' \
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
  # ISSUE #60 — record once (idempotent). Both the frontmatter Stop (as SubagentStop) AND the plugin-level
  # SubagentStop can fire for the same finished subagent; _persist_verdict de-dupes so that one review
  # appends one line. The gate only needs >=1 per role, so a duplicate is harmless to correctness — but a
  # bloated ledger is not free, and the durable tally is already a set, so the file matches it.
  _persist_verdict "$bid" "$role" "$rundir"
  exit 0
}

# _record_mode SLUG — ISSUE #81, the SYNCHRONOUS verdict channel. The gate cannot read the conversation,
# and SubagentStop does not fire for Agent-tool-dispatched review subagents (#60, proven host limit), so
# the verdict a reviewer returns in-report never reaches verdicts.jsonl on its own. This entry is the
# sanctioned write: after a review returns, the orchestrator pipes the reviewer's typed verdict object
# (role-output.schema.json shape) to `--record ROLE`, and this records it in EXACTLY the shape --gate
# reads — the same shape, validation, and durable tally as the hook path, via _persist_verdict.
#
# HONEST MECHANISM (do not overstate it): this is ORCHESTRATOR-recorded, not host-forced. Nothing in the
# host makes the orchestrator call it — commands/deliver.md instructs it to, and a run that skips the call
# simply lands back on the capture-dropped waiver. What it is NOT is transcript-scraping or a flaky async
# hook: when the orchestrator DOES call it, the write provably happens and --gate provably reads it. Its
# forgery bar is the existing one (ADR-0006/0008): the verdict must carry its role's required shape, and a
# well-formed lie still passes — the same limit the SubagentStop path already had.
#
# TIED TO THE RELIABLE DISPATCH RECORD. A verdict is recordable ONLY for a role that dispatch.jsonl shows
# was dispatched for the in-flight batch (the reliable PreToolUse[Agent] channel). Recording a verdict for
# an UNDISPATCHED role would forge a review that never ran — the exact "skipped" case #81's discriminating
# waiver keeps blocked — so it is refused here too. Defense in depth: the synchronous channel cannot be
# used to manufacture the evidence the gate exists to demand.
_record_mode() {
  local slug="${1:-}" role payload tmp obj missing f bline bid rundir dispatched
  if [ -z "$slug" ]; then
    echo "usage: $(basename "$0") --record ROLE   (the role's typed verdict JSON on stdin)" >&2
    echo "  records a confirmed verdict to .runs/<run>/verdicts.jsonl for the in-flight batch (#81)." >&2
    exit 64
  fi
  role="$(role_of_slug "$slug" 2>/dev/null || true)"      # slug → attributed role; a bare role name maps to itself
  [ -n "$role" ] || role="$slug"
  payload="$(head -c 1048576 2>/dev/null || true)"
  [ -n "$payload" ] || { echo "check-role-verdict --record: no verdict JSON on stdin for '$role' — nothing to record." >&2; exit 64; }
  tmp="$(mktemp 2>/dev/null)" || { echo "check-role-verdict --record: could not create a temp file." >&2; exit 1; }
  printf '%s' "$payload" > "$tmp"
  obj="$(_verdict_obj "$tmp" "$role")"      # SAME extractor the hook path uses: the object must carry "role":"<role>"
  rm -f "$tmp" 2>/dev/null || true
  if [ -z "$obj" ]; then
    echo "check-role-verdict --record: BLOCKED — stdin carried no JSON object with \"role\":\"$role\". A recorded verdict must be that role's own typed object (references/schemas/role-output.schema.json), not a summary or another role's object." >&2
    exit 2
  fi
  missing=""
  for f in $(required_fields_for "$role"); do
    printf '%s' "$obj" | grep -qE "\"$f\"[[:space:]]*:" || missing="${missing:+$missing }$f"
  done
  if [ -n "$missing" ]; then
    echo "check-role-verdict --record: BLOCKED — the '$role' verdict is missing the field(s) its own contract requires: [$missing]." >&2
    echo "  references/schemas/role-output.schema.json requires them of this role. A verdict without them is not a review result — it is a shape the closure gate cannot confirm (same bar as the SubagentStop path)." >&2
    exit 2
  fi
  bline="$(inflight_batch 2>/dev/null || true)"; bid="$(field_str "$bline" id)"
  [ -n "$bid" ] || { echo "check-role-verdict --record: no in-flight batch to attribute the '$role' verdict to — is a delivery run armed with a kind:code batch announced?" >&2; exit 1; }
  rundir="$(dirname "$(resolve_marker 2>/dev/null || true)")"
  [ -n "$rundir" ] && [ -d "$rundir" ] || { echo "check-role-verdict --record: no active run directory to record into." >&2; exit 1; }
  # The reliable-dispatch tie (see the header): refuse a verdict for a role with no dispatch record.
  dispatched="$(roles_covered "$bid" 2>/dev/null || true)"
  case " $dispatched " in
    *" $role "*) : ;;
    *)
      echo "check-role-verdict --record: REFUSED — '$role' has no dispatch record in .runs/<run>/dispatch.jsonl for batch '$bid'. A synchronous verdict is recordable only for a role actually dispatched (the reliable PreToolUse[Agent] channel); recording one for an undispatched role would forge a review that never ran (#81)." >&2
      exit 2 ;;
  esac
  _persist_verdict "$bid" "$role" "$rundir"
  echo "check-role-verdict --record: recorded a well-formed '$role' verdict for batch '$bid' → .runs/<run>/verdicts.jsonl (synchronous channel, #81). The --gate reader confirms it with no waiver." >&2
  # ISSUE #106 — AUTO-DERIVE the review_acks entry (check-review-ack gate C) from a recorded code-reviewer
  # verdict, so recording the review ONCE satisfies gate C without a second, hand-written ack. Scoped to
  # the code-reviewer role — the clean-context adversarial review gate C reads. Best-effort: a derive that
  # cannot be written never changes this command's exit status (the verdict is already recorded).
  [ "$role" = "code-reviewer" ] && _derive_review_ack "$obj" "$bid"
  exit 0
}

# _derive_review_ack VERDICT_OBJ BID — ISSUE #106. Translate a recorded code-reviewer verdict into the
# review_acks entry check-review-ack (gate C) reads, closing the "two writes for one fact" gap: the
# role-verdict and the review-ack were separate manual writes for the SAME clean-context code review.
#
# WHAT IT DERIVES, and WHAT IT REFUSES:
#   - approval_status == "approved"  → a review_acks entry {reviewer:code-reviewer, context:clean,
#     verdict:go, commit:HEAD}. HEAD is the anchor because --record runs after the reviewed code is
#     committed; it is reachable-from-HEAD and post-baseline, the two git facts gate C checks.
#   - approval_status != "approved" (changes_requested / anything else) → NO ack. A blocked/refuted review
#     must still surface as a finding and escalate — it may NOT auto-close the batch (AC: a blocked verdict
#     must not auto-ack).
#
# INDEPENDENCE PRESERVED (reviewer≠builder, OQ-4): the derived reviewer is "code-reviewer"; if the marker
# builder IS "code-reviewer" the derive is SKIPPED rather than forging a self-review. The write goes
# through marker.sh review-ack, which re-enforces reviewer≠builder and validates the shape — one owner of
# the review_acks contract, so a derived ack is byte-identical to a hand-written one.
#
# IDEMPOTENT: skips when a review_acks entry for BID already exists (a re-record, or a hand-authored ack
# the operator wrote first — the manual path stays available and wins).
_derive_review_ack() {
  local obj="$1" bid="$2" marker mk approval builder commit
  [ -n "$obj" ] && [ -n "$bid" ] || return 0
  marker="$(resolve_marker 2>/dev/null || true)"
  [ -n "$marker" ] && [ -f "$marker" ] || return 0
  mk="$(cat "$marker" 2>/dev/null || true)"
  # idempotent: a review_acks entry for THIS batch already present ⇒ nothing to derive (manual path wins).
  if printf '%s' "$mk" | grep -oE '"review_acks":[[:space:]]*\[[^]]*\]' | grep -qF "\"batch\":\"$bid\""; then
    return 0
  fi
  approval="$(field_str "$obj" approval_status)"
  if [ "$approval" != "approved" ]; then
    echo "check-role-verdict --record: code-reviewer approval_status='$approval' is not 'approved' — NOT auto-deriving a review_ack; a blocked/changes_requested review must surface as a finding and escalate, never auto-close the batch (#106)." >&2
    return 0
  fi
  builder="$(field_str "$mk" builder)"; [ -n "$builder" ] || builder="orchestrator"
  if [ "$builder" = "code-reviewer" ]; then
    echo "check-role-verdict --record: marker builder is 'code-reviewer' — NOT auto-deriving a review_ack (reviewer≠builder independence, OQ-4); record a genuinely independent review by hand if one ran (#106)." >&2
    return 0
  fi
  commit="$(git rev-parse --short HEAD 2>/dev/null || true)"
  [ -n "$commit" ] || return 0
  if "$here/marker.sh" review-ack --batch "$bid" --reviewer code-reviewer --context clean --verdict go --commit "$commit" >/dev/null 2>&1; then
    echo "check-role-verdict --record: AUTO-DERIVED a review_acks entry (reviewer=code-reviewer, context=clean, verdict=go, commit=$commit) for batch '$bid' from the recorded verdict — check-review-ack gate C is satisfied without a separate hand-written ack (#106)." >&2
  fi
  return 0
}

_gate_mode() {
  local marker mk bline bid pipeline rundir recorded req r missing seen tallied lost dispatched diag
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

  # ISSUE #46 — durability cross-check. verdicts_captured lives in the RUN marker, a DIFFERENT file from
  # verdicts.jsonl, so it survives a removal of the latter. A batch that was captured (tally > 0) but
  # whose file records are now gone (seen < tally) was TAMPERED WITH after the fact — a distinct, named
  # failure from one that was never captured. Both still refuse to pass; the difference is that the loss
  # is no longer silent.
  tallied="$(_tallied_for "$bid")"; tallied="${tallied:-0}"

  if [ "${seen:-0}" -eq 0 ]; then
    if [ "$tallied" -gt 0 ]; then
      echo "check-role-verdict: DURABILITY BREACH (#46) — $tallied verdict record(s) for batch '$bid' were captured and are still recorded in the RUN marker (verdicts_captured), but .runs/<run>/verdicts.jsonl is now empty or REMOVED. The evidence was lost AFTER capture; the marker retains proof it existed. This gate cannot re-confirm from a deleted file and does not pass on it — the removal is reported, not swallowed." >&2
    fi
    # A gate that declares its own blindness and then passes is the green-by-skip this whole tree exists
    # to refuse (spec 021 D3, AC-6; F1; constitution P10). "UNVERIFIED for this batch, not satisfied" is a
    # description of a failure; the return value agrees with it (it refuses below).
    #
    # ISSUE #60 — say WHY, from the observable, and leave a trace. dispatch.jsonl records whether reviewers
    # were dispatched for this batch, which distinguishes the two failures the old one-line guess conflated
    # ("did not run" vs "ran but could not read"). Write the finding to verdict-capture.jsonl by this gate
    # (a proven-firing path), and print a message grounded in that observable rather than the guess.
    dispatched="$(roles_covered "$bid" 2>/dev/null || true)"
    # ISSUE #81 — QUALIFY the waiver with the RELIABLE dispatch record so it can no longer bless a skipped
    # role. dispatch.jsonl (PreToolUse[Agent], record-dispatch.sh) records fact-of-dispatch reliably, so
    # the required roles ABSENT from it are the ones that were never dispatched — SKIPPED, not dropped.
    # A required role PRESENT in dispatch.jsonl but with no verdict is a capture that DROPPED (the flaky
    # SubagentStop channel), which is the only case the governed, expiring waiver may relieve. Before #81
    # a single blanket waiver covered both, so a batch that dispatched code-reviewer and simply skipped
    # integration-verifier could still be waved through as "capture dropped".
    local skipped=""
    for r in $req; do
      case " $dispatched " in *" $r "*) : ;; *) skipped="${skipped:+$skipped }$r" ;; esac
    done
    if [ "$tallied" -gt 0 ]; then diag="captured-then-lost"
    elif [ -z "$dispatched" ]; then diag="no-reviewer-dispatched"   # nothing dispatched at all → skipped
    elif [ -n "$skipped" ]; then diag="role-not-dispatched"          # some dispatched, but a required role was NOT → skipped
    else diag="capture-channel-did-not-fire"; fi                     # every required role dispatched, none captured → dropped
    _record_capture_decline "$rundir" "$bid" "$req" "$dispatched" "$diag"
    case "$diag" in
      capture-channel-did-not-fire)
        echo "check-role-verdict: UNVERIFIED — batch '$bid' required [$req]; dispatch.jsonl records reviewer dispatch(es) for [$dispatched], but .runs/<run>/verdicts.jsonl holds zero verdicts and no per-role decline was traced. The verdict-capture hook did not fire (or fired blind) for these Agent-tool dispatches — role confirmation is UNVERIFIED, not satisfied. Diagnosis recorded in .runs/<run>/verdict-capture.jsonl (#60)." >&2 ;;
      captured-then-lost)
        echo "check-role-verdict: UNVERIFIED — batch '$bid' (required: [$req]) had verdict(s) captured (durable marker tally) then REMOVED from verdicts.jsonl; see the durability breach above. Role confirmation is UNVERIFIED, not satisfied. Diagnosis recorded in .runs/<run>/verdict-capture.jsonl (#46/#60)." >&2 ;;
      role-not-dispatched)
        echo "check-role-verdict: UNVERIFIED — batch '$bid' required [$req]; dispatch.jsonl records dispatch(es) for [$dispatched] but NOT for [$skipped]. A required role was never dispatched (SKIPPED, not a dropped capture) — role_verdict_waiver relieves a dropped capture only and CANNOT pass a skipped role. This batch stays BLOCKED. Diagnosis recorded in .runs/<run>/verdict-capture.jsonl (#81)." >&2 ;;
      *)
        echo "check-role-verdict: UNVERIFIED — batch '$bid' required [$req] but no reviewer dispatch is recorded and no verdict was captured; every required role was SKIPPED, not dropped. role_verdict_waiver cannot pass a skipped batch — this stays BLOCKED. Diagnosis recorded in .runs/<run>/verdict-capture.jsonl (#81)." >&2 ;;
    esac

    # ISSUE #81 — the waiver is grantable ONLY for the dropped-capture cases (every required role IS on
    # the reliable dispatch channel; only the verdict CONTENT was lost). A skipped role — one with no
    # dispatch record — is never waivable, so we return before the waiver is consulted. This is the whole
    # point of splitting the diagnosis: the "skipped" case can never be waved through.
    case "$diag" in
      no-reviewer-dispatched|role-not-dispatched)
        return 1 ;;
    esac

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
      echo "check-role-verdict: WAIVED by a governed role_verdict_waiver (capture-dropped case: every required role was dispatched; finding surfaced above; by/reason/expires recorded, expiry forces re-review) — exit 0. See references/enforcement.md for the procedure." >&2
      return 0
    fi
    return 1
  fi
  missing=""; lost=""
  for r in $req; do
    if grep -qF "\"batch\":\"$bid\",\"role\":\"$r\"" "$rundir/verdicts.jsonl" 2>/dev/null; then continue; fi
    missing="${missing:+$missing }$r"
    # ISSUE #46/#83 — a role in the durable tally (sidecar ∪ marker field) but absent from verdicts.jsonl
    # was captured and then LOST, not one that never ran. Name the two apart.
    _captured_all 2>/dev/null | grep -q "\"$bid/$r\"" && lost="${lost:+$lost }$r"
  done
  if [ -n "$missing" ]; then
    echo "check-role-verdict: FAIL — batch '$bid' captured verdicts, but not from every required role. MISSING: [$missing] (required: [$req])." >&2
    [ -n "$lost" ] && echo "check-role-verdict: DURABILITY BREACH (#46) — of the missing, [$lost] WERE captured earlier (still in the RUN marker's verdicts_captured) and have since been REMOVED from verdicts.jsonl — a lost record, not a review that never ran." >&2
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
  # --fields ROLE|SLUG (#88): print the verdict fields the role's own schema requires, WITHOUT needing a
  # verdict — the upfront lookup that removes the discover-by-rejection round-trip. Accepts a dispatch
  # slug or a bare role name (resolved through the same role_of_slug the record/hook paths use).
  --fields) shift
            _fr="$(role_of_slug "${1:-}" 2>/dev/null || true)"; [ -n "$_fr" ] || _fr="${1:-}"
            required_fields_for "$_fr"; exit 0 ;;
  # --record ROLE (verdict JSON on stdin): the SYNCHRONOUS orchestrator channel (#81). Writes a confirmed
  # verdict to verdicts.jsonl at a point that reliably happens (the orchestrator, after a review returns),
  # independent of the flaky SubagentStop. See _record_mode's header for the honest mechanism.
  --record) shift; _record_mode "${1:-}" ;;
  # --hook-role SLUG: the SubagentStop hook that KNOWS its own role (declared in a review agent's
  # frontmatter). SLUG is resolved through role_of_slug exactly like the payload path, so the two agree.
  --hook-role) shift; _hook_mode "${1:-}" ;;
  *)      _hook_mode ;;
esac
