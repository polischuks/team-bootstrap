#!/usr/bin/env bash
# harness-robustness.test.sh — behavioural spec for the harness-robustness milestone.
# Milestone thesis: a gate must fail on a REAL problem, never on its own infra fragility.
# Each WS ships a PAIRED assertion: the real problem still blocks + the fragility no longer does.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
# Fail count lives in a FILE, not a var: assertions run inside `( … )` subshells (to isolate
# cd / set -f / unset), and a subshell cannot mutate a parent var. A file survives the subshell.
FAILF="$(mktemp)"; printf '0' > "$FAILF"
_chk() { # _chk ACTUAL EXPECTED MSG
  if [ "$1" = "$2" ]; then printf '  PASS %s\n' "$3"
  else printf '  FAIL %s (got [%s] want [%s])\n' "$3" "$1" "$2"
       printf '%s' "$(( $(cat "$FAILF") + 1 ))" > "$FAILF"; fi
}

# ---------------------------------------------------------------------------
# WS-1 — glob-free marker/ledger resolution (P0). resolve_marker/resolve_ledger
# must not depend on shell pathname expansion, so a caller under `set -f` (noglob)
# — as delivery-stop-hook.sh:157 legitimately is around its untrusted closed_ids
# loop — cannot blind them. Root of the most expensive false-block loop.
# ---------------------------------------------------------------------------
ws1() {
  local T; T="$(mktemp -d)"
  ( cd "$T"
    mkdir -p .runs/run-a .runs/run-b
    printf '{"run":"run-a","intends_code":true}\n' > .runs/run-a/RUN
    printf '{"id":"B1","kind":"code","status":"announced"}\n' > .runs/run-a/batches.jsonl
    # run-b is NEWER (touched last) — recency must pick it.
    printf '{"run":"run-b","intends_code":true}\n' > .runs/run-b/RUN
    printf '{"id":"B9","kind":"code","status":"announced"}\n' > .runs/run-b/batches.jsonl
    . "$here/bin/delivery-lib.sh"

    # AC-1d/AC-1a — under set -f, env UNSET, resolve_marker must still resolve (NOT empty).
    unset TEAM_BOOTSTRAP_RUN
    set -f
    local m; m="$(resolve_marker)"
    set +f
    _chk "$([ -n "$m" ] && echo nonempty || echo empty)" "nonempty" \
      "AC-1a/1d resolve_marker non-empty under set -f, env unset"

    # AC-1e — recency: must return the NEWEST run's marker (run-b), not directory order.
    set -f; m="$(resolve_marker)"; set +f
    _chk "$(basename "$(dirname "$m")")" "run-b" \
      "AC-1e resolve_marker picks newest-by-mtime under set -f (not dir order)"

    # resolve_ledger parallel property under set -f.
    set -f; local l; l="$(resolve_ledger)"; set +f
    _chk "$(basename "$(dirname "$l")")" "run-b" \
      "AC-1a resolve_ledger glob-free + newest under set -f"

    # AC-1c — TEAM_BOOTSTRAP_RUN pin still works (regression), even under set -f.
    set -f; m="$(TEAM_BOOTSTRAP_RUN=run-a resolve_marker)"; set +f
    _chk "$(basename "$(dirname "$m")")" "run-a" \
      "AC-1c TEAM_BOOTSTRAP_RUN pin honoured under set -f"
  )
  rm -rf "$T"
}

# AC-1f — delivery-lib.sh is SOURCED by every gate; its own --self-test block (if any)
# must be guarded [ "${BASH_SOURCE[0]}" = "$0" ] so a gate's own `check-X.sh --self-test`
# (which sets $1=--self-test, inherited on source) does not trip the lib's self-test and
# exit the parent. Proxy: sourcing delivery-lib with $1=--self-test must NOT exit non-zero
# or emit a self-test banner.
ws1_selftest_guard() {
  local out rc
  out="$(bash -c 'set -- --self-test; . "'"$here"'/bin/delivery-lib.sh"; echo LIB_SOURCED_OK' 2>&1)"; rc=$?
  _chk "$rc" "0" "AC-1f sourcing delivery-lib with \$1=--self-test does not exit the parent"
  _chk "$(printf '%s' "$out" | grep -c 'LIB_SOURCED_OK')" "1" \
    "AC-1f delivery-lib self-test block is guarded (source reaches the caller)"
}

echo "WS-1 — glob-free marker/ledger resolution (AC-1a/1c/1d/1e/1f):"
ws1
ws1_selftest_guard

# ---------------------------------------------------------------------------
# WS-2 — Stop-hook de-dup that ALWAYS preserves exit 2 (T021). The retro's token
# sink was a REPEATED block re-emitting the full explanation every Stop (each re-reads
# the whole context). De-dup: fingerprint the block (run + condition + ledger content-
# hash); an identical repeat emits ONE terse line but STILL exits 2. Never block→allow;
# any ledger-content change re-fires the full block.
# ---------------------------------------------------------------------------
ws2_dedup() {
  local T; T="$(mktemp -d)"
  ( cd "$T"
    git init -q; git config user.email a@b.c; git config user.name t
    git commit -q --allow-empty -m base; local BASE; BASE="$(git rev-parse HEAD)"
    printf 'x\n' > code.js; git add -A; git commit -q -m work   # code since baseline
    mkdir -p .runs/r
    printf '{"run":"r","pipeline":"full","source":"harness","intends_code":true,"baseline_sha":"%s"}\n' "$BASE" > .runs/r/RUN
    printf '{"id":"B1","kind":"code","status":"announced"}\n' > .runs/r/batches.jsonl   # unclosed → blocks

    local o1 rc1 o2 rc2 o3 rc3
    o1="$(TEAM_BOOTSTRAP_RUN=r "$here/bin/delivery-stop-hook.sh" 2>&1 <<<'{}')"; rc1=$?
    o2="$(TEAM_BOOTSTRAP_RUN=r "$here/bin/delivery-stop-hook.sh" 2>&1 <<<'{}')"; rc2=$?
    _chk "$rc1" "2" "AC-2b first block → exit 2"
    _chk "$rc2" "2" "AC-2b repeat identical block → STILL exit 2 (never block→allow)"
    _chk "$(printf '%s' "$o1" | grep -c 'BLOCKED —')" "1" "AC-2b first block is the FULL message"
    # repeat must be terser than the first (de-duped), not a re-emit of the full explanation
    _chk "$([ "$(printf '%s' "$o2" | wc -l)" -lt "$(printf '%s' "$o1" | wc -l)" ] && echo terser || echo same)" \
      "terser" "AC-2b repeat block is de-duped (terse), not a full re-emit"

    # ledger content change → full block re-fires (not treated as the same fingerprint)
    printf '{"id":"B2","kind":"code","status":"announced"}\n' >> .runs/r/batches.jsonl
    o3="$(TEAM_BOOTSTRAP_RUN=r "$here/bin/delivery-stop-hook.sh" 2>&1 <<<'{}')"; rc3=$?
    _chk "$rc3" "2" "AC-2b ledger changed → still exit 2"
    _chk "$(printf '%s' "$o3" | grep -c 'BLOCKED —')" "1" "AC-2b ledger content change → FULL block re-fires"
  )
  rm -rf "$T"
}

echo "WS-2 — Stop-hook de-dup preserves exit 2 (AC-2b):"
ws2_dedup

# ---------------------------------------------------------------------------
# WS-3 — SIGPIPE false-positive: `producer | consumer-that-returns-early` under
# `set -o pipefail` → the consumer short-circuits, the producer gets SIGPIPE(141),
# pipefail makes the pipeline non-zero → a passing check is read as a FAILURE. The
# live instance is check-completeness --final's `printf "$files" | _ac_in_tests` (fires
# only when $files > the 64KB pipe buffer, i.e. big repos). Fix: feed via herestring.
# ---------------------------------------------------------------------------
ws3_sigpipe() {
  # Demonstrate the class is real (documents WHY the fix matters), then pin the fix.
  _consumer() { while IFS= read -r x; do [ "$x" = "1" ] && return 0; done; return 1; }
  local big; big="$(seq 1 20000)"   # ~115KB > 64KB pipe buffer → forces the SIGPIPE
  local piped herestr
  ( set -o pipefail; printf '%s\n' "$big" | _consumer ); piped=$?
  ( set -o pipefail; _consumer <<< "$big" ); herestr=$?
  _chk "$piped" "141" "AC-3a the pipe pattern DOES 141 under pipefail (the bug class is real)"
  _chk "$herestr" "0" "AC-3a the herestring pattern is SIGPIPE-free (rc 0, the fix)"

  # Pin the real gate: check-completeness must NOT feed _ac_in_tests through a pipe (the vulnerable form).
  # Exclude comment lines — a comment documenting the anti-pattern must not count as the anti-pattern.
  local pipes; pipes="$(grep -vE '^[[:space:]]*#' "$here/bin/check-completeness.sh" | grep -Ec 'printf[^|]*\|[^|]*_ac_in_tests' || true)"
  _chk "$pipes" "0" "AC-3a check-completeness no longer pipes into _ac_in_tests (herestring instead)"

  # Regression: the gate still works (self-test green).
  local st; ( "$here/bin/check-completeness.sh" --self-test >/dev/null 2>&1 ); st=$?
  _chk "$st" "0" "AC-3a check-completeness --self-test still green after the fix"
}

echo "WS-3 — SIGPIPE false-positive elimination (AC-3a):"
ws3_sigpipe

# ---------------------------------------------------------------------------
# WS-4 — marker reader tolerates ANY valid JSON serialization. Top-level scalar reads
# are already space/newline tolerant; the real residual is NESTED reads (field_in_obj),
# which matched `"obj":{` (compact) and broke on a pretty-printer's `"obj": {` / newline.
# Gates read precond/preflight/enforcement via field_in_obj, so this false-skips them.
# ---------------------------------------------------------------------------
ws4_reader() {
  . "$here/bin/delivery-lib.sh"
  local pretty compact
  pretty="$(python3 -c 'import json;print(json.dumps({"run":"r","intends_code":True,"baseline_sha":"abc123","precond":{"exit":2,"ack":False},"preflight":{"exit":0,"ack":True}},indent=2))')"
  compact="$(python3 -c 'import json;print(json.dumps({"run":"r","intends_code":True,"baseline_sha":"abc123","precond":{"exit":2,"ack":False},"preflight":{"exit":0,"ack":True}},separators=(",",":")))')"

  # AC-4a — top-level scalars read back from the multiline (pretty) marker (already worked; regression pin).
  _chk "$(field_str "$pretty" run)" "r" "AC-4a field_str top-level on pretty marker"
  _chk "$(field_bool "$pretty" intends_code)" "true" "AC-4a field_bool top-level on pretty marker"

  # AC-4a — NESTED reads read back identically to compact (the real fix).
  _chk "$(field_in_obj "$pretty" precond exit)" "2" "AC-4a field_in_obj precond.exit on pretty (multiline)"
  _chk "$(field_in_obj "$pretty" precond ack)" "false" "AC-4a field_in_obj precond.ack on pretty (multiline)"
  _chk "$(field_in_obj "$pretty" preflight exit)" "0" "AC-4a field_in_obj preflight.exit on pretty (multiline)"
  # equivalence: pretty and compact give the SAME nested values
  _chk "$(field_in_obj "$pretty" precond exit)" "$(field_in_obj "$compact" precond exit)" \
    "AC-4a nested read: pretty == compact (round-trip)"

  # AC-4b — the plugin's own writers emit COMPACT single-line (regression pin): record_marker_list output
  # has no interior newline.
  local T; T="$(mktemp -d)"
  ( cd "$T"; mkdir -p .runs/r; printf '{"run":"r","intends_code":true}\n' > .runs/r/RUN
    . "$here/bin/delivery-lib.sh"; export TEAM_BOOTSTRAP_RUN=r
    record_marker_list seam_acks '[{"seam":"x","commit":"y"}]'
    _chk "$(wc -l < .runs/r/RUN | tr -d ' ')" "1" "AC-4b marker writer stays single-line (compact)" )
  rm -rf "$T"
}

echo "WS-4 — marker reader multiline/nested robustness (AC-4a/4b):"
ws4_reader

# ---------------------------------------------------------------------------
# (WS-5..WS-8 assertions land with their own batches.)
# ---------------------------------------------------------------------------

fail="$(cat "$FAILF")"; rm -f "$FAILF"
if [ "$fail" -eq 0 ]; then echo "harness-robustness.test.sh: OK"; exit 0; fi
echo "harness-robustness.test.sh: $fail failure(s)"; exit 1
