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

# _batch_files → the in-flight batch's git-changed files on stdout, with a fail-closed return code.
# A tamper-relevant seam must NOT fall back to the ledger's self-declared "files" (a tamperer controls
# them). So this is git-grounded ONLY, distinguishing (OQ-2 / AC-Empty):
#   rc 0 — resolvable base, non-empty diff  → the changed files on stdout
#   rc 3 — resolvable base, ZERO diff       → fail-closed (empty window; no declared-"files" fallback)
#   rc 4 — unresolvable base                → diagnosed fail (cannot ground the diff in git)
_batch_files() {
  local base changed
  base="$(current_batch_base)"
  [ -n "$base" ] || return 4
  git rev-parse --verify -q "$base^{commit}" >/dev/null 2>&1 || return 4
  changed="$(git diff --name-only "$base" HEAD 2>/dev/null)"
  [ -n "$changed" ] || return 3
  printf '%s\n' "$changed"
  return 0
}

# _intersects FILE PATHS_NL → rc 0 if FILE equals, is under (directory-prefix), OR glob-matches any
# path token in PATHS_NL (newline-delimited). OQ-5: the shipped equals/under-dir matcher was glob-BLIND
# (its `"$p"` was quoted → `*` literal), silently under-matching bin/check-*.sh / hooks/*.json. The added
# `case "$f" in $token)` branch (UNQUOTED $p → glob) fixes both detection and ack-validation at once,
# since both go through here (BF2 — they can never disagree). Tokens are iterated line-by-line via
# `while read` (NEVER `for t in $paths` — unquoted command-subst would pathname-EXPAND the globs against
# the CWD before matching, NB2); `case` pattern-matching does not touch the filesystem, so globs stay
# patterns. NOTE: `case`-glob `*` SPANS `/`, so hooks/*.json also matches hooks/nested/x.json — an
# intended, fail-closed over-match (spec OQ-5).
_intersects() {
  local f="$1" p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ "$f" = "$p" ] && return 0
    case "$f" in
      "$p"/*) return 0 ;;
      $p)     return 0 ;;
    esac
  done <<EOF
$2
EOF
  return 1
}

# _commit_touches_seam FULLSHA PATHS_NL → rc 0 if the commit changed a file matching any seam path
# (newline-delimited, same glob-aware _intersects). The ack must name the commit that ACTUALLY shipped
# the seam change — not merely a resolvable SHA (B5): a resolvable-but-unrelated commit, e.g. the run
# baseline, proves nothing was read.
_commit_touches_seam() {
  local full="$1" paths_nl="$2" f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    _intersects "$f" "$paths_nl" && return 0
  done < <(git show --name-only --format= "$full" 2>/dev/null)
  return 1
}

_evaluate() {
  local marker mk seams cs_globs files bf_rc viol=0 name paths_str paths_nl touched f ackc ackfull bfull
  marker="$(resolve_marker)"
  [ -n "$marker" ] && [ -f "$marker" ] || { echo "check-seam-ack: no active delivery run — skipping (governs armed runs)."; return 0; }
  mk="$(cat "$marker" 2>/dev/null || true)"
  [ "$(field_bool "$mk" intends_code)" = "true" ] || { echo "check-seam-ack: marker not intends_code — skipping."; return 0; }
  bfull="$(resolve_sha "$(field_str "$mk" baseline_sha)")"

  seams="$(_seam_objects "$mk")"
  # Standing control-surface seam (control-surface-protection): the control_surface_globs set is an
  # ALWAYS-PRESENT high-risk seam, unioned in BEFORE the "no high_risk_seams" early-return so it fires
  # even when the marker records zero high_risk_seams. Its ack must be named 'control-surface'
  # specifically (AC-Legacy — a different seam-ack does not satisfy it). The globs are space-joined into
  # the same NAME<TAB>paths line shape _seam_objects emits (surface tokens never contain spaces).
  cs_globs="$(control_surface_globs 2>/dev/null | tr '\n' ' ' | sed -E 's/[[:space:]]+$//')"
  if [ -n "$cs_globs" ]; then
    seams="$(printf '%s\n' "$seams" "$(printf 'control-surface\t%s' "$cs_globs")" | grep -vE '^[[:space:]]*$')"
  fi
  [ -n "$seams" ] || { echo "check-seam-ack: no high_risk_seams recorded (and no control surface) — nothing to guard."; return 0; }

  files="$(_batch_files)"; bf_rc=$?
  case "$bf_rc" in
    3) echo "  FAIL: a seam is under guard but the in-flight batch has a resolvable base with a ZERO git diff — a tamper-relevant gate will not fall back to the ledger's self-declared \"files\"; fail-closed (AC-Empty)." >&2; return 1 ;;
    4) echo "  FAIL: cannot resolve the in-flight batch window base — a tamper-relevant gate must ground the diff in git, not trust a declared file list; fail-closed (AC-Empty)." >&2; return 1 ;;
  esac

  while IFS="$(printf '\t')" read -r name paths_str; do
    [ -n "$name" ] || continue
    # newline-delimit the seam's paths WITHOUT pathname-expanding any globs ("$paths_str" is quoted;
    # surface tokens carry no spaces) — the glob-safe input _intersects expects (NB2).
    paths_nl="$(printf '%s' "$paths_str" | tr ' ' '\n')"
    # does any changed file intersect this seam's paths?
    touched=0
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      if _intersects "$f" "$paths_nl"; then touched=1; break; fi
    done <<EOF
$files
EOF
    [ "$touched" -eq 1 ] || continue

    ackc="$(_ack_commit "$mk" "$name")"
    ackfull="$(resolve_sha "$ackc")"
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
    elif ! _commit_touches_seam "$ackfull" "$paths_nl"; then
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
  # AC-Reg: the batch commit + the marker-rewrite seam target a NON-control-surface path (src/app.py),
  # not bin/check-seam-ack.sh — otherwise the STANDING control-surface seam (control-surface-protection)
  # would demand a `control-surface` ack these legacy cases don't carry and they would regress. The
  # standing seam is exercised separately in tests/control-surface-protection.test.sh.
  ( cd "$T" && mkdir -p src && echo x > src/app.py && git add . && git commit -qm "touch seam" ) >/dev/null 2>&1
  code="$(cd "$T" && git rev-parse --short HEAD)"
  mkdir -p "$T/.runs/r"
  _marker() { printf '%s\n' "$1" > "$T/.runs/r/RUN"; }
  # ledger: in-flight batch over baseline..HEAD (current_batch_base uses baseline_sha for first batch)
  printf '{"id":"B1","kind":"code","files":["src/app.py"],"status":"announced"}\n' > "$T/.runs/r/batches.jsonl"
  _run() { ( cd "$T" && TEAM_BOOTSTRAP_RUN=r "$here/check-seam-ack.sh" . >/dev/null 2>&1 ); echo $?; }
  _chk() { if [ "$2" = "$3" ]; then echo "  PASS (exit $2) $1"; else echo "  FAIL (exit $2 want $3) $1" >&2; fail=$((fail + 1)); fi; }
  SEAM='"high_risk_seams":[{"seam":"marker-rewrite","paths":["src/app.py","src/lib.py"]}]'

  # AC-5 — touched seam, NO ack → fail
  _marker "{\"run\":\"r\",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$base\",$SEAM}"
  _chk "AC-5 touched seam, no seam_acks → fail" "$(_run)" 1
  # AC-5 — touched seam, ack with a RESOLVABLE commit → pass
  _marker "{\"run\":\"r\",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$base\",$SEAM,\"seam_acks\":[{\"seam\":\"marker-rewrite\",\"commit\":\"$code\",\"note\":\"src/app.py:1 read the rewrite\"}]}"
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

  # --- standing control-surface seam (control-surface-protection) — glob-aware + fail-closed. -------
  # Fresh fixtures whose batch touches a REAL control_surface_globs path (bin/check-*.sh), so the
  # standing seam (read from references/control-surface.txt, BASH_SOURCE-relative) fires with NO marker
  # high_risk_seams recorded — the union-before-early-return path (r4).
  CS="$(mktemp -d)"
  ( cd "$CS" && git init -q && git config user.email t@t && git config user.name t
    echo s > seed && git add . && git commit -qm base ) >/dev/null 2>&1
  csbase="$(cd "$CS" && git rev-parse --short HEAD)"
  ( cd "$CS" && mkdir -p bin && echo x > bin/check-newgate.sh && git add . && git commit -qm "edit a new gate" ) >/dev/null 2>&1
  cscode="$(cd "$CS" && git rev-parse --short HEAD)"
  mkdir -p "$CS/.runs/r"; printf '{"id":"B1","kind":"code","files":["bin/check-newgate.sh"],"status":"announced"}\n' > "$CS/.runs/r/batches.jsonl"
  _csmk() { printf '%s\n' "$1" > "$CS/.runs/r/RUN"; }
  _csrun() { ( cd "$CS" && TEAM_BOOTSTRAP_RUN=r "$here/check-seam-ack.sh" . >/dev/null 2>&1 ); echo $?; }
  # glob-aware: a NEW bin/check-*.sh edited without a control-surface ack → fail (the hardening — AC-4).
  _csmk "{\"run\":\"r\",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$csbase\"}"
  _chk "standing seam: bin/check-newgate.sh, no control-surface ack → fail (AC-4)" "$(_csrun)" 1
  # a non-control-surface ack does NOT satisfy the standing seam (AC-Legacy).
  _csmk "{\"run\":\"r\",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$csbase\",\"seam_acks\":[{\"seam\":\"marker-rewrite\",\"commit\":\"$cscode\",\"note\":\"x\"}]}"
  _chk "standing seam: only a marker-rewrite ack → fail (AC-Legacy)" "$(_csrun)" 1
  # a valid control-surface ack naming the surface-touching commit → pass (AC-2).
  _csmk "{\"run\":\"r\",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$csbase\",\"seam_acks\":[{\"seam\":\"control-surface\",\"commit\":\"$cscode\",\"note\":\"bin/check-newgate.sh:1\"}]}"
  _chk "standing seam: valid control-surface ack → pass (AC-2)" "$(_csrun)" 0
  # fail-closed empty window: resolvable base + zero diff → fail (AC-Empty).
  ( cd "$CS" && git commit -q --allow-empty -m "empty" ) >/dev/null 2>&1
  _csmk "{\"run\":\"r\",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$cscode\"}"
  _chk "standing seam: resolvable base + zero diff → fail-closed (AC-Empty)" "$(_csrun)" 1
  rm -rf "$CS"
  if [ "$fail" -eq 0 ]; then echo "check-seam-ack --self-test: OK"; exit 0; fi
  echo "check-seam-ack --self-test: $fail case(s) FAILED" >&2; exit 1
fi

root="${1:-.}"
cd "$root" 2>/dev/null || { echo "check-seam-ack: bad dir '$root'" >&2; exit 64; }
if _evaluate; then exit 0; else exit 1; fi
