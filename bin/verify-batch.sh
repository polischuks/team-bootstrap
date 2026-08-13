#!/usr/bin/env bash
# verify-batch.sh — the harness-enforced batch gate.
#
# The reviewer roles (integration-verifier, code-reviewer, architecture-reviewer,
# regression-guardian) are prose the orchestrator can skip (~70% adherence). This
# script enforces the OUTCOMES those roles exist to guarantee, regardless of which
# roles actually ran — so a /deliver batch cannot pass by skipping review:
#   - quality-gate    : typecheck + lint (from AGENTS.md)
#   - check-orphans   : dead code / created-but-not-wired
#   - check-architecture : drift from the baseline
#   - check-gate-integrity : no green-by-skip / disabled gate
#   - check-delivery  : no unearned closure (a prior code batch announced but never closed)
#
# On success it STAMPS the in-flight batch closed in the run ledger
# (.runs/<run>/batches.jsonl): status->closed + commit_shas + code_delta. Only this
# script — not the orchestrator's prose — can flip a batch to closed. That is what
# makes "batch closed" a machine fact, not a claim (see check-delivery.sh).
#
# Run it at batch completion AND in CI (the independent backstop that catches a
# batch whose local run skipped the roles). See references/enforcement.md.
#
# Usage: bin/verify-batch.sh [project-dir]   # default: current dir
# Exit:  0 all gates pass · 1 a gate failed · 64 bad usage
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="${1:-.}"
cd "$root" 2>/dev/null || { echo "verify-batch: bad dir '$root'" >&2; exit 64; }
# shellcheck source=bin/delivery-lib.sh
. "$here/delivery-lib.sh"

fails=0
gate() {
  local name="$1"; shift
  echo "verify-batch: → $name" >&2
  if "$@"; then
    echo "verify-batch:   OK — $name" >&2
  else
    echo "verify-batch:   FAILED — $name" >&2
    fails=$((fails + 1))
  fi
}

# stamp_batch_closed — machine-only closure. On a passing batch, flip the in-flight
# (last still-announced) ledger entry to status:closed and record the commit_shas and
# code_delta that earned it. No ledger / nothing in flight -> no-op. This is the half
# the orchestrator cannot do in prose: closure becomes a recorded fact.
stamp_batch_closed() {
  local ledger; ledger="$(resolve_ledger)"
  [ -n "$ledger" ] && [ -f "$ledger" ] || return 0

  local target
  target="$(grep -n '"status":"announced"' "$ledger" 2>/dev/null | tail -1 | sed -E 's/^[0-9]+://')"
  [ -n "$target" ] || return 0   # nothing in flight to close

  # per-batch commit range: since the PREVIOUS closed batch's newest commit (so each
  # batch's code_delta counts only its own work, not the cumulative run). Falls back
  # to base..HEAD for the first batch, else the last commit.
  local since range base b
  since="$(grep '"status":"closed"' "$ledger" 2>/dev/null | tail -1 \
    | sed -nE 's/.*"commit_shas":\["([0-9a-f]+)".*/\1/p')"
  if [ -n "$since" ] && git rev-parse --verify -q "$since" >/dev/null 2>&1; then
    range="$since..HEAD"
  else
    base=""
    for b in origin/main main origin/master master; do
      if git rev-parse --verify -q "$b" >/dev/null 2>&1; then base="$b"; break; fi
    done
    if [ -n "$base" ] && [ "$(git rev-parse -q "$base" 2>/dev/null)" != "$(git rev-parse -q HEAD 2>/dev/null)" ]; then
      range="$base..HEAD"
    else
      range="HEAD~1..HEAD"
    fi
  fi

  # the batch's commits, space-separated (for the shared delta fn) and comma-joined
  # (for the ledger JSON). One list, two renderings.
  local shas_list shas
  shas_list="$(git log --format=%h "$range" 2>/dev/null | head -50 | tr '\n' ' ' || true)"
  shas="$(printf '%s' "$shas_list" | sed 's/[[:space:]]*$//;s/  */,/g')"

  # code_delta from the SAME shared function check-delivery.sh recomputes with
  # (delivery-lib.sh nondoc_delta_of_shas) — per-commit non-doc sum over exactly the
  # stamped SHAs. Sharing this makes stamp == recompute by construction (spec R1),
  # so a batch this script closes always survives the check-delivery recompute.
  local delta
  delta="$(nondoc_delta_of_shas "$shas_list")"; case "$delta" in ''|*[!0-9]*) delta=0 ;; esac

  local shas_json="[]"
  [ -n "$shas" ] && shas_json="[\"$(printf '%s' "$shas" | sed 's/,/","/g')\"]"
  local gates="quality-gate=ok;orphans=ok;architecture=ok;gate-integrity=ok;delivery=ok"

  local newline
  newline="$(printf '%s' "$target" \
    | sed 's/"status":"announced"/"status":"closed"/' \
    | sed 's/}[[:space:]]*$/,"commit_shas":'"$shas_json"',"code_delta":'"$delta"',"gate_results":"'"$gates"'"}/')"

  local tmp; tmp="$(mktemp)"
  while IFS= read -r l; do
    if [ "$l" = "$target" ]; then printf '%s\n' "$newline"; else printf '%s\n' "$l"; fi
  done < "$ledger" > "$tmp" && mv "$tmp" "$ledger"
  echo "verify-batch: stamped closed in $ledger — code_delta=$delta shas=${shas:-none}" >&2
}

gate "quality-gate (typecheck + lint)"      "$here/quality-gate.sh" .
gate "orphans (dead code / not wired)"       "$here/check-orphans.sh"
gate "architecture (drift vs baseline)"      "$here/check-architecture.sh" .
gate "gate-integrity (no skip / disabled)"   "$here/check-gate-integrity.sh" .
gate "tdd (red→green observed, P9)"          "$here/check-tdd.sh" .
gate "delivery (no unearned closure)"        "$here/check-delivery.sh" .

if [ "$fails" -gt 0 ]; then
  echo "verify-batch: $fails gate(s) failed — batch cannot pass. Fix and re-run." >&2
  exit 1
fi
stamp_batch_closed
echo "verify-batch: all gates passed."
exit 0
