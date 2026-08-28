#!/usr/bin/env bash
# tests/exec-role-integrity.test.sh — integration test for the harness-verified role-execution gate
# (milestone exec-role-integrity, v2.21.0). End-to-end: the PreToolUse[Agent] dispatch recorder feeds
# the role-dispatch gate, and the gate is wired into verify-batch.
#
# Carries the AC tokens for check-completeness --final (every AC-N referenced by a test-path file):
#   AC-1 — full/mvp kind:code batch with ZERO reviewer-typed dispatch records → gate exit 1 + loud msg;
#          ≥1 such record → exit 0; a builder-typed dispatch does NOT satisfy it.
#   AC-2 — a review_acks entry with no corresponding reviewer-typed dispatch record → check-review-ack fails
#          (corroboration; asserted in Batch C — tests/check-review-ack.test.sh / its --self-test).
#   AC-3 — single-thread pipeline or non-kind:code batch → gate skips (exit 0).
#   AC-4 — the degradation message is surfaced to the user (stdout), not only stderr.
#   AC-5 — record-dispatch + check-role-dispatch ship --self-test; check-gate-integrity clean; gate wired.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
_chk() { if [ "$2" = "$3" ]; then echo "  PASS (exit $2) $1"; else echo "  FAIL (exit $2 want $3) $1" >&2; fail=$((fail + 1)); fi; }

# --- AC-5: both new scripts exist and DECLARE a --self-test --------------------
# This loop used to RUN each script's --self-test here. bin/run-tests.sh already runs every
# bin/*.sh --self-test as its own member, so re-executing them inside this integration test re-ran work
# the suite had just done and added only forks (issue #79 — the same dedup #51 applied to gates-wiring).
# check-role-dispatch --self-test in particular builds git fixtures and is not cheap. What is unique to
# THIS file is the end-to-end recorder→gate wiring exercised below; the peer self-tests' PASS/FAIL is
# answered once, in the sweep. Here we assert only the wiring fact: the script exists and is
# self-testable (a script that lost its --self-test drops out of the sweep silently).
for s in record-dispatch check-role-dispatch; do
  if [ -x "$here/bin/$s.sh" ] || [ -f "$here/bin/$s.sh" ]; then
    # Matched with run-tests' OWN detection pattern — a real dispatch on the flag, not a mere mention.
    if grep -qE -- '(--self-test\)|= "--self-test" \]|=--self-test)' "$here/bin/$s.sh" 2>/dev/null; then
      echo "  PASS AC-5 $s declares a --self-test (run-tests runs it)"; else
      echo "  FAIL AC-5 $s declares no --self-test dispatch — it would drop out of the run-tests sweep" >&2; fail=$((fail + 1)); fi
  else echo "  FAIL AC-5 $s missing" >&2; fail=$((fail + 1)); fi
done

# Dropping the re-run above is safe ONLY because run-tests really sweeps every bin/*.sh --self-test.
# Assert that, rather than assuming it (mirrors gates-wiring / issue #51).
if grep -qE 'bin/\*\.sh|for f in .*bin' "$here/bin/run-tests.sh" 2>/dev/null \
   && grep -q -- '--self-test' "$here/bin/run-tests.sh" 2>/dev/null; then
  echo "  PASS AC-5 run-tests sweeps bin/*.sh --self-test (so this file need not re-run them)"; else
  echo "  FAIL AC-5 run-tests does NOT sweep bin/*.sh --self-test — dropping the self-tests here loses coverage" >&2
  fail=$((fail + 1)); fi

# --- AC-5: the gate is wired into verify-batch.sh -------------------------------
if grep -q 'check-role-dispatch.sh' "$here/bin/verify-batch.sh"; then echo "  PASS AC-5 gate wired into verify-batch"; else
  echo "  FAIL AC-5 gate NOT wired into verify-batch" >&2; fail=$((fail + 1)); fi

# --- AC-5: check-gate-integrity clean on this repo -----------------------------
if bash "$here/bin/check-gate-integrity.sh" "$here" >/dev/null 2>&1; then echo "  PASS AC-5 gate-integrity clean"; else
  echo "  FAIL AC-5 gate-integrity" >&2; fail=$((fail + 1)); fi

# --- end-to-end: recorder feeds the gate ---------------------------------------
T="$(mktemp -d)"; mkdir -p "$T/.runs/r"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t
  echo base > f && git add . && git commit -qm base ) >/dev/null 2>&1
base="$(cd "$T" && git rev-parse --short HEAD)"
printf '{"run":"r","pipeline":"full","intends_code":true,"source":"harness","baseline_sha":"%s"}\n' "$base" > "$T/.runs/r/RUN"
printf '{"id":"B1","kind":"code","status":"announced"}\n' > "$T/.runs/r/batches.jsonl"

# a reviewer-typed dispatch payload (PreToolUse[Agent].tool_input.subagent_type ∈ review-set)
rev='{"tool_name":"Agent","tool_input":{"subagent_type":"code-reviewer","prompt":"review the diff"}}'
bld='{"tool_name":"Agent","tool_input":{"subagent_type":"backend-developer","prompt":"build the endpoint"}}'
_rec() { ( cd "$T" && printf '%s' "$1" | TEAM_BOOTSTRAP_RUN=r "$here/bin/record-dispatch.sh" >/dev/null 2>&1 ); echo $?; }
# The property THIS file tests is the >=1 anti-collapse floor (exec-role-integrity, v2.21.0): a batch
# that dispatched no reviewer at all has collapsed review into the builder. That is a different question
# from the PER-ROLE floor, which asks whether all four mandated roles ran and which milestone 020 flipped
# to enforce by default (AC-26). Pinning warn here keeps these cases measuring what they are named for
# instead of silently re-testing the mode; the enforce behaviour has its own cases at the end of the file.
_gate() { ( cd "$T" && TEAM_BOOTSTRAP_RUN=r TEAM_BOOTSTRAP_ROLE_FLOOR=warn "$here/bin/check-role-dispatch.sh" . >/dev/null 2>&1 ); echo $?; }
# _gate_enforce — the same call with the shipped default (no override), for the AC-26 cases.
_gate_enforce() { ( cd "$T" && TEAM_BOOTSTRAP_RUN=r "$here/bin/check-role-dispatch.sh" . >/dev/null 2>&1 ); echo $?; }

# AC-1 — before any reviewer dispatch, a full/code batch → gate fails (degraded to single-thread)
_chk "AC-1 full+code, zero reviewer dispatch → gate fail" "$(_gate)" 1
# recorder ignores a builder-typed dispatch (AC-1 negative: builder does not satisfy)
_chk "AC-1 record a builder-typed dispatch → non-blocking exit 0" "$(_rec "$bld")" 0
_chk "AC-1 builder-only dispatch → gate still fails" "$(_gate)" 1
# recorder records a reviewer-typed dispatch → gate now passes
_chk "AC-1 record a reviewer-typed dispatch → non-blocking exit 0" "$(_rec "$rev")" 0
_chk "AC-1 ≥1 reviewer dispatch → gate passes" "$(_gate)" 0

# AC-4 — the degradation message reaches STDOUT (user-visible), not only stderr
printf '{"run":"r2","pipeline":"full","intends_code":true,"source":"harness","baseline_sha":"%s"}\n' "$base" > "$T/.runs/r/RUN2" 2>/dev/null || true
mkdir -p "$T/.runs/r2"
printf '{"run":"r2","pipeline":"full","intends_code":true,"source":"harness","baseline_sha":"%s"}\n' "$base" > "$T/.runs/r2/RUN"
printf '{"id":"B1","kind":"code","status":"announced"}\n' > "$T/.runs/r2/batches.jsonl"
msg="$( cd "$T" && TEAM_BOOTSTRAP_RUN=r2 "$here/bin/check-role-dispatch.sh" . 2>/dev/null )"
case "$msg" in *degrad*|*single-thread*) echo "  PASS AC-4 degradation message on stdout" ;; *) echo "  FAIL AC-4 no user-visible message on stdout (got: $msg)" >&2; fail=$((fail + 1)) ;; esac

# AC-3 — a single-thread run → skip (exit 0) even with zero reviewer dispatch
mkdir -p "$T/.runs/st"
printf '{"run":"st","pipeline":"single-thread","intends_code":true,"source":"harness","baseline_sha":"%s"}\n' "$base" > "$T/.runs/st/RUN"
printf '{"id":"B1","kind":"code","status":"announced"}\n' > "$T/.runs/st/batches.jsonl"
_chk "AC-3 single-thread pipeline → gate skips" "$( cd "$T" && TEAM_BOOTSTRAP_RUN=st "$here/bin/check-role-dispatch.sh" . >/dev/null 2>&1; echo $? )" 0

rm -rf "$T"

# --- AC-2: check-review-ack corroboration (Batch C, T5) -------------------------
# A review_acks entry is valid only when a reviewer-typed dispatch record exists for that batch's
# window in full/mvp — the marker `reviewer` claim must be harness-corroborated, not merely present
# (soundness B3). single-thread is exempt (reviewers run inline there — no dispatch).
T2="$(mktemp -d)"; mkdir -p "$T2/.runs/r"
( cd "$T2" && git init -q && git config user.email t@t && git config user.name t
  echo a > f && git add . && git commit -qm c0
  echo b >> f && git add . && git commit -qm c1 ) >/dev/null 2>&1
b2="$(cd "$T2" && git rev-parse --short HEAD~1)"; c2="$(cd "$T2" && git rev-parse --short HEAD)"
printf '{"id":"B1","kind":"code","status":"announced"}\n' > "$T2/.runs/r/batches.jsonl"
MK2='"run":"r","pipeline":"full","intends_code":true,"builder":"orchestrator","baseline_sha":"'"$b2"'"'
AOK2='"review_acks":[{"batch":"B1","reviewer":"code-reviewer","context":"clean","commit":"'"$c2"'","verdict":"go"}]'
# Pinned to warn for the same reason as _gate above: these cases test the >=1 CORROBORATION property
# (a review_acks claim needs a reviewer-typed dispatch behind it), not the per-role mode. check-review-ack
# mirrors check-role-dispatch's per-role parity under enforce (N3, no drift), so leaving the mode free
# would make them re-test AC-26 under an AC-2 name. The enforce case is asserted separately below.
_ra() { ( cd "$T2" && TEAM_BOOTSTRAP_RUN=r TEAM_BOOTSTRAP_ROLE_FLOOR=warn "$here/bin/check-review-ack.sh" . >/dev/null 2>&1 ); echo $?; }
_ra_enforce() { ( cd "$T2" && TEAM_BOOTSTRAP_RUN=r "$here/bin/check-review-ack.sh" . >/dev/null 2>&1 ); echo $?; }
# full + valid review_acks + NO reviewer dispatch → fail (claim not harness-corroborated)
printf '{%s,%s}\n' "$MK2" "$AOK2" > "$T2/.runs/r/RUN"; rm -f "$T2/.runs/r/dispatch.jsonl"
_chk "AC-2 full + review_acks + no reviewer dispatch → check-review-ack fail" "$(_ra)" 1
# full + valid review_acks + builder-only dispatch → fail (a builder dispatch does not corroborate)
printf '{"batch":"B1","subagent_type":"backend-developer"}\n' > "$T2/.runs/r/dispatch.jsonl"
_chk "AC-2 full + review_acks + builder-only dispatch → fail" "$(_ra)" 1
# full + valid review_acks + reviewer-typed dispatch → pass
printf '{"batch":"B1","subagent_type":"code-reviewer"}\n' > "$T2/.runs/r/dispatch.jsonl"
_chk "AC-2 full + review_acks + reviewer dispatch → pass" "$(_ra)" 0
# AC-26 (milestone 020) — the same state under the shipped default: per-role parity now applies here
# too, so one corroborating dispatch on a full batch is no longer enough. Both guarantees, side by side.
_chk "AC-26 …and under the shipped enforce default the same state needs per-role parity" "$(_ra_enforce)" 1
# single-thread + valid review_acks + no dispatch → pass (corroboration is full/mvp-scoped)
printf '{"run":"r","pipeline":"single-thread","intends_code":true,"builder":"orchestrator","baseline_sha":"%s",%s}\n' "$b2" "$AOK2" > "$T2/.runs/r/RUN"
rm -f "$T2/.runs/r/dispatch.jsonl"
_chk "AC-2 single-thread + review_acks + no dispatch → pass (exempt)" "$(_ra)" 0
rm -rf "$T2"


# AC-26 (milestone 020) — the per-role floor is ENFORCE by default, and the >=1 anti-collapse floor is
# still hard underneath it. Two separate guarantees; both asserted on ONE freshly built state, because
# $T above has accumulated dispatches and ledger edits across the whole file and inheriting it would
# make the result depend on test order rather than on the property.
T26="$(mktemp -d)"
( cd "$T26" || exit 1
  git init -q; git config user.email a@b.c; git config user.name t
  mkdir -p .runs/r; echo base > f; git add .; git commit -qm base
  b="$(git rev-parse --short HEAD)"
  printf '{"run":"r","pipeline":"full","intends_code":true,"source":"harness","baseline_sha":"%s"}\n' "$b" > .runs/r/RUN
  printf '{"id":"B1","kind":"code","status":"announced"}\n' > .runs/r/batches.jsonl
  printf '{"batch":"B1","subagent_type":"code-reviewer"}\n' > .runs/r/dispatch.jsonl )
_g26() { ( cd "$T26" && env $1 TEAM_BOOTSTRAP_RUN=r "$here/bin/check-role-dispatch.sh" . >/dev/null 2>&1 ); echo $?; }
_chk "AC-26 one generic reviewer on a full batch → PER-ROLE floor blocks (enforce is the default)" "$(_g26 '')" 1
_chk "AC-26 …while the same state passes the >=1 anti-collapse floor under warn" "$(_g26 'TEAM_BOOTSTRAP_ROLE_FLOOR=warn')" 0
rm -rf "$T26"

[ "$fail" -eq 0 ] && { echo "exec-role-integrity.test.sh: OK"; exit 0; }
echo "exec-role-integrity.test.sh: $fail failure(s)" >&2; exit 1
