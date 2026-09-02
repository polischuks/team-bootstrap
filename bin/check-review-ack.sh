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

_evaluate() {
  local marker mk bline bid bkind builder base_full head_full
  marker="$(resolve_marker)"
  [ -n "$marker" ] && [ -f "$marker" ] || { echo "check-review-ack: no active delivery run — skipping."; return 0; }
  mk="$(cat "$marker" 2>/dev/null || true)"
  [ "$(field_bool "$mk" intends_code)" = "true" ] || { echo "check-review-ack: marker not intends_code — skipping."; return 0; }

  bline="$(inflight_batch)"
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
  # ADR-0006): this proves *a* reviewer subagent of the right type was DISPATCHED — the record is a
  # PreToolUse attempt (spec 021 D2, AC-5), so "ran" was already one step beyond it — not that it is byte-identical
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
      fi
      # all-four-role-dispatch T4 — per-role PARITY: under ENFORCE, a review_acks claim needs the batch to
      # cover EVERY REQUIRED role (roles_covered ⊇ required_review_roles), not merely ≥1 dispatch. In warn
      # (default until references/role-dispatch-enforce is committed) the ≥1 corroboration above is the floor.
      if [ "$(role_floor_mode)" = "enforce" ]; then
        # SINGLE SOURCE (issue #70): read required_review_roles — the SAME set check-role-dispatch reads.
        # This gate runs BEFORE record_required_roles in verify-batch, so the recorded field is usually
        # ABSENT here; required_review_roles then computes required_roles_for_batch — the diff-sized set —
        # instead of the blanket mandated_roles(pipeline). Without this, a small batch inside a full run
        # failed HERE demanding the full 4-role panel, then PASSED role-dispatch (which runs after the
        # record) on the sized subset: the batch failed review-ack for roles the sizing said it didn't need.
        local _miss; _miss="$(missing_review_roles "$bid")"
        if [ -n "$_miss" ]; then
          echo "  FAIL: review_acks for '$bid' (pipeline='$pipeline', enforce) is missing required review role(s) [$_miss] — the per-role floor requires every required role dispatched under its dedicated review type, not just ≥1 (all-four-role-dispatch; single-sourced with check-role-dispatch, #70)." >&2
          viol=$((viol + 1))
        fi
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
  _disp() { printf '%s\n' "$1" > "$T/.runs/r/dispatch.jsonl"; }
  _chk() { if [ "$2" = "$3" ]; then echo "  PASS (exit $2) $1"; else echo "  FAIL (exit $2 want $3) $1" >&2; fail=$((fail + 1)); fi; }
  # R4-1: enforce marker at a temp path so no case touches the shipped references/role-dispatch-enforce.
  unset TEAM_BOOTSTRAP_ROLE_FLOOR; export TEAM_BOOTSTRAP_ROLE_ENFORCE_MARKER="$T/enforce-marker"; rm -f "$T/enforce-marker"

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
  # AC-24 (milestone 020) — the discipline holds for EVERY revived role, not only for code-reviewer.
  # A review_acks entry naming any of them is subject to the same four conditions: reviewer ≠ builder,
  # context clean, the commit reachable and post-baseline, verdict go. Parameterised over the roles the
  # profile can actually assign, so a role added to profiles/default.map without a case here is caught
  # by the loop rather than by nobody.
  for _r in security-reviewer data-schema-reviewer chaos-engineer test-designer \
            legal-compliance-checker ip-contracts-reviewer accessibility-reviewer \
            performance-reviewer overengineering-reviewer devops-platform; do
    _marker '{'"$M"',"review_acks":[{"batch":"C1","reviewer":"'"$_r"'","context":"clean","commit":"'"$C1"'","verdict":"go"}]}'
    _chk "AC-24 $_r: independent clean go review → pass" "$(_run)" 0
    _marker '{'"$M"',"review_acks":[{"batch":"C1","reviewer":"orchestrator","context":"clean","commit":"'"$C1"'","verdict":"go"}]}'
    _chk "AC-24 $_r: self-review by the builder → fail" "$(_run)" 1
    _marker '{'"$M"',"review_acks":[{"batch":"C1","reviewer":"'"$_r"'","context":"clean","commit":"'"$C1"'","verdict":"blocked"}]}'
    _chk "AC-24 $_r: verdict blocked → fail" "$(_run)" 1
  done

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

  # --- all-four-role-dispatch T4: per-role parity under ENFORCE (roles_covered ⊇ required_review_roles) --
  # RECORD the required set on the ledger line (issue #70): review-ack reads the SAME single source
  # (required_review_roles) check-role-dispatch reads, so this pins parity against a known 4-role set
  # rather than the retired blanket mandated_roles(pipeline).
  _batch '{"id":"C1","kind":"code","status":"announced","required_roles":["integration-verifier","architecture-reviewer","regression-guardian","code-reviewer"]}'
  _cover4rev() { { printf '{"batch":"C1","subagent_type":"integration-verifier"}\n'
    printf '{"batch":"C1","subagent_type":"architecture-reviewer"}\n'
    printf '{"batch":"C1","subagent_type":"regression-guardian"}\n'
    printf '{"batch":"C1","subagent_type":"tb-code-reviewer"}\n'; } > "$T/.runs/r/dispatch.jsonl"; }
  _marker "{$MF,$AOK}"
  # WARN (marker absent): a ≥1 generic dispatch still passes (parity fires only under enforce)
  _disp '{"batch":"C1","subagent_type":"code-reviewer"}'; rm -f "$T/enforce-marker"
  _chk "T4 warn: ≥1 generic dispatch → pass (parity off)" "$(_run)" 0
  # ENFORCE: generic-only (≥1 ok, ∅ roles) → fail (missing all mandated)
  touch "$T/enforce-marker"
  _chk "T4 enforce: generic-only → fail (roles_covered ⊉ mandated)" "$(_run)" 1
  # ENFORCE: all four roles covered → pass
  _cover4rev
  _chk "T4 enforce: all four roles covered → pass" "$(_run)" 0
  # ENFORCE: missing one role → fail
  _disp '{"batch":"C1","subagent_type":"tb-code-reviewer"}'
  _chk "T4 enforce: only one role → fail (missing 3)" "$(_run)" 1
  rm -f "$T/enforce-marker" "$T/.runs/r/dispatch.jsonl"

  rm -rf "$T"
  if [ "$fail" -eq 0 ]; then echo "check-review-ack --self-test: OK"; exit 0; fi
  echo "check-review-ack --self-test: $fail case(s) FAILED" >&2; exit 1
fi

# --- the contract card (issue #107) ------------------------------------------
# `--contract [project-dir]` prints THIS batch's FULL close-time requirement set BEFORE verify-batch
# enforces it — the close-time analogue of `check-role-verdict --fields` (#88), widened from one gate's
# fields to every artifact the close will demand. On spec-103 each requirement (tasks.md [x] format,
# review_acks, seam_acks, AC→test scoping) was learned only by hitting the gate that enforces it and
# reading its source; the card states them upfront so the operator satisfies them in one pass. It only
# REPORTS — it enforces nothing and never fails a batch (exit 0 unless it cannot resolve a run/batch).
_contract() {
  local marker mk bline bid bkind pipeline builder feat spec slug roles r
  marker="$(resolve_marker 2>/dev/null || true)"
  [ -n "$marker" ] && [ -f "$marker" ] || { echo "check-review-ack --contract: no active delivery run — nothing to describe."; return 0; }
  mk="$(cat "$marker" 2>/dev/null || true)"
  bline="$(inflight_batch 2>/dev/null || true)"
  bid="$(field_str "$bline" id)"
  [ -n "$bid" ] || { echo "check-review-ack --contract: no in-flight batch — announce a batch to see its close-time contract."; return 0; }
  bkind="$(field_str "$bline" kind)"
  pipeline="$(field_str "$mk" pipeline)"; [ -n "$pipeline" ] || pipeline="(unset)"
  builder="$(field_str "$mk" builder)"; [ -n "$builder" ] || builder="orchestrator"

  echo "==================================================================="
  echo "CLOSE-TIME CONTRACT CARD — batch '$bid' (kind=${bkind:-?}, pipeline=$pipeline)"
  echo "  What verify-batch will require to CLOSE this batch. Satisfy it upfront (#107)."
  echo "==================================================================="

  if [ "$bkind" != "code" ]; then
    echo "- kind:$bkind batch — the review/ack gates (roles, review_acks, seam_acks) do not apply; only"
    echo "  tasks.md completeness for its declared tasks is checked."
  fi

  # 1) required REVIEW ROLES (already sized for this batch) — the single-sourced set the gates read.
  roles="$(required_review_roles "$bid" 2>/dev/null || true)"
  echo "- Required review roles (sized for this batch): ${roles:-none}"
  echo "    Each required role must be DISPATCHED under its own review subagent type and return a typed"
  echo "    verdict (check-role-dispatch + check-role-verdict). Record each with:"
  echo "      bin/check-role-verdict.sh --record <role>   (the role's typed verdict JSON on stdin)"
  echo "    See its required fields upfront with: bin/check-role-verdict.sh --fields <role>"

  # 2) review_acks — the independent clean-context adversarial review (gate C).
  echo "- review_acks (gate C): ONE entry for this batch —"
  echo "      {batch:$bid, reviewer:<who>, context:clean, verdict:go, commit:<sha>}"
  echo "    reviewer must ≠ builder ('$builder'); context must be 'clean'; verdict must be 'go';"
  echo "    commit must resolve, be reachable from HEAD, and be post-baseline."
  echo "    #106: recording the code-reviewer verdict (approval_status:approved) with"
  echo "      bin/check-role-verdict.sh --record code-reviewer"
  echo "    AUTO-DERIVES this review_acks entry — no separate hand write needed. Otherwise record by hand:"
  echo "      bin/marker.sh review-ack --batch $bid --reviewer <who> --context clean --verdict go --commit <sha>"

  # 3) seam_acks — only when the batch diff touches a control-surface seam.
  echo "- seam_acks (check-seam-ack): REQUIRED only if this batch touches a control-surface seam."
  echo "    One entry per touched seam: {seam:<name>, commit:<sha>, note:<file:line + why>}. Record with:"
  echo "      bin/marker.sh seam-ack --seam <name> --commit <sha> --note \"<file:line + why>\""

  # 4) tasks.md checkbox format — read by check-completeness (per-batch AC-3, milestone AC-4).
  feat="$(field_str "$mk" feature)"
  case "$feat" in
    "") spec=""; slug="" ;;
    *.md) spec="$feat"; slug="$(basename "$(dirname "$feat")")" ;;
    *) spec="specs/${feat#specs/}"; spec="${spec%/}/spec.md"; slug="$(basename "${feat%/}")" ;;
  esac
  echo "- tasks.md format (check-completeness): tasks live in ${slug:+specs/$slug/}tasks.md as GFM"
  echo "    checkboxes '- [x]' (done) / '- [ ]' (open) — a task TABLE is not read. This batch's declared"
  echo "    task_ids must be '- [x]' to close (AC-3); NO '- [ ]' may remain at milestone --final (AC-4)."

  # 5) AC→test mapping — the scoping --final enforces (#94).
  echo "- AC→test mapping (check-completeness --final, #94): every 'AC-N' token in ${spec:-specs/<slug>/spec.md}"
  echo "    must appear in >=1 SPEC-SCOPED test file — one under the spec dir OR naming the slug"
  echo "    '${slug:-<slug>}' in its path/content — within 3 lines of a test/assertion construct. A bare or"
  echo "    cross-spec AC mention does NOT count (the slug is the discriminator)."
  echo "==================================================================="
  return 0
}

case "${1:-}" in
  --contract) shift
              root="${1:-.}"
              cd "$root" 2>/dev/null || { echo "check-review-ack: bad dir '$root'" >&2; exit 64; }
              _contract; exit $? ;;
esac

root="${1:-.}"
cd "$root" 2>/dev/null || { echo "check-review-ack: bad dir '$root'" >&2; exit 64; }
if _evaluate; then exit 0; else exit 1; fi
