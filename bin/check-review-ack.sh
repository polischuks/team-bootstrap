#!/usr/bin/env bash
# check-review-ack.sh — verify-batch gate C (milestone closed-loop-fidelity, batch C1): a kind:code batch
# cannot close without a recorded, INDEPENDENT, clean-context adversarial review of its diff. Closes the
# retro's residual semantic class (F2 write-before-validate ordering, F6 aggregation/no-op) that no
# structural fitness function sees — the post-code review the orchestrator can otherwise consolidate away.
#
# The reviewer runs in a fresh subagent context (P2) seeing only the diff + enumerated criteria, prompted
# to REFUTE (Refute-or-Promote). The orchestrator records the outcome to the run marker:
#   review_acks:        [{batch, reviewer, context, commit, verdict}]
#   review_refutations: [{batch, class, outcome, finding_id}]   (flat; one per attempted refutation)
#
# For the in-flight kind:code batch, closing requires a review_acks entry whose:
#   - reviewer is present AND ≠ the batch builder identity (marker `builder`, default "orchestrator"; OQ-4
#     — CODEOWNERS/required-reviewer semantics: no self-review);
#   - context == "clean" (saw only the diff+criteria, not the builder's reasoning);
#   - commit resolves, is reachable from HEAD, and post-baseline (the review looked at the shipped code);
#   - verdict == "go".
# And EVERY review_refutations entry for this batch with outcome=="credible" must carry a finding_id that
# resolves to a review_findings entry of severity ≥ MEDIUM — so check-disposition (gate B, ordered BEFORE
# C in verify-batch) governs that live counterexample's waiver, not a bare present string (soundness B2 +
# re-review #3). A credible refutation with no B-governed finding ⇒ fail (the self-approval bypass, closed).
#
# HONEST LIMIT (ADR-0006): the gate enforces the review's PRESENCE, independence, clean-context attestation,
# commit anchor, and refutation governance — NOT the correctness of the verdict. The *who* (reviewer≠builder)
# is a marker string, forgeable by the same orchestrator; the *when* (commit) is git-grounded. Parity with
# seam_acks/risk_rank — presence enforced, honesty logged not proven.
#
# Parse note: refutation governance is fail-CLOSED on value punctuation — a raw `{` `}` `[` `]` inside a
# refutation field value (e.g. class/finding_id) makes the jq-free parse reject the record (safe direction:
# blocks, never leaks). Keep refutation field values free of raw braces/brackets. Forged/invalid-JSON
# markers fall inside the HONEST LIMIT below (a marker is orchestrator-written, not machine-proven).
#
# Graceful skips (exit 0): no active marker / not intends_code / in-flight batch not kind:code.
#
# Usage: bin/check-review-ack.sh [project-dir]  ·  bin/check-review-ack.sh --self-test
# Exit:  0 governed / skip · 1 missing / self / blocked / ungoverned-credible-refutation · 64 bad usage
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/delivery-lib.sh
. "$here/delivery-lib.sh"

# _array_objects MK KEY → one flat {...} object per line for the JSON array at "KEY":[...] (flat objects only).
_array_objects() {
  local mk="$1" key="$2" arr
  arr="$(printf '%s' "$mk" | grep -oE "\"$key\":[[:space:]]*\[[^]]*\]" | head -1)"
  [ -n "$arr" ] || return 0
  printf '%s' "$arr" | grep -oE '\{[^}]*\}'
}
# _refutation_objects MK → one refutation object per line, matched by SIGNATURE (contains "outcome") rather
# than by isolating the array bounds. This tolerates a `]` inside a field value (e.g. class:"predicate[0]"),
# which the array-bounds parse (`\[[^]]*\]`, stops at first `]`) would truncate — a FAIL-OPEN the review
# found: a truncated review_refutations array silently drops a credible refutation. `[^{}]` allows `]` in
# values; "outcome" is unique to refutation objects (acks carry verdict/reviewer, findings carry severity).
_refutation_objects() { printf '%s' "$1" | grep -oE '\{[^{}]*"outcome":[^{}]*\}'; }
# _obj_by MK KEY FIELD VALUE → the first object in array KEY whose FIELD == VALUE (rc 1 if none).
_obj_by() {
  local mk="$1" key="$2" field="$3" val="$4" obj
  while IFS= read -r obj; do
    [ -n "$obj" ] || continue
    [ "$(field_str "$obj" "$field")" = "$val" ] && { printf '%s' "$obj"; return 0; }
  done <<EOF
$(_array_objects "$mk" "$key")
EOF
  return 1
}
_sev_ge_medium() { case "$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')" in MEDIUM|HIGH|CRITICAL) return 0 ;; esac; return 1; }

# _inflight_batch → the in-flight ledger line (last announced; else last non-empty).
_inflight_batch() {
  local ledger line
  ledger="$(resolve_ledger)"; [ -n "$ledger" ] && [ -f "$ledger" ] || return 0
  line="$(grep '"status":[[:space:]]*"announced"' "$ledger" 2>/dev/null | tail -1)"
  [ -n "$line" ] || line="$(grep -v '^[[:space:]]*$' "$ledger" 2>/dev/null | tail -1)"
  printf '%s' "$line"
}

_evaluate() {
  local marker mk bline bid bkind builder base_full head_full
  marker="$(resolve_marker)"
  [ -n "$marker" ] && [ -f "$marker" ] || { echo "check-review-ack: no active delivery run — skipping."; return 0; }
  mk="$(cat "$marker" 2>/dev/null || true)"
  [ "$(field_bool "$mk" intends_code)" = "true" ] || { echo "check-review-ack: marker not intends_code — skipping."; return 0; }

  bline="$(_inflight_batch)"
  [ -n "$bline" ] || { echo "check-review-ack: no in-flight batch — nothing to review."; return 0; }
  bid="$(field_str "$bline" id)"; bkind="$(field_str "$bline" kind)"
  [ "$bkind" = "code" ] || { echo "check-review-ack: in-flight batch '$bid' is kind=$bkind (not code) — skipping."; return 0; }

  builder="$(field_str "$mk" builder)"; [ -n "$builder" ] || builder="orchestrator"
  base_full="$(resolve_sha "$(field_str "$mk" baseline_sha)" 2>/dev/null || true)"
  head_full="$(git rev-parse HEAD 2>/dev/null || true)"

  # 1) require a review_acks entry for this batch
  local ack reviewer context commit verdict cfull
  if ! ack="$(_obj_by "$mk" review_acks batch "$bid")"; then
    echo "  FAIL-CLOSED: kind:code batch '$bid' has NO review_acks entry — an independent clean-context review must run before it closes (no self-consolidated review; F2/F6)." >&2
    return 1
  fi
  reviewer="$(field_str "$ack" reviewer)"; context="$(field_str "$ack" context)"; commit="$(field_str "$ack" commit)"; verdict="$(field_str "$ack" verdict)"

  local viol=0
  if [ -z "$reviewer" ] || [ "$reviewer" = "$builder" ]; then
    echo "  FAIL: review_acks reviewer='$reviewer' empty or == builder '$builder' — no independence (reviewer must ≠ builder, OQ-4)." >&2; viol=$((viol + 1))
  fi
  [ "$context" = "clean" ] || { echo "  FAIL: review_acks context='$context' — must be 'clean' (reviewer saw only the diff + criteria, not the builder's reasoning)." >&2; viol=$((viol + 1)); }
  [ "$verdict" = "go" ] || { echo "  FAIL: review_acks verdict='$verdict' — not 'go' (a blocked review cannot close the batch; escalate)." >&2; viol=$((viol + 1)); }

  cfull="$(resolve_sha "$commit" 2>/dev/null || true)"
  if [ -z "$cfull" ]; then
    echo "  FAIL: review_acks commit '$commit' does not resolve." >&2; viol=$((viol + 1))
  else
    if [ -n "$head_full" ] && ! git merge-base --is-ancestor "$cfull" "$head_full" 2>/dev/null; then
      echo "  FAIL: review_acks commit $commit not reachable from HEAD (the review must be of the shipped code)." >&2; viol=$((viol + 1))
    fi
    if [ -n "$base_full" ] && ! git merge-base --is-ancestor "$base_full" "$cfull" 2>/dev/null; then
      echo "  FAIL: review_acks commit $commit is not post-baseline." >&2; viol=$((viol + 1))
    fi
  fi

  # 1b) HARNESS CORROBORATION (exec-role-integrity B3): in full/mvp, the review_acks `reviewer` claim
  # must be backed by a harness-recorded reviewer-typed DISPATCH for this batch (dispatch.jsonl,
  # reviewer_dispatch_count) — not merely a marker string. This upgrades the v2.20.0 forgeable-marker
  # residual (ADR-0006): a review that never dispatched an independent subagent cannot close. single-
  # thread is EXEMPT — P1 sanctions inline reviewers there, which dispatch nothing. Honest limit (N2/
  # ADR-0006): this proves *a* reviewer subagent of the right type ran, not that it is byte-identical
  # to `reviewer` nor that the review was substantive.
  local pipeline
  pipeline="$(field_str "$mk" pipeline)"
  case "$pipeline" in
    single-thread) : ;;   # P1: inline reviewers dispatch nothing — the only EXEMPT pipeline
    *)
      # full/mvp AND any unrecognized/absent pipeline require the dispatch corroboration. An intends_code
      # kind:code batch whose pipeline cannot be confirmed single-thread must NOT fall back to the weaker
      # marker-only (v2.20.0) check — that would fail OPEN on undeterminable input (review FIX#1). A
      # well-formed harness marker always records single-thread|mvp|full.
      if [ "$(reviewer_dispatch_count "$bid")" -eq 0 ]; then
        echo "  FAIL: review_acks for '$bid' names reviewer='$reviewer' but NO reviewer-typed subagent dispatch was recorded for this batch (pipeline='$pipeline') — the review claim is not harness-corroborated (a marker string alone is forgeable; exec-role-integrity B3). single-thread is the only exempt pipeline; an unrecognized pipeline fails closed." >&2
        viol=$((viol + 1))
      fi ;;
  esac

  # 2a) fail-closed parse-integrity guard (independent review, round 2). A naive single-regex object
  # extractor cannot survive arbitrary value punctuation: the first fix rotated the vulnerable char from
  # ']' to '{'/'}'. Rather than chase a total regex, make ambiguity a SAFE REJECTION. "outcome" is unique
  # to refutation objects, so the raw count of `"outcome":` tokens is the TRUE number of refutations; if
  # the extractor parsed fewer VALID (batch-bearing) objects, some value broke the parse ⇒ the governance
  # record is unverifiable ⇒ FAIL-CLOSED (never silently govern fewer credible refutations than exist).
  local raw_outcomes valid_refs=0 _ro
  raw_outcomes="$(printf '%s' "$mk" | grep -oE '"outcome":' | grep -c . || true)"
  while IFS= read -r _ro; do
    [ -n "$_ro" ] || continue
    [ -n "$(field_str "$_ro" batch)" ] && valid_refs=$((valid_refs + 1))
  done <<EOF
$(_refutation_objects "$mk")
EOF
  if [ "${raw_outcomes:-0}" -gt "${valid_refs:-0}" ]; then
    echo "  FAIL-CLOSED: review_refutations record unparseable — $raw_outcomes refutation(s) present but only $valid_refs parsed with a valid batch; a value contains { } [ ] punctuation that broke the parse. Ambiguous governance record ⇒ rejected (not fail-open)." >&2
    viol=$((viol + 1))
  fi

  # 2b) every credible refutation for this batch must link to a B-governed (≥MEDIUM) finding
  local robj rbatch rout rfid fobj fsev
  while IFS= read -r robj; do
    [ -n "$robj" ] || continue
    rbatch="$(field_str "$robj" batch)"; [ "$rbatch" = "$bid" ] || continue
    # normalize outcome: strip surrounding whitespace before matching, so "credible " (trailing space from
    # a sloppy generator) is not misclassed as non-credible — another FAIL-OPEN the review found.
    rout="$(field_str "$robj" outcome | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]')"
    case "$rout" in credible) : ;; *) continue ;; esac
    rfid="$(field_str "$robj" finding_id)"
    if [ -z "$rfid" ]; then
      echo "  FAIL: a CREDIBLE refutation on batch '$bid' has no finding_id — a live counterexample must be recorded as a review_findings entry so gate B governs it (soundness B2)." >&2; viol=$((viol + 1)); continue
    fi
    if ! fobj="$(_obj_by "$mk" review_findings id "$rfid")"; then
      echo "  FAIL: credible refutation finding_id='$rfid' resolves to no review_findings entry (B never governed it)." >&2; viol=$((viol + 1)); continue
    fi
    fsev="$(field_str "$fobj" severity)"
    if ! _sev_ge_medium "$fsev"; then
      echo "  FAIL: credible refutation finding_id='$rfid' links a $fsev finding — must be MEDIUM+ to be in gate B's jurisdiction (re-review #3)." >&2; viol=$((viol + 1)); continue
    fi
  done <<EOF
$(_refutation_objects "$mk")
EOF

  if [ "$viol" -gt 0 ]; then
    echo "  FAIL-CLOSED: batch '$bid' review-ack invalid ($viol issue(s)) — independent, clean-context, verdict:go review with governed refutations is required to close (F2/F6)." >&2
    return 1
  fi
  echo "check-review-ack: batch '$bid' has a valid independent review (reviewer=$reviewer≠builder, context=clean, verdict=go, commit=$commit; credible refutations B-governed). OK."
  return 0
}

# --- self-test ---------------------------------------------------------------
if [ "${1:-}" = "--self-test" ]; then
  fail=0; T="$(mktemp -d)"; mkdir -p "$T/.runs/r"
  ( cd "$T" && git init -q && git config user.email t@t && git config user.name t
    echo a > f.txt && git add . && git commit -qm c0
    echo b >> f.txt && git add . && git commit -qm c1 ) >/dev/null 2>&1
  BASE="$(cd "$T" && git rev-parse --short HEAD~1)"; C1="$(cd "$T" && git rev-parse --short HEAD)"
  _marker() { printf '%s\n' "$1" > "$T/.runs/r/RUN"; }
  _batch()  { printf '%s\n' "$1" > "$T/.runs/r/batches.jsonl"; }
  _run() { ( cd "$T" && TEAM_BOOTSTRAP_RUN=r "$here/check-review-ack.sh" . >/dev/null 2>&1 ); echo $?; }
  _chk() { if [ "$2" = "$3" ]; then echo "  PASS (exit $2) $1"; else echo "  FAIL (exit $2 want $3) $1" >&2; fail=$((fail + 1)); fi; }

  _batch '{"id":"C1","kind":"code","status":"announced"}'
  # Base marker: single-thread so these cases exercise the ARTIFACT logic (reviewer≠builder, verdict,
  # commit, refutations) WITHOUT triggering the full/mvp dispatch corroboration (which is covered by the
  # B3 cases below with an explicit full marker). single-thread reviewers run inline — dispatch-exempt.
  M='"run":"r","pipeline":"single-thread","intends_code":true,"builder":"orchestrator","baseline_sha":"'"$BASE"'"'
  AOK='"review_acks":[{"batch":"C1","reviewer":"code-reviewer","context":"clean","commit":"'"$C1"'","verdict":"go"}]'

  # AC-6 — no review_acks entry → fail
  _marker "{$M}"
  _chk "AC-6 kind:code + no review_acks → fail" "$(_run)" 1
  # AC-6 — valid independent review, verdict go, anchored → pass
  _marker "{$M,$AOK}"
  _chk "AC-6 independent clean go review (anchored) → pass" "$(_run)" 0
  # AC-7 — reviewer == builder (self-review) → fail
  _marker '{'"$M"',"review_acks":[{"batch":"C1","reviewer":"orchestrator","context":"clean","commit":"'"$C1"'","verdict":"go"}]}'
  _chk "AC-7 self-review (reviewer==builder) → fail" "$(_run)" 1
  # AC-7 — verdict blocked → fail
  _marker '{'"$M"',"review_acks":[{"batch":"C1","reviewer":"code-reviewer","context":"clean","commit":"'"$C1"'","verdict":"blocked"}]}'
  _chk "AC-7 verdict blocked → fail" "$(_run)" 1
  # AC-7 — context not clean → fail
  _marker '{'"$M"',"review_acks":[{"batch":"C1","reviewer":"code-reviewer","context":"dirty","commit":"'"$C1"'","verdict":"go"}]}'
  _chk "AC-7 context not clean → fail" "$(_run)" 1
  # AC-7 — commit not post-baseline (uses BASE, which is the baseline itself → not strictly after) still reachable;
  #         use an unresolvable commit → fail
  _marker '{'"$M"',"review_acks":[{"batch":"C1","reviewer":"code-reviewer","context":"clean","commit":"deadbeef","verdict":"go"}]}'
  _chk "AC-7 unresolvable commit → fail" "$(_run)" 1
  # AC-7 — credible refutation WITHOUT a linked finding → fail (self-approval bypass closed)
  _marker '{'"$M"','"$AOK"',"review_refutations":[{"batch":"C1","class":"ordering","outcome":"credible"}]}'
  _chk "AC-7 credible refutation, no finding_id → fail" "$(_run)" 1
  # AC-7 — credible refutation linked to a LOW finding → fail (outside B jurisdiction)
  _marker '{'"$M"','"$AOK"',"review_findings":[{"id":"F9","severity":"LOW","disposition":"downgraded"}],"review_refutations":[{"batch":"C1","class":"ordering","outcome":"credible","finding_id":"F9"}]}'
  _chk "AC-7 credible refutation → LOW finding → fail" "$(_run)" 1
  # AC-6 — credible refutation linked to a MEDIUM finding (B-governed) → pass
  _marker '{'"$M"','"$AOK"',"review_findings":[{"id":"F9","severity":"MEDIUM","disposition":"downgraded"}],"review_refutations":[{"batch":"C1","class":"ordering","outcome":"credible","finding_id":"F9"}]}'
  _chk "AC-6 credible refutation → MEDIUM finding → pass" "$(_run)" 0
  # non-credible refutation (outcome none) → pass, no finding needed
  _marker '{'"$M"','"$AOK"',"review_refutations":[{"batch":"C1","class":"ordering","outcome":"none"}]}'
  _chk "non-credible refutation → pass" "$(_run)" 0
  # REGRESSION (independent review, credible #1): a ']' inside a refutation value must NOT truncate the
  # parse and silently drop a credible refutation (was FAIL-OPEN). Credible + ']' in class + no finding → fail.
  _marker '{'"$M"','"$AOK"',"review_refutations":[{"batch":"C1","class":"predicate[0]","outcome":"credible","finding_id":""}]}'
  _chk "REGRESSION ']' in value does not drop credible refutation → fail" "$(_run)" 1
  # REGRESSION (independent review, credible #2): 'credible ' with trailing space must still be governed → fail.
  _marker '{'"$M"','"$AOK"',"review_refutations":[{"batch":"C1","class":"ordering","outcome":"credible "}]}'
  _chk "REGRESSION 'credible ' (trailing space) still governed → fail" "$(_run)" 1
  # REGRESSION (independent review round 2): a '}' or '{' in a refutation value must not fail OPEN — the
  # parse-integrity guard rejects the unparseable governance record (fail-closed).
  _marker '{'"$M"','"$AOK"',"review_refutations":[{"batch":"C1","class":"a}b","outcome":"credible","finding_id":""}]}'
  _chk "REGRESSION '}' in value → parse-integrity guard → fail" "$(_run)" 1
  _marker '{'"$M"','"$AOK"',"review_refutations":[{"batch":"C1","class":"a{b","outcome":"credible","finding_id":""}]}'
  _chk "REGRESSION '{' in value → parse-integrity guard → fail" "$(_run)" 1
  # PIN (independent review round 3, safe-direction usability limit): a legitimately-GOVERNED credible
  # refutation whose value contains a raw brace ALSO fails-closed (the guard cannot tell it from a break).
  # This is the safe direction (blocks, never leaks). Pinned so a future "usability fix" that makes braces
  # parse cannot silently reintroduce a fail-open without turning this red. Avoid raw {}/[] in values.
  _marker '{'"$M"','"$AOK"',"review_findings":[{"id":"F9","severity":"MEDIUM","disposition":"downgraded"}],"review_refutations":[{"batch":"C1","class":"map{k}v","outcome":"credible","finding_id":"F9"}]}'
  _chk "PIN '{' in value even when governed → fail-closed (safe direction)" "$(_run)" 1
  # skip — in-flight batch is kind:doc → skip
  _batch '{"id":"Z","kind":"doc","status":"announced"}'
  _marker "{$M}"
  _chk "skip: kind:doc batch → pass" "$(_run)" 0
  # skip — no marker
  _batch '{"id":"C1","kind":"code","status":"announced"}'; rm -f "$T/.runs/r/RUN"
  _chk "skip: no active marker → pass" "$(_run)" 0

  # exec-role-integrity B3 — full/mvp: a review_acks entry must be corroborated by a reviewer-typed
  # DISPATCH record (dispatch.jsonl) for the batch; single-thread is exempt (inline reviewers).
  _batch '{"id":"C1","kind":"code","status":"announced"}'
  MF='"run":"r","pipeline":"full","intends_code":true,"builder":"orchestrator","baseline_sha":"'"$BASE"'"'
  rm -f "$T/.runs/r/dispatch.jsonl"
  _marker "{$MF,$AOK}"
  _chk "B3 full + review_acks + no reviewer dispatch → fail" "$(_run)" 1
  printf '{"batch":"C1","subagent_type":"backend-developer"}\n' > "$T/.runs/r/dispatch.jsonl"
  _chk "B3 full + review_acks + builder-only dispatch → fail" "$(_run)" 1
  printf '{"batch":"C1","subagent_type":"code-reviewer"}\n' > "$T/.runs/r/dispatch.jsonl"
  _chk "B3 full + review_acks + reviewer-typed dispatch → pass" "$(_run)" 0
  rm -f "$T/.runs/r/dispatch.jsonl"
  _marker '{"run":"r","pipeline":"single-thread","intends_code":true,"builder":"orchestrator","baseline_sha":"'"$BASE"'",'"$AOK"'}'
  _chk "B3 single-thread + review_acks + no dispatch → pass (exempt)" "$(_run)" 0
  # FIX#1 — an UNKNOWN/absent pipeline (malformed marker) on an intends_code code batch must fail-closed
  # (require corroboration), not fall back to the marker-only check.
  rm -f "$T/.runs/r/dispatch.jsonl"
  _marker '{"run":"r","pipeline":"audit","intends_code":true,"builder":"orchestrator","baseline_sha":"'"$BASE"'",'"$AOK"'}'
  _chk "B3 unknown pipeline (audit) + review_acks + no dispatch → fail-closed" "$(_run)" 1
  _marker '{"run":"r","intends_code":true,"builder":"orchestrator","baseline_sha":"'"$BASE"'",'"$AOK"'}'
  _chk "B3 absent pipeline + review_acks + no dispatch → fail-closed" "$(_run)" 1
  rm -f "$T/.runs/r/dispatch.jsonl"

  rm -rf "$T"
  if [ "$fail" -eq 0 ]; then echo "check-review-ack --self-test: OK"; exit 0; fi
  echo "check-review-ack --self-test: $fail case(s) FAILED" >&2; exit 1
fi

root="${1:-.}"
cd "$root" 2>/dev/null || { echo "check-review-ack: bad dir '$root'" >&2; exit 64; }
if _evaluate; then exit 0; else exit 1; fi
