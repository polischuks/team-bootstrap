#!/usr/bin/env bash
# check-enforcement.sh — closure-fidelity gate A: make a SILENTLY-SKIPPED quality gate LOUD + BLOCKING,
# and (v2.20.0, milestone closed-loop-fidelity, batch A2) GOVERN the acknowledgement so it can no longer
# deprecate into a perpetual free pass.
#
# The retrospective's CAS bug passed because P9 red-first (check-tdd), F2 diff-coverage, and F3 mutation
# ALL skipped for lack of project tooling — the bug slipped through *disarmed* gates, not absent ones.
# This gate detects, on an armed code-delivery run, which of those three dimensions is UNENFORCEABLE,
# records the gaps in the RUN marker, and BLOCKS a code batch from closing until the human acknowledges.
#
# Gap detection mirrors the exact signal each peer gate skips on (AGENTS.md/CLAUDE.md, backtick contract):
#   - no `Test:` command                         → gap "red-first"     (check-tdd skips)
#   - no `Coverage:` command                     → gap "diff-coverage" (check-diff-coverage skips)
#   - no `Mutation:` command, or MutationMode≠enforce → gap "mutation" (check-mutation only advisory)
#
# GOVERNED WAIVER (A2). A bare `enforcement_ack:true` no longer suffices. A valid waiver carries:
#   enforcement_ack:true, enforcement_ack_by, enforcement_ack_reason, enforcement_ack_expires (YYYY-MM-DD),
#   enforcement_ack_category ∈ {host_structural, deferred}. A waiver past `expires` (vs a passed-in
#   `TEAM_BOOTSTRAP_NOW`, default system date), or missing any field, is treated as NO ack. This stops the
#   ack becoming a standing default — it must be dated and re-acknowledged (ADR-0007).
#
# CATEGORY IS DERIVED, NOT TRUSTED. `host_structural` (the tool provably cannot exist on host) is only
# legitimate when NO gap dimension has a declared+resolvable tool. If a gap dimension's command IS
# declared in AGENTS.md and resolves on PATH, that gap is `deferred` by construction (arm it, don't waive
# it) and a `host_structural` label is rejected → forced to `deferred`. This keeps the exemption airtight
# on target projects (re-review #1).
#
# HARD-REQUIRE TIERS (risk-tied strictness). An *ackable* gap — unwaived, or waived only `deferred` — is
# hard-failed on the highest-cost paths:
#   - a batch touching a recorded `high_risk_seams` path (seam-tier), and
#   - a `run-rate|irreversible` batch (OQ-1 tier).
# A gap under a VALID `host_structural` waiver is EXEMPT from *every* tier (the tool cannot exist — a
# run-rate fix to team-bootstrap's own gate machinery must not self-block; re-review #2). A `feature|doc`
# batch off the seams passes on any valid governed waiver.
#
# Graceful skips (exit 0): no active marker, or marker not intends_code — never a false block (AC-6).
#
# Usage: bin/check-enforcement.sh [project-dir]  ·  bin/check-enforcement.sh --self-test
# Exit:  0 no gaps / valid waiver (per tier) / skip · 1 unwaived-or-tier-blocked gap · 64 bad usage
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/delivery-lib.sh
. "$here/delivery-lib.sh"

_doc() { local f; for f in AGENTS.md CLAUDE.md; do [ -f "$f" ] && { printf '%s' "$f"; return 0; }; done; }
# _cmd LABEL DOC → first backticked command on a `Label:` line (empty if none/N-A)
_cmd() {
  local c; c="$(grep -iE "^[[:space:]]*[-*]?[[:space:]]*$1:" "$2" 2>/dev/null | head -1 | grep -oE '`[^`]+`' | head -1 | tr -d '`')"
  case "$c" in N/A|n/a|None|none) c="" ;; esac
  printf '%s' "$c"
}
# _val LABEL DOC → bare value after `Label:` (backticks stripped, trimmed, lowercased)
_val() { grep -iE "^[[:space:]]*[-*]?[[:space:]]*$1:" "$2" 2>/dev/null | head -1 | sed -E 's/^[^:]*://' | tr -d '`' | tr '[:upper:]' '[:lower:]' | xargs 2>/dev/null || true; }

# _tool_resolves DOC LABEL → 0 if AGENTS.md declares LABEL: with a first token that resolves (PATH or -x).
_tool_resolves() {
  local cmd tok
  cmd="$(_cmd "$2" "$1")"
  [ -n "$cmd" ] || return 1
  tok="${cmd%% *}"
  command -v "$tok" >/dev/null 2>&1 && return 0
  [ -x "$tok" ] && return 0
  return 1
}
# _any_deferrable DOC GAPS → 0 if any gap dimension has a declared+resolvable tool (⇒ not host_structural).
_any_deferrable() {
  local doc="$1" gaps="$2"
  case " $gaps " in *" diff-coverage "*) _tool_resolves "$doc" Coverage && return 0 ;; esac
  case " $gaps " in *" mutation "*)      _tool_resolves "$doc" Mutation && return 0 ;; esac
  case " $gaps " in *" red-first "*)     _tool_resolves "$doc" Test && return 0 ;; esac
  return 1
}

# _inflight_risk_rank → risk_rank of the batch being closed now (last announced ledger entry; else last).
_inflight_risk_rank() {
  local ledger line
  ledger="$(resolve_ledger)"
  [ -n "$ledger" ] && [ -f "$ledger" ] || return 0
  line="$(grep '"status":[[:space:]]*"announced"' "$ledger" 2>/dev/null | tail -1)"
  [ -n "$line" ] || line="$(grep -v '^[[:space:]]*$' "$ledger" 2>/dev/null | tail -1)"
  [ -n "$line" ] || return 0
  field_str "$line" risk_rank
}

# _seam_paths MK → all high_risk_seams paths, one per line (coarse, OQ-4).
_seam_paths() { printf '%s' "$1" | grep -oE '"paths":[[:space:]]*\[[^]]*\]' | grep -oE '"[^"]*"' | tr -d '"'; }
# _batch_files_e → in-flight batch changed files: git window (current_batch_base..HEAD), else ledger "files".
_batch_files_e() {
  local base changed ledger line
  base="$(current_batch_base 2>/dev/null || true)"
  if [ -n "$base" ]; then
    changed="$(git diff --name-only "$base" HEAD 2>/dev/null)"
    [ -n "$changed" ] && { printf '%s\n' "$changed"; return 0; }
  fi
  ledger="$(resolve_ledger)"
  [ -n "$ledger" ] && [ -f "$ledger" ] || return 0
  line="$(grep '"status":[[:space:]]*"announced"' "$ledger" 2>/dev/null | tail -1)"
  [ -n "$line" ] || line="$(grep -v '^[[:space:]]*$' "$ledger" 2>/dev/null | tail -1)"
  printf '%s' "$line" | grep -oE '"files":[[:space:]]*\[[^]]*\]' | head -1 | grep -oE '"[^"]*"' | tr -d '"'
}
# _batch_touches_seam MK → 0 if any in-flight batch file equals or is under any recorded seam path.
_batch_touches_seam() {
  local mk="$1" paths files p f
  paths="$(_seam_paths "$mk")"; [ -n "$paths" ] || return 1
  files="$(_batch_files_e)"; [ -n "$files" ] || return 1
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      [ "$f" = "$p" ] && return 0
      case "$f" in "$p"/*) return 0 ;; esac
    done <<EOF
$paths
EOF
  done <<EOF
$files
EOF
  return 1
}

_evaluate() {
  local marker mk doc test cov mut mmode rank
  marker="$(resolve_marker)"
  [ -n "$marker" ] && [ -f "$marker" ] || { echo "check-enforcement: no active delivery run — skipping (governs armed runs)."; return 0; }
  mk="$(cat "$marker" 2>/dev/null || true)"
  [ "$(field_bool "$mk" intends_code)" = "true" ] || { echo "check-enforcement: marker not intends_code — skipping."; return 0; }

  doc="$(_doc)"
  test=""; cov=""; mut=""; mmode=""
  if [ -n "$doc" ]; then
    test="$(_cmd Test "$doc")"; cov="$(_cmd Coverage "$doc")"; mut="$(_cmd Mutation "$doc")"; mmode="$(_val MutationMode "$doc")"
  fi

  # detect the unenforceable dimensions — one gap string per disarmed peer gate.
  local gaps=""
  [ -n "$test" ] || gaps="$gaps red-first"
  [ -n "$cov" ]  || gaps="$gaps diff-coverage"
  { [ -z "$mut" ] || [ "$mmode" != "enforce" ]; } && gaps="$gaps mutation"
  gaps="$(printf '%s' "$gaps" | xargs 2>/dev/null || true)"

  # record enforcement_gaps to the marker (JSON array), so the gap set is a machine-readable fact.
  local arr="[]" g
  if [ -n "$gaps" ]; then
    arr="["; local first=1
    for g in $gaps; do [ "$first" -eq 1 ] && first=0 || arr="$arr,"; arr="$arr\"$g\""; done
    arr="$arr]"
  fi
  record_marker_list enforcement_gaps "$arr" || echo "check-enforcement: WARN — could not record enforcement_gaps to marker." >&2

  if [ -z "$gaps" ]; then
    echo "check-enforcement: all three quality dimensions enforceable (Test:/Coverage:/Mutation: enforce present) — no gaps, OK."
    return 0
  fi

  rank="$(_inflight_risk_rank)"

  # --- governed waiver validity (T5): fields present + category valid + unexpired ---
  local ack_raw ackby ackreason ackexp ackcat now ack_valid="false"
  ack_raw="$(field_bool "$mk" enforcement_ack)"
  ackby="$(field_str "$mk" enforcement_ack_by)"
  ackreason="$(field_str "$mk" enforcement_ack_reason)"
  ackexp="$(field_str "$mk" enforcement_ack_expires)"
  ackcat="$(field_str "$mk" enforcement_ack_category)"
  now="${TEAM_BOOTSTRAP_NOW:-$(date +%Y-%m-%d)}"
  if [ "$ack_raw" = "true" ] && [ -n "$ackby" ] && [ -n "$ackreason" ] && [ -n "$ackexp" ] \
     && { [ "$ackcat" = "host_structural" ] || [ "$ackcat" = "deferred" ]; }; then
    case "$ackexp" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9])
        if [[ "$ackexp" < "$now" ]]; then
          echo "check-enforcement: enforcement waiver EXPIRED ($ackexp < $now) — re-acknowledge with a future expiry (ADR-0007)." >&2
        else
          ack_valid="true"
        fi ;;
      *) echo "check-enforcement: enforcement_ack_expires '$ackexp' is not YYYY-MM-DD — invalid waiver." >&2 ;;
    esac
  elif [ "$ack_raw" = "true" ]; then
    echo "check-enforcement: enforcement_ack:true but missing by/reason/expires/category — an incomplete waiver is not an ack (A2 governed waiver)." >&2
  fi

  # --- effective category (T6 derive/corroborate): a declared+resolvable tool forces 'deferred' ---
  local eff_cat="$ackcat"
  if _any_deferrable "$doc" "$gaps"; then
    eff_cat="deferred"
    [ "$ackcat" = "host_structural" ] && echo "check-enforcement: category 'host_structural' rejected — a declared+resolvable tool exists for a gap dimension; treated as 'deferred' (arm it, don't waive it)." >&2
  fi

  # --- seam touch (T6) ---
  local seam_touched="no"
  _batch_touches_seam "$mk" && seam_touched="yes"

  # --- decision -------------------------------------------------------------------------
  # (a) valid waiver + host_structural → exempt from EVERY tier (tool provably cannot exist on host).
  if [ "$ack_valid" = "true" ] && [ "$eff_cat" = "host_structural" ]; then
    echo "check-enforcement: gaps [$gaps] under a valid host_structural waiver (expires $ackexp) — tool cannot exist on host; exempt from all tiers (rank=${rank:-unset}, seam_touch=$seam_touched). OK."
    return 0
  fi

  # (b) hard-require tiers — an ackable (deferred/unwaived) gap on the highest-cost paths hard-fails.
  if [ "$seam_touched" = "yes" ]; then
    echo "  FAIL-CLOSED: batch touches a high_risk_seam with an ackable enforcement gap [$gaps] (category=$eff_cat) — the highest-cost paths cannot ship under a waiver; arm the tooling. (A valid host_structural gap would be exempt; a declared/resolvable tool is not.)" >&2
    return 1
  fi
  if [ "$rank" = "run-rate" ] || [ "$rank" = "irreversible" ]; then
    echo "  FAIL-CLOSED: batch risk_rank=$rank with an ackable enforcement gap [$gaps] (category=$eff_cat) — a bleeding-stopper batch must run against real tooling (OQ-1). Only a host_structural gap (tool cannot exist) is exempt." >&2
    return 1
  fi

  # (c) feature|doc off the seams — a valid governed waiver passes; anything else fails.
  if [ "$ack_valid" = "true" ]; then
    echo "check-enforcement: gaps [$gaps] under a valid $eff_cat waiver (by=$ackby, expires=$ackexp, rank=${rank:-unset}) — logged, dated decision. OK."
    return 0
  fi

  echo "  FAIL-CLOSED: test-quality enforcement gaps [$gaps] with no valid governed waiver — record enforcement_ack:true + enforcement_ack_by/reason/expires(YYYY-MM-DD)/category(host_structural|deferred), unexpired, in the run marker, or declare the tooling in AGENTS.md." >&2
  return 1
}

# --- self-test ---------------------------------------------------------------
if [ "${1:-}" = "--self-test" ]; then
  fail=0; T="$(mktemp -d)"; mkdir -p "$T/.runs/r"
  _marker() { printf '%s\n' "$1" > "$T/.runs/r/RUN"; }
  _agents() { printf '%s\n' "$1" > "$T/AGENTS.md"; }
  _batch()  { printf '%s\n' "$1" > "$T/.runs/r/batches.jsonl"; }
  _run() { ( cd "$T" && TEAM_BOOTSTRAP_RUN=r TEAM_BOOTSTRAP_NOW=2026-08-18 "$here/check-enforcement.sh" . >/dev/null 2>&1 ); echo $?; }
  _chk() { if [ "$2" = "$3" ]; then echo "  PASS (exit $2) $1"; else echo "  FAIL (exit $2 want $3) $1" >&2; fail=$((fail + 1)); fi; }
  ALL='# AGENTS

- Test: `true`
- Coverage: `true`
- Mutation: `true`
- MutationMode: enforce
'
  NONE='# AGENTS

- Lint: `true`
'
  # governed waivers (valid = all fields + unexpired). host_structural vs deferred.
  W_HS_OK='"enforcement_ack":true,"enforcement_ack_by":"x","enforcement_ack_reason":"r","enforcement_ack_expires":"2999-01-01","enforcement_ack_category":"host_structural"'
  W_DEF_OK='"enforcement_ack":true,"enforcement_ack_by":"x","enforcement_ack_reason":"r","enforcement_ack_expires":"2999-01-01","enforcement_ack_category":"deferred"'
  W_EXPIRED='"enforcement_ack":true,"enforcement_ack_by":"x","enforcement_ack_reason":"r","enforcement_ack_expires":"2000-01-01","enforcement_ack_category":"host_structural"'
  W_NOCAT='"enforcement_ack":true,"enforcement_ack_by":"x","enforcement_ack_reason":"r","enforcement_ack_expires":"2999-01-01"'

  # AC-1 — armed run, no tooling, feature, no ack → gaps recorded + fail
  _marker '{"run":"r","intends_code":true,"source":"harness","baseline_sha":"x"}'
  _agents "$NONE"; _batch '{"id":"B1","kind":"code","risk_rank":"feature","status":"announced"}'
  _chk "AC-1 gaps + no ack (feature) → fail" "$(_run)" 1
  got="$(cat "$T/.runs/r/RUN")"
  case "$got" in *'"enforcement_gaps":['*'red-first'*'diff-coverage'*'mutation'*']'*) echo "  PASS enforcement_gaps recorded [red-first,diff-coverage,mutation]" ;;
    *) echo "  FAIL enforcement_gaps not recorded: $got" >&2; fail=$((fail + 1)) ;; esac
  case "$got" in *'"baseline_sha":"x"'*) echo "  PASS marker round-trip: baseline_sha survived" ;;
    *) echo "  FAIL marker round-trip clobbered baseline_sha: $got" >&2; fail=$((fail + 1)) ;; esac
  # AC-2 — gaps + VALID host_structural governed waiver (feature) → pass
  _marker '{"run":"r","intends_code":true,"source":"harness","baseline_sha":"x",'"$W_HS_OK"'}'
  _chk "AC-2 gaps + valid host_structural waiver (feature) → pass" "$(_run)" 0
  # AC-2 — EXPIRED waiver (feature) → fail
  _marker '{"run":"r","intends_code":true,"source":"harness",'"$W_EXPIRED"'}'
  _chk "AC-2 expired waiver (feature) → fail" "$(_run)" 1
  # AC-2 — missing category (feature) → fail
  _marker '{"run":"r","intends_code":true,"source":"harness",'"$W_NOCAT"'}'
  _chk "AC-2 waiver missing category (feature) → fail" "$(_run)" 1
  # AC-2 — bare enforcement_ack:true (legacy, no fields) → fail (no longer sufficient)
  _marker '{"run":"r","intends_code":true,"source":"harness","enforcement_ack":true}'
  _chk "AC-2 bare enforcement_ack:true (no fields) → fail" "$(_run)" 1
  # AC-2 — all tooling present (Mutation enforce) → no gap → pass
  _marker '{"run":"r","intends_code":true,"source":"harness","baseline_sha":"x"}'
  _agents "$ALL"
  _chk "AC-2 Test:+Coverage:+Mutation:enforce → no gap → pass" "$(_run)" 0
  got="$(cat "$T/.runs/r/RUN")"
  case "$got" in *'"enforcement_gaps":[]'*) echo "  PASS enforcement_gaps emptied when no gaps" ;;
    *) echo "  FAIL enforcement_gaps not emptied: $got" >&2; fail=$((fail + 1)) ;; esac

  # AC-3 — seam-touch + valid host_structural waiver (no tooling) → EXEMPT → pass (even run-rate)
  _agents "$NONE"
  _marker '{"run":"r","intends_code":true,"source":"harness","high_risk_seams":[{"seam":"s","paths":["bin/x.sh"]}],'"$W_HS_OK"'}'
  _batch '{"id":"B1","kind":"code","risk_rank":"run-rate","files":["bin/x.sh"],"status":"announced"}'
  _chk "AC-3 seam-touch + host_structural + run-rate → exempt → pass" "$(_run)" 0
  # AC-3 — seam-touch + DEFERRABLE gap (Mutation declared+resolvable, advisory) → hard-fail even w/ waiver
  _agents '# AGENTS

- Test: `true`
- Coverage: `true`
- Mutation: `true`
- MutationMode: advisory
'
  _marker '{"run":"r","intends_code":true,"source":"harness","high_risk_seams":[{"seam":"s","paths":["bin/x.sh"]}],'"$W_HS_OK"'}'
  _batch '{"id":"B1","kind":"code","risk_rank":"feature","files":["bin/x.sh"],"status":"announced"}'
  _chk "AC-3 seam-touch + deferrable gap (host_structural label rejected) → fail" "$(_run)" 1
  # re-review #2 — run-rate + DEFERRABLE gap → fail (not exempt)
  _marker '{"run":"r","intends_code":true,"source":"harness",'"$W_HS_OK"'}'
  _batch '{"id":"B1","kind":"code","risk_rank":"run-rate","status":"announced"}'
  _chk "OQ-1 run-rate + deferrable gap → fail" "$(_run)" 1
  # mutation-only gap, feature, valid deferred waiver (Mutation resolvable) → pass
  _marker '{"run":"r","intends_code":true,"source":"harness",'"$W_DEF_OK"'}'
  _batch '{"id":"B1","kind":"code","risk_rank":"feature","status":"announced"}'
  _chk "mutation-only deferrable gap + feature + deferred waiver → pass" "$(_run)" 0

  # R6 (marker-rewrite seam) — record_marker_list must REPLACE enforcement_gaps after a NESTED key
  # without leaking a backslash or clobbering the nested value (bash-5.2 ${//} bug, locked).
  _agents "$NONE"; _batch '{"id":"B1","kind":"code","risk_rank":"feature","status":"announced"}'
  _marker '{"run":"r","intends_code":true,"source":"harness","baseline_sha":"x","high_risk_seams":[{"seam":"marker-rewrite","paths":["bin/a.sh","bin/b.sh"]}],"enforcement_gaps":["stale"]}'
  ( cd "$T" && TEAM_BOOTSTRAP_RUN=r "$here/check-enforcement.sh" . >/dev/null 2>&1 ) || true
  got="$(cat "$T/.runs/r/RUN")"
  if printf '%s' "$got" | grep -q '\\'; then
    echo "  FAIL R6 marker rewrite leaked a backslash: $got" >&2; fail=$((fail + 1))
  elif printf '%s' "$got" | grep -q '"high_risk_seams":\[{"seam":"marker-rewrite","paths":\["bin/a.sh","bin/b.sh"\]}\]' \
    && printf '%s' "$got" | grep -q '"enforcement_gaps":\["red-first","diff-coverage","mutation"\]'; then
    echo "  PASS R6 marker rewrite replaced enforcement_gaps, nested high_risk_seams intact, no backslash"
  else
    echo "  FAIL R6 marker rewrite result malformed: $got" >&2; fail=$((fail + 1))
  fi

  # AC-6 — no active marker → skip
  rm -f "$T/.runs/r/RUN"
  _chk "AC-6 no active marker → skip (exit 0)" "$(_run)" 0
  rm -rf "$T"
  if [ "$fail" -eq 0 ]; then echo "check-enforcement --self-test: OK"; exit 0; fi
  echo "check-enforcement --self-test: $fail case(s) FAILED" >&2; exit 1
fi

root="${1:-.}"
cd "$root" 2>/dev/null || { echo "check-enforcement: bad dir '$root'" >&2; exit 64; }
if _evaluate; then exit 0; else exit 1; fi
