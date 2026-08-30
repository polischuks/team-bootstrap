#!/usr/bin/env bash
# batch-review-depth.test.sh — issue #84: review DEPTH must be sized to the BATCH, not fixed to the run.
#
# The role SET has been per-batch since #27/#70 (required_roles_for_batch reads the batch diff), but the
# DEPTH each dispatched reviewer is told to run at came from ONE number — the run marker's `pipeline`
# field — so subagent-brief.sh told every reviewer on every batch, including a small reversible feature
# batch inside a `full` run, to review at `high` on the /code-review scale. That is the measured cost:
# ~2.5h/run for ~4 code batches, each reviewer 3.6–11.8 min, all at max depth regardless of the batch.
#
# The fix makes depth derive from batch_effective_tier(bid) — the same per-batch tier (select-pipeline
# --batch, then the spec-plan and judge floors, one-directional) that already sizes the role set. So a
# reversible batch is billed its own (lower) depth, and a batch whose diff/plan names a risk is lifted.
#
# Written BEFORE the fix → red (brief says `high` for a small batch), then green (`low`/`medium`).
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
BIN="$here/../bin"
fail=0
_chk() { if [ "$2" = "$3" ]; then echo "  PASS $1"; else echo "  FAIL $1 (got [$2] want [$3])" >&2; fail=$((fail + 1)); fi; }
PY() { python3 -c "$1" "${@:2}"; }

# additionalContext extractor for a SubagentStart hook emission.
_ctx() { PY 'import json,sys
try:
    d=json.loads(sys.stdin.read()); print(d.get("hookSpecificOutput",{}).get("additionalContext",""))
except Exception: print("")'; }

# ---------------------------------------------------------------------------
# Fixture: a `full` run with a small, reversible one-line batch — the exact shape #70 uses to prove the
# role set sizes below the full panel. If the roles size down, the tier is below full, so the depth must
# too.
# ---------------------------------------------------------------------------
T="$(mktemp -d)"; mkdir -p "$T/.runs/r"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t
  printf 'base\n' > f && git add . && git commit -qm base ) >/dev/null 2>&1
base="$(cd "$T" && git rev-parse --short HEAD)"
( cd "$T" && printf 'x\n' >> f && git add . && git commit -qm b1 ) >/dev/null 2>&1
c1="$(cd "$T" && git rev-parse --short HEAD)"
export TEAM_BOOTSTRAP_RUN=r

printf '{"run":"r","pipeline":"full","intends_code":true,"source":"harness","builder":"orchestrator","baseline_sha":"%s"}\n' "$base" > "$T/.runs/r/RUN"
printf '{"id":"B1","kind":"code","status":"announced","commit_shas":["%s"]}\n' "$c1" > "$T/.runs/r/batches.jsonl"

# Sanity: the batch really does size below the full panel (else there is no down-sizing to bill).
sized="$( cd "$T" && bash -c '. "'"$BIN"'/delivery-lib.sh"; required_roles_for_batch B1' )"
case " $sized " in *" integration-verifier "*|*" architecture-reviewer "*|*" regression-guardian "*)
  echo "  FAIL fixture: sized set [$sized] is not below the full panel — cannot exercise #84" >&2; fail=$((fail + 1)) ;;
esac

# The batch tier the depth should follow, and its depth.
btier="$( cd "$T" && bash -c '. "'"$BIN"'/delivery-lib.sh"; batch_effective_tier B1' )"
bdepth="$( cd "$T" && bash -c '. "'"$BIN"'/delivery-lib.sh"; review_depth_for_tier "$(batch_effective_tier B1)"' )"
echo "batch_effective_tier(B1)=[$btier] → depth [$bdepth]   (run pipeline=full → depth high)"

# AC-1 — the batch tier is genuinely below `full` (the premise of the whole finding).
case "$btier" in single-thread|mvp) _chk "batch tier is below full for a one-line batch" ok ok ;;
  *) _chk "batch tier is below full for a one-line batch" "$btier" "single-thread|mvp" ;; esac

# AC-2 — the reviewer's brief carries the BATCH depth, not the run depth. THIS is the red line.
OUT="$( cd "$T" && printf '%s' '{"subagent_type":"tb-code-reviewer"}' | "$BIN/subagent-brief.sh" 2>/dev/null )"
CTX="$(printf '%s' "$OUT" | _ctx)"
_chk "brief is emitted for the in-flight code batch" "$([ -n "$CTX" ] && echo nonempty || echo empty)" nonempty
# The emitted depth VALUE (the word right after "depth for this batch:") must equal the batch depth —
# matched in POSITION, not anywhere, because the scale label "low-medium-high" contains all three words.
_emit_depth="$(printf '%s' "$CTX" | grep -oiE 'depth for this batch:[[:space:]]*[a-z]+' | head -1 | grep -oiE '[a-z]+$')"
_chk "brief states the batch depth in the value position" "$_emit_depth" "$bdepth"
# … and that value must NOT be the run's `high` (the pre-fix behaviour).
_chk "brief does NOT bill the run's high depth on a reversible batch" \
  "$([ "$_emit_depth" = high ] && echo billed-high || echo ok)" ok

# ---------------------------------------------------------------------------
# AC-3 — one-directional the other way: a batch whose DIFF trips a risk category is LIFTED to full/high
# even inside a lower-tier run. Depth follows the batch up as well as down.
# ---------------------------------------------------------------------------
T2="$(mktemp -d)"; mkdir -p "$T2/.runs/r"
( cd "$T2" && git init -q && git config user.email t@t && git config user.name t
  printf 'base\n' > f && git add . && git commit -qm base ) >/dev/null 2>&1
b2="$(cd "$T2" && git rev-parse --short HEAD)"
( cd "$T2" && mkdir -p db && printf 'CREATE TABLE t (id int);\nALTER TABLE t ADD COLUMN x int;\n' > db/schema.sql
  git add . && git commit -qm risk ) >/dev/null 2>&1
c2="$(cd "$T2" && git rev-parse --short HEAD)"
printf '{"run":"r","pipeline":"mvp","intends_code":true,"source":"harness","builder":"orchestrator","baseline_sha":"%s"}\n' "$b2" > "$T2/.runs/r/RUN"
printf '{"id":"B9","kind":"code","status":"announced","commit_shas":["%s"]}\n' "$c2" > "$T2/.runs/r/batches.jsonl"
rtier="$( cd "$T2" && bash -c '. "'"$BIN"'/delivery-lib.sh"; batch_effective_tier B9' )"
rdepth="$( cd "$T2" && bash -c '. "'"$BIN"'/delivery-lib.sh"; review_depth_for_tier "$(batch_effective_tier B9)"' )"
echo "risk batch B9 in an mvp run: batch_effective_tier=[$rtier] → depth [$rdepth]  (run mvp → depth medium)"
# The schema diff should lift this batch's tier above the run's mvp; depth must rise with it.
_chk "risk batch is lifted above the run tier (depth is high, not the run's medium)" "$rdepth" high

rm -rf "$T" "$T2"
if [ "$fail" -eq 0 ]; then echo "batch-review-depth.test.sh: OK"; exit 0; fi
echo "batch-review-depth.test.sh: $fail case(s) FAILED" >&2; exit 1
