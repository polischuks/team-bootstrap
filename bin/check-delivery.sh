#!/usr/bin/env bash
# check-delivery.sh — the delivery-occurred gate (fail-closed on unearned closure).
#
# The other gates (quality-gate, orphans, architecture, gate-integrity) verify the
# delivered CODE is clean. NONE verifies that delivery actually HAPPENED. A batch can
# be declared "closed" in prose while no pipeline ran and no code changed — the exact
# failure this gate exists to make impossible. Closure must be EARNED by a machine
# stamp (see verify-batch.sh), never asserted by the orchestrator.
#
# Reads the batch ledger .runs/<run>/batches.jsonl (one compact JSON object per line):
#   {"id":..,"kind":"code|doc","status":"announced|closed",..,"code_delta":<n>}
# The orchestrator writes an entry at Announce (status:announced). verify-batch.sh
# stamps a passing batch: status->closed, commit_shas, code_delta. Only the machine
# can flip status to closed.
#
# Rule, per kind:code entry:
#   - status:closed        -> require code_delta > 0 (a code batch that changed no code
#                             is unearned closure).
#   - status:announced     -> allowed ONLY if it is the last line (the in-flight batch);
#                             an announced code batch with a LATER batch after it was
#                             announced and then abandoned — unearned. FAIL.
# kind:doc entries earn no delivery credit and are never required to close.
#
# Ledger resolution: $TEAM_BOOTSTRAP_RUN, else the newest .runs/*/batches.jsonl.
#
# Usage: bin/check-delivery.sh [project-dir]   # default: current dir
# Exit:  0 clean / no ledger (not machine-checkable) · 1 unearned closure · 64 bad usage
set -uo pipefail

root="${1:-.}"
cd "$root" 2>/dev/null || { echo "check-delivery: bad dir '$root'" >&2; exit 64; }

# --- resolve the ledger ------------------------------------------------------
ledger=""
if [ -n "${TEAM_BOOTSTRAP_RUN:-}" ] && [ -f ".runs/${TEAM_BOOTSTRAP_RUN}/batches.jsonl" ]; then
  ledger=".runs/${TEAM_BOOTSTRAP_RUN}/batches.jsonl"
else
  ledger="$(ls -t .runs/*/batches.jsonl 2>/dev/null | head -1 || true)"
fi
if [ -z "$ledger" ] || [ ! -f "$ledger" ]; then
  echo "check-delivery: no batch ledger — delivery not machine-checkable, skipping."
  exit 0
fi

# --- field extractors (controlled compact JSONL, no jq dependency) -----------
field_str() { printf '%s' "$1" | grep -oE "\"$2\":\"[^\"]*\"" | head -1 | sed -E "s/\"$2\":\"([^\"]*)\"/\1/"; }
field_num() { printf '%s' "$1" | grep -oE "\"$2\":-?[0-9]+" | head -1 | sed -E "s/\"$2\"://"; }

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
    if [ "$delta" -le 0 ]; then
      echo "  UNEARNED: batch '$id' closed with code_delta=$delta — a code batch that changed no code." >&2
      viol=$((viol + 1))
    fi
  elif [ "$n" -eq "$total" ]; then
    echo "check-delivery: batch '$id' in flight (status=$status) — not yet closed, allowed."
  else
    echo "  UNEARNED: batch '$id' is kind:code status='$status' — announced then abandoned (a later batch exists, this one never closed)." >&2
    viol=$((viol + 1))
  fi
done < "$ledger"

# first-batch-must-be-code: a run that delivers ANY code must open with code, not
# docs. Front-loading the easy-to-write documents while the load-bearing code waits
# is the ordering failure this guards. (A docs-only run — no code batch at all — is
# a different thing and is left alone.)
if [ "$any_code" -eq 1 ] && [ "$first_kind" = "doc" ]; then
  echo "  ORDERING: first batch is kind:doc while the run delivers code later — a delivery run must open with the load-bearing code, not documentation." >&2
  viol=$((viol + 1))
fi

if [ "$viol" -gt 0 ]; then
  echo "check-delivery: $viol unearned closure(s) in $ledger — closure is earned by a pipeline run + code delta, not by assertion." >&2
  exit 1
fi
echo "check-delivery: all kind:code batches earned closure ($ledger)."
exit 0
