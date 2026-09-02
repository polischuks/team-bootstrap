#!/usr/bin/env bash
# tests/review-ack-autoderive.test.sh — issues #106 and #107.
#
# #106 — role-verdict and review-ack are two writes for ONE fact. Recording the code-reviewer role-verdict
# (verdict:go / approval_status:approved, clean context) must AUTO-DERIVE the review_acks entry check-
# review-ack (gate C) reads, so gate C is satisfied WITHOUT a separate hand-written ack. A blocked /
# changes_requested verdict must NOT auto-ack (it must still surface as a finding). reviewer≠builder
# independence is preserved (the derived reviewer is code-reviewer; a code-reviewer builder is never
# self-acked).
#
# #107 — a pre-verify CONTRACT CARD: `check-review-ack.sh --contract` prints THIS batch's full close-time
# requirement set (required review roles, tasks.md [x] format, review_acks/seam_acks fields, AC→test
# scoping) so the operator satisfies them upfront instead of by tripping verify-batch one gate at a time.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
V="$here/bin/check-role-verdict.sh"
A="$here/bin/check-review-ack.sh"
fail=0
_chk() { if [ "$1" = "$2" ]; then printf '  PASS %s\n' "$3"
  else printf '  FAIL %s (got [%s] want [%s])\n' "$3" "$1" "$2" >&2; fail=$((fail + 1)); fi; }

# --- shared fixture: a git repo with an armed full run, a kind:code batch, a reviewer dispatch ----------
_mkfix() {
  local d; d="$(mktemp -d)"
  ( cd "$d" || exit 1; git init -q; git config user.email a@b.c; git config user.name t
    printf 'x\n' > s.txt; git add -A; git commit -q -m b0
    printf 'y\n' >> s.txt; git add -A; git commit -q -m b1
    mkdir -p .runs/r
    printf '{"run":"r","pipeline":"full","intends_code":true,"builder":"orchestrator","baseline_sha":"%s"}\n' "$(git rev-parse --short HEAD~1)" > .runs/r/RUN
    printf '{"id":"B1","kind":"code","status":"announced","required_roles":["code-reviewer"]}\n' > .runs/r/batches.jsonl
    printf '%s\n' '{"batch":"B1","subagent_type":"team-bootstrap:tb-code-reviewer","outcome":"attempted"}' > .runs/r/dispatch.jsonl ) >/dev/null 2>&1
  printf '%s' "$d"
}

echo "#106 — recording a code-reviewer verdict:go (approved, clean) auto-derives the review_acks entry:"
D="$(_mkfix)"
# Gate C fails before any review is recorded (no review_acks entry).
_chk "$( ( cd "$D" || exit 1; TEAM_BOOTSTRAP_RUN=r "$A" . >/dev/null 2>&1 ); echo $? )" 1 \
  "before --record: gate C fails (no review_acks entry)"
# Record the code-reviewer verdict ONCE, through the synchronous channel.
_chk "$( ( cd "$D" || exit 1; printf '%s' '{"role":"code-reviewer","approval_status":"approved"}' \
  | TEAM_BOOTSTRAP_RUN=r "$V" --record code-reviewer >/dev/null 2>&1 ); echo $? )" 0 \
  "--record code-reviewer (approved) → exit 0"
# THE #106 ACCEPTANCE: gate C now PASSES with NO separately hand-written review_acks entry.
_chk "$( ( cd "$D" || exit 1; TEAM_BOOTSTRAP_RUN=r "$A" . >/dev/null 2>&1 ); echo $? )" 0 \
  "after --record: gate C PASSES from the auto-derived review_ack (no second hand write)"
# A review_acks entry now exists in the marker, naming the code-reviewer with verdict go / context clean.
_mk="$(cat "$D/.runs/r/RUN" 2>/dev/null)"
_chk "$(printf '%s' "$_mk" | grep -c '"review_acks":\[')" 1 "a review_acks array was written to the marker"
_chk "$(printf '%s' "$_mk" | grep -oE '"review_acks":\[[^]]*\]' | grep -qF '"reviewer":"code-reviewer"' && echo yes || echo no)" yes \
  "  …reviewer=code-reviewer"
_chk "$(printf '%s' "$_mk" | grep -oE '"review_acks":\[[^]]*\]' | grep -qF '"context":"clean"' && echo yes || echo no)" yes \
  "  …context=clean"
_chk "$(printf '%s' "$_mk" | grep -oE '"review_acks":\[[^]]*\]' | grep -qF '"verdict":"go"' && echo yes || echo no)" yes \
  "  …verdict=go"
# INDEPENDENCE preserved: the derived reviewer differs from the marker builder (orchestrator).
_chk "$(printf '%s' "$_mk" | grep -oE '"review_acks":\[[^]]*\]' | grep -qF '"reviewer":"orchestrator"' && echo self || echo independent)" independent \
  "  …reviewer ≠ builder (no self-review forged)"
rm -rf "$D"

echo "#106 — a BLOCKED / changes_requested verdict does NOT auto-ack:"
D="$(_mkfix)"
_chk "$( ( cd "$D" || exit 1; printf '%s' '{"role":"code-reviewer","approval_status":"changes_requested"}' \
  | TEAM_BOOTSTRAP_RUN=r "$V" --record code-reviewer >/dev/null 2>&1 ); echo $? )" 0 \
  "--record code-reviewer (changes_requested) → exit 0 (verdict still recorded)"
_mk="$(cat "$D/.runs/r/RUN" 2>/dev/null)"
_chk "$(printf '%s' "$_mk" | grep -c '"review_acks":\[')" 0 "NO review_acks entry derived from a blocked verdict"
_chk "$( ( cd "$D" || exit 1; TEAM_BOOTSTRAP_RUN=r "$A" . >/dev/null 2>&1 ); echo $? )" 1 \
  "gate C still FAILS on a blocked review (must escalate, not auto-close)"
rm -rf "$D"

echo "#106 — a code-reviewer BUILDER is never self-acked (independence guard):"
D="$(_mkfix)"
# Rewrite the marker so the builder IS code-reviewer.
printf '{"run":"r","pipeline":"full","intends_code":true,"builder":"code-reviewer","baseline_sha":"%s"}\n' \
  "$( ( cd "$D" && git rev-parse --short HEAD~1 ) )" > "$D/.runs/r/RUN"
( cd "$D" || exit 1; printf '%s' '{"role":"code-reviewer","approval_status":"approved"}' \
  | TEAM_BOOTSTRAP_RUN=r "$V" --record code-reviewer >/dev/null 2>&1 )
_mk="$(cat "$D/.runs/r/RUN" 2>/dev/null)"
_chk "$(printf '%s' "$_mk" | grep -c '"review_acks":\[')" 0 "builder==code-reviewer → no auto-ack forged (reviewer≠builder held)"
rm -rf "$D"

echo "#107 — the contract card lists THIS batch's close-time requirement set:"
D="$(_mkfix)"
_card="$( ( cd "$D" || exit 1; TEAM_BOOTSTRAP_RUN=r "$A" --contract . 2>&1 ) )"
_rc=$?
_chk "$_rc" 0 "--contract exits 0"
_chk "$(printf '%s' "$_card" | grep -ciE 'review[_ -]?role')" 1 "card names the required review roles (>=1 mention)"
_chk "$(printf '%s' "$_card" | grep -qF 'code-reviewer' && echo yes || echo no)" yes "  …including the sized code-reviewer role"
_chk "$(printf '%s' "$_card" | grep -qiE '\[x\]' && echo yes || echo no)" yes "card states the tasks.md [x] checkbox format"
_chk "$(printf '%s' "$_card" | grep -qiE 'review_acks' && echo yes || echo no)" yes "card names review_acks"
_chk "$(printf '%s' "$_card" | grep -qiE 'seam_acks' && echo yes || echo no)" yes "card names seam_acks"
_chk "$(printf '%s' "$_card" | grep -qiE 'AC-?N|AC→test|AC-[0-9]|acceptance' && echo yes || echo no)" yes "card names the AC→test mapping --final checks"
rm -rf "$D"

[ "$fail" -eq 0 ] && { echo "review-ack-autoderive.test.sh: OK"; exit 0; }
echo "review-ack-autoderive.test.sh: $fail failure(s)" >&2; exit 1
