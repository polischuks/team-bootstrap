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
# (WS-3..WS-8 assertions land with their own batches.)
# ---------------------------------------------------------------------------

fail="$(cat "$FAILF")"; rm -f "$FAILF"
if [ "$fail" -eq 0 ]; then echo "harness-robustness.test.sh: OK"; exit 0; fi
echo "harness-robustness.test.sh: $fail failure(s)"; exit 1
