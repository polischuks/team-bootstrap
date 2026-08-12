#!/usr/bin/env bash
# check-delivery.sh — the delivery-occurred gate (fail-closed on unearned/FORGED closure).
#
# The other gates (quality-gate, orphans, architecture, gate-integrity) verify the
# delivered CODE is clean. NONE verifies that delivery actually HAPPENED, or that a
# "closed" line is BACKED BY REAL COMMITS. v2.11.0 moved closure from English prose to
# a JSON line — but the line was trusted: a hand-written
#   {"id":"B1","kind":"code","status":"closed","commit_shas":["deadbeef"],"code_delta":137}
# passed with exit 0 (a SHA git rejects, a number nobody checked). This gate closes that:
# closure is now a function of REPOSITORY STATE GIT CAN PROVE, not a self-declared field.
#
# Per closed kind:code entry:
#   - every commit_sha must resolve to a real commit          (AC-1; forged SHA -> fail)
#   - stamped code_delta must NOT exceed the git-RECOMPUTED    (AC-2; inflation -> fail)
#     non-doc delta over those commits (recompute uses the SAME shared function
#     verify-batch.sh stamps with — delivery-lib.sh nondoc_delta_of_shas — so an honest
#     stamp always passes; only an inflated one fails). "exceeds", not "differs":
#     honest history can recompute slightly ABOVE its range-diff stamp (see --self-test AC-3).
#   - code_delta > 0                                           (a code batch that changed no code)
# Announced-but-abandoned kind:code (a later batch exists, this never closed) -> fail.
# first-batch-must-be-code: a run delivering code must open with code, not docs.
# kind:doc entries earn no delivery credit and are never required to close.
#
# Ledger + SHA resolution + the non-doc delta come from bin/delivery-lib.sh (one
# definition, shared with verify-batch.sh — spec R1).
#
# Usage: bin/check-delivery.sh [project-dir]   # default: current dir
#        bin/check-delivery.sh --self-test     # AC-1/AC-2/AC-3 fixtures
# Exit:  0 clean / no ledger (not machine-checkable) · 1 unearned/forged closure · 64 bad usage
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/delivery-lib.sh
. "$here/delivery-lib.sh"

# --- self-test ---------------------------------------------------------------
if [ "${1:-}" = "--self-test" ]; then
  st_root="$(pwd)"; fail=0
  _expect() { # runname expected_exit desc
    local rn="$1" exp="$2" desc="$3" got
    TEAM_BOOTSTRAP_RUN="$rn" "$0" "$st_root" >/dev/null 2>&1; got=$?
    if [ "$got" -eq "$exp" ]; then echo "  PASS (exit $got) $desc"
    else echo "  FAIL (exit $got, want $exp) $desc" >&2; fail=$((fail + 1)); fi
  }
  mkdir -p .runs/_st_ac1 .runs/_st_ac2
  printf '%s\n' '{"id":"F1","kind":"code","status":"closed","commit_shas":["deadbeef"],"code_delta":137}' > .runs/_st_ac1/batches.jsonl
  _expect _st_ac1 1 "AC-1 — forged deadbeef SHA rejected"
  printf '%s\n' '{"id":"F2","kind":"code","status":"closed","commit_shas":["4d4a42d"],"code_delta":137}' > .runs/_st_ac2/batches.jsonl
  _expect _st_ac2 1 "AC-2 — inflated code_delta over a doc-only commit rejected"
  if [ -f ".runs/deliver-delivery-guard/batches.jsonl" ]; then
    _expect deliver-delivery-guard 0 "AC-3 — historical honest ledger (B1-B5) still passes"
  else
    echo "  SKIP  AC-3 — historical ledger absent (gate-integrity: sanctioned — fixture not present in this checkout)"
  fi
  rm -rf .runs/_st_ac1 .runs/_st_ac2
  if [ "$fail" -eq 0 ]; then echo "check-delivery --self-test: OK"; exit 0; fi
  echo "check-delivery --self-test: $fail case(s) FAILED" >&2; exit 1
fi

root="${1:-.}"
cd "$root" 2>/dev/null || { echo "check-delivery: bad dir '$root'" >&2; exit 64; }

ledger="$(resolve_ledger)"
if [ -z "$ledger" ] || [ ! -f "$ledger" ]; then
  echo "check-delivery: no batch ledger — delivery not machine-checkable, skipping."
  exit 0
fi

total="$(grep -c . "$ledger" 2>/dev/null || echo 0)"
n=0
viol=0
first_kind=""
any_code=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  n=$((n + 1))
  kind="$(field_str "$line" kind)"
  [ "$n" -eq 1 ] && first_kind="$kind"
  [ "$kind" = "code" ] || continue   # doc batches: no delivery credit
  any_code=1
  id="$(field_str "$line" id)"; [ -n "$id" ] || id="#$n"
  status="$(field_str "$line" status)"
  if [ "$status" = "closed" ]; then
    delta="$(field_num "$line" code_delta)"; case "$delta" in ''|*[!0-9-]*) delta=0 ;; esac
    shas="$(shas_of_line "$line")"
    # AC-1 — closure must be tied to commits git can prove.
    if [ -z "$shas" ]; then
      echo "  FORGED: batch '$id' closed kind:code with no commit_shas — closure tied to no commit." >&2
      viol=$((viol + 1)); continue
    fi
    missing=""
    for s in $shas; do
      [ -n "$s" ] || continue
      [ -z "$(resolve_sha "$s")" ] && missing="$missing $s"
    done
    if [ -n "$missing" ]; then
      echo "  FORGED: batch '$id' cites commit_sha(s) git cannot resolve:$missing — closure not backed by real commits (AC-1)." >&2
      viol=$((viol + 1)); continue
    fi
    # a code batch that changed no code is unearned (P0.3, preserved).
    if [ "$delta" -le 0 ]; then
      echo "  UNEARNED: batch '$id' closed with code_delta=$delta — a code batch that changed no code." >&2
      viol=$((viol + 1)); continue
    fi
    # AC-2 — stamped delta may not EXCEED the git-recomputed non-doc delta (inflation).
    recomputed="$(nondoc_delta_of_shas "$shas")"
    if [ "$delta" -gt "$recomputed" ]; then
      echo "  FORGED: batch '$id' stamped code_delta=$delta EXCEEDS git-recomputed non-doc delta=$recomputed over [${shas}] — inflated closure (AC-2)." >&2
      viol=$((viol + 1)); continue
    fi
  elif [ "$n" -eq "$total" ]; then
    echo "check-delivery: batch '$id' in flight (status=$status) — not yet closed, allowed."
  else
    echo "  UNEARNED: batch '$id' is kind:code status='$status' — announced then abandoned (a later batch exists, this one never closed)." >&2
    viol=$((viol + 1))
  fi
done < "$ledger"

# first-batch-must-be-code: a run that delivers ANY code must open with code, not
# docs — the load-bearing code leads, documentation does not front-run it.
if [ "$any_code" -eq 1 ] && [ "$first_kind" = "doc" ]; then
  echo "  ORDERING: first batch is kind:doc while the run delivers code later — a delivery run must open with the load-bearing code, not documentation." >&2
  viol=$((viol + 1))
fi

if [ "$viol" -gt 0 ]; then
  echo "check-delivery: $viol unearned/forged closure(s) in $ledger — closure is earned by real commits + a git-verified delta, not by assertion." >&2
  exit 1
fi
echo "check-delivery: all kind:code batches earned closure (git-verified) ($ledger)."
exit 0
