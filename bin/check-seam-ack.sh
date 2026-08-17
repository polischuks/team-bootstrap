#!/usr/bin/env bash
# check-seam-ack.sh — closure-fidelity gate C: a named high-risk seam requires a recorded "read it in
# the shipped code" ack before the batch that touches it can close.
#
# The retrospective's CAS bug lived on the highest-risk seam (a CAS reconciliation predicate) and the
# manual verification that would have caught it was skipped. This turns "architecture review named a
# risky seam → someone reads that seam in the shipped diff" from spoken discipline into a recorded,
# commit-anchored step. The architecture-reviewer records its highest-risk seams to the marker
# (high_risk_seams:[{seam,paths}]); a batch whose files intersect a flagged seam's paths must carry a
# matching seam_acks entry naming the seam + a resolvable commit. Missing ack for a touched seam ⇒ fail.
#
# Marker schema contract (orchestrator/human-written; field ORDER is load-bearing for the jq-free parse):
#   high_risk_seams: [ {"seam":"<name>","paths":["<path>",…]}, … ]   (seam THEN paths)
#   seam_acks:       [ {"seam":"<name>","commit":"<sha>","note":"<file:line + why>"}, … ] (seam THEN commit)
# Intersection is coarse by file path (OQ-4): a changed file equal to, or under, a seam path counts —
# over-ask on the highest-risk seam beats under-ask (which is what let the CAS bug through).
#
# The batch's touched files are git-grounded — the diff over the in-flight batch window
# (current_batch_base..HEAD, the SAME window verify-batch stamps) — falling back to the ledger entry's
# declared "files" only when the git window is empty (P11: ground in the mechanism, not the declaration).
#
# Graceful skips (exit 0): no active marker / not intends_code (AC-6); no high_risk_seams recorded
# (nothing to guard); no flagged seam touched by this batch.
#
# Usage: bin/check-seam-ack.sh [project-dir]  ·  bin/check-seam-ack.sh --self-test
# Exit:  0 pass / skip · 1 a touched seam has no valid ack · 64 bad usage
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/delivery-lib.sh
. "$here/delivery-lib.sh"

# _seam_objects MK → one line per high_risk_seams object, "NAME<TAB>path1 path2 …". The seam→paths
# adjacency (a "seam" immediately followed by "paths") uniquely identifies a high_risk_seams object,
# so it never captures a seam_acks object (whose "seam" is followed by "commit").
_seam_objects() {
  local mk="$1" m name paths
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    name="$(printf '%s' "$m" | sed -E 's/.*"seam":[[:space:]]*"([^"]*)".*/\1/')"
    paths="$(printf '%s' "$m" | grep -oE '"paths":[[:space:]]*\[[^]]*\]' | head -1 | grep -oE '"[^"]*"' | tr -d '"' | tr '\n' ' ')"
    [ -n "$name" ] && printf '%s\t%s\n' "$name" "$paths"
  done < <(printf '%s' "$mk" | grep -oE '"seam":[[:space:]]*"[^"]*"[[:space:]]*,[[:space:]]*"paths":[[:space:]]*\[[^]]*\]')
}

# _ack_commit MK SEAM → the commit recorded in the seam_acks entry for SEAM (empty if none). Matches a
# "seam":"SEAM" immediately followed by "commit" — a seam_acks object, never a high_risk_seams one.
_ack_commit() {
  local mk="$1" seam="$2"
  printf '%s' "$mk" | grep -oE "\"seam\":[[:space:]]*\"$seam\"[[:space:]]*,[[:space:]]*\"commit\":[[:space:]]*\"[^\"]*\"" \
    | head -1 | grep -oE '"commit":[[:space:]]*"[^"]*"' | sed -E 's/.*"([^"]*)"$/\1/'
}

# _batch_files → the in-flight batch's changed files (git window), else the ledger entry's declared files.
_batch_files() {
  local base changed ledger line
  base="$(current_batch_base)"
  if [ -n "$base" ]; then
    changed="$(git diff --name-only "$base" HEAD 2>/dev/null)"
    [ -n "$changed" ] && { printf '%s\n' "$changed"; return 0; }
  fi
  ledger="$(resolve_ledger)"
  [ -n "$ledger" ] && [ -f "$ledger" ] || return 0
  line="$(grep '"status":[[:space:]]*"announced"' "$ledger" 2>/dev/null | tail -1)"
  [ -n "$line" ] || line="$(grep -v '^[[:space:]]*$' "$ledger" 2>/dev/null | tail -1)"
  printf '%s' "$line" | grep -oE '"files":[[:space:]]*\[[^]]*\]' | head -1 \
    | grep -oE '\[[^]]*\]' | head -1 | grep -oE '"[^"]*"' | tr -d '"'
}

# _intersects FILE PATHS… → rc 0 if FILE equals or is under any seam path (coarse, OQ-4).
_intersects() {
  local f="$1"; shift
  local p
  for p in "$@"; do
    [ -n "$p" ] || continue
    [ "$f" = "$p" ] && return 0
    case "$f" in "$p"/*) return 0 ;; esac
  done
  return 1
}

# _commit_touches_seam FULLSHA PATHS… → rc 0 if the commit changed a file under any seam path.
# The ack must name the commit that ACTUALLY shipped the seam change — not merely a resolvable SHA
# (B5): a resolvable-but-unrelated commit, e.g. the run baseline, proves nothing was read.
_commit_touches_seam() {
  local full="$1"; shift
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    _intersects "$f" "$@" && return 0
  done < <(git show --name-only --format= "$full" 2>/dev/null)
  return 1
}

_evaluate() {
  local marker mk seams files viol=0 name paths_str touched f ackc ackfull bfull
  marker="$(resolve_marker)"
  [ -n "$marker" ] && [ -f "$marker" ] || { echo "check-seam-ack: no active delivery run — skipping (governs armed runs)."; return 0; }
  mk="$(cat "$marker" 2>/dev/null || true)"
  [ "$(field_bool "$mk" intends_code)" = "true" ] || { echo "check-seam-ack: marker not intends_code — skipping."; return 0; }
  bfull="$(resolve_sha "$(field_str "$mk" baseline_sha)")"

  seams="$(_seam_objects "$mk")"
  [ -n "$seams" ] || { echo "check-seam-ack: no high_risk_seams recorded — nothing to guard."; return 0; }

  files="$(_batch_files)"
  [ -n "$files" ] || { echo "check-seam-ack: in-flight batch changed no files — nothing to intersect."; return 0; }

  while IFS="$(printf '\t')" read -r name paths_str; do
    [ -n "$name" ] || continue
    # does any changed file intersect this seam's paths?
    touched=0
    # shellcheck disable=SC2086  # word-split paths_str into positional paths on purpose
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      if _intersects "$f" $paths_str; then touched=1; break; fi
    done <<EOF
$files
EOF
    [ "$touched" -eq 1 ] || continue

    ackc="$(_ack_commit "$mk" "$name")"
    ackfull="$(resolve_sha "$ackc")"
    # shellcheck disable=SC2086  # word-split paths_str into positional seam paths on purpose
    if [ -z "$ackc" ]; then
      echo "  FAIL: batch touches high-risk seam '$name' but no seam_acks entry names it — record a read-in-the-shipped-code ack (seam + commit that changed the seam + file:line note) before closing (AC-5)." >&2
      viol=$((viol + 1))
    elif [ -z "$ackfull" ]; then
      echo "  FAIL: seam_acks entry for '$name' cites commit '$ackc' that git cannot resolve — the ack must be anchored to a real shipped commit (AC-5)." >&2
      viol=$((viol + 1))
    elif ! git merge-base --is-ancestor "$ackfull" HEAD 2>/dev/null; then
      echo "  FAIL: seam '$name' ack commit '$ackc' is not reachable from HEAD — the ack must name a commit shipped in this run (AC-5, B5)." >&2
      viol=$((viol + 1))
    elif [ -n "$bfull" ] && { [ "$ackfull" = "$bfull" ] || ! git merge-base --is-ancestor "$bfull" "$ackfull" 2>/dev/null; }; then
      echo "  FAIL: seam '$name' ack commit '$ackc' is not after the run baseline — the ack must anchor to this run's shipped change, not pre-existing history (AC-5, B5)." >&2
      viol=$((viol + 1))
    elif ! _commit_touches_seam "$ackfull" $paths_str; then
      echo "  FAIL: seam '$name' ack commit '$ackc' did not change the seam's paths — the ack must name the commit that shipped the seam change, not a resolvable-but-unrelated commit like the baseline (AC-5, B5)." >&2
      viol=$((viol + 1))
    else
      echo "check-seam-ack: seam '$name' touched — ack commit $ackc resolves, is reachable from HEAD, post-baseline, and changed the seam."
    fi
  done <<EOF
$seams
EOF

  [ "$viol" -eq 0 ] || return 1
  echo "check-seam-ack: every touched high-risk seam has a valid, commit-anchored ack (or none touched)."
  return 0
}

# --- self-test ---------------------------------------------------------------
if [ "${1:-}" = "--self-test" ]; then
  fail=0; T="$(mktemp -d)"
  ( cd "$T" && git init -q && git config user.email t@t && git config user.name t
    echo base > seed && git add . && git commit -qm base ) >/dev/null 2>&1
  base="$(cd "$T" && git rev-parse --short HEAD)"
  # a batch commit that touches the flagged seam path bin/check-seam-ack.sh
  ( cd "$T" && mkdir -p bin && echo x > bin/check-seam-ack.sh && git add . && git commit -qm "touch seam" ) >/dev/null 2>&1
  code="$(cd "$T" && git rev-parse --short HEAD)"
  mkdir -p "$T/.runs/r"
  _marker() { printf '%s\n' "$1" > "$T/.runs/r/RUN"; }
  # ledger: in-flight batch over baseline..HEAD (current_batch_base uses baseline_sha for first batch)
  printf '{"id":"B1","kind":"code","files":["bin/check-seam-ack.sh"],"status":"announced"}\n' > "$T/.runs/r/batches.jsonl"
  _run() { ( cd "$T" && TEAM_BOOTSTRAP_RUN=r "$here/check-seam-ack.sh" . >/dev/null 2>&1 ); echo $?; }
  _chk() { if [ "$2" = "$3" ]; then echo "  PASS (exit $2) $1"; else echo "  FAIL (exit $2 want $3) $1" >&2; fail=$((fail + 1)); fi; }
  SEAM='"high_risk_seams":[{"seam":"marker-rewrite","paths":["bin/check-seam-ack.sh","bin/delivery-lib.sh"]}]'

  # AC-5 — touched seam, NO ack → fail
  _marker "{\"run\":\"r\",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$base\",$SEAM}"
  _chk "AC-5 touched seam, no seam_acks → fail" "$(_run)" 1
  # AC-5 — touched seam, ack with a RESOLVABLE commit → pass
  _marker "{\"run\":\"r\",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$base\",$SEAM,\"seam_acks\":[{\"seam\":\"marker-rewrite\",\"commit\":\"$code\",\"note\":\"bin/check-seam-ack.sh:1 read the rewrite\"}]}"
  _chk "AC-5 touched seam + ack (resolvable commit) → pass" "$(_run)" 0
  # AC-5 — ack names the seam but its commit does NOT resolve → fail
  _marker "{\"run\":\"r\",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$base\",$SEAM,\"seam_acks\":[{\"seam\":\"marker-rewrite\",\"commit\":\"deadbeef\",\"note\":\"x\"}]}"
  _chk "AC-5 ack commit unresolvable → fail" "$(_run)" 1
  # AC-5 — a seam that the batch does NOT touch → pass (no ack needed)
  _marker "{\"run\":\"r\",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$base\",\"high_risk_seams\":[{\"seam\":\"other\",\"paths\":[\"src/untouched.py\"]}]}"
  _chk "AC-5 no flagged seam touched → pass" "$(_run)" 0
  # no high_risk_seams at all → pass
  _marker "{\"run\":\"r\",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$base\"}"
  _chk "no high_risk_seams recorded → pass" "$(_run)" 0
  # B5 — the ack must anchor to the commit that SHIPPED the seam change, not a resolvable-but-unrelated one.
  # ack = the run baseline (resolvable + reachable, but pre-baseline and touched no seam) → fail.
  _marker "{\"run\":\"r\",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$base\",$SEAM,\"seam_acks\":[{\"seam\":\"marker-rewrite\",\"commit\":\"$base\",\"note\":\"x\"}]}"
  _chk "B5 ack = baseline (resolvable but pre-baseline, no seam change) → fail" "$(_run)" 1
  # a post-baseline commit that changed a NON-seam file → reachable + post-baseline but didn't touch the seam → fail
  ( cd "$T" && echo o > other.txt && git add other.txt && git commit -qm "non-seam work" ) >/dev/null 2>&1
  code2="$(cd "$T" && git rev-parse --short HEAD)"
  _marker "{\"run\":\"r\",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$base\",$SEAM,\"seam_acks\":[{\"seam\":\"marker-rewrite\",\"commit\":\"$code2\",\"note\":\"x\"}]}"
  _chk "B5 ack = post-baseline commit that didn't touch the seam → fail" "$(_run)" 1
  # ack = the seam-touching commit still passes with HEAD advanced past it
  _marker "{\"run\":\"r\",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$base\",$SEAM,\"seam_acks\":[{\"seam\":\"marker-rewrite\",\"commit\":\"$code\",\"note\":\"x\"}]}"
  _chk "B5 ack = the seam-touching commit → pass" "$(_run)" 0
  # AC-6 — no active marker → skip
  rm -f "$T/.runs/r/RUN"
  _chk "AC-6 no active marker → skip (exit 0)" "$(_run)" 0
  rm -rf "$T"
  if [ "$fail" -eq 0 ]; then echo "check-seam-ack --self-test: OK"; exit 0; fi
  echo "check-seam-ack --self-test: $fail case(s) FAILED" >&2; exit 1
fi

root="${1:-.}"
cd "$root" 2>/dev/null || { echo "check-seam-ack: bad dir '$root'" >&2; exit 64; }
if _evaluate; then exit 0; else exit 1; fi
