#!/usr/bin/env bash
# run-selection.test.sh — behavioural spec for ACTIVE-RUN SELECTION (issue #20).
#
# Bug (reported): resolve_marker/resolve_ledger pick the active run by mtime
# (`ls -t .runs/*/RUN | head -1`), so a stale sibling run whose RUN merely gets touched
# wins the race and gates read the WRONG run's marker/ledger.
#
# Bug (found while reproducing, worse): marker and ledger are resolved INDEPENDENTLY, so
# they can resolve to TWO DIFFERENT runs at once — every gate that reads both (verify-batch,
# check-delivery, delivery-stop-hook) then reasons about run A's marker with run B's ledger.
#
# Fix contract: an explicit active-run POINTER (.runs/current, written by delivery-marker-init
# when it arms a run) wins over mtime; both resolvers derive from the SAME run id (coherent by
# construction); $TEAM_BOOTSTRAP_RUN still outranks everything; a dangling/absent pointer falls
# back to the legacy newest-by-mtime rule — deliberately NOT a hard fail, because a fail-closed
# "refuse ambiguous" here would create a NEW false-block class on exactly the hot path the
# harness-robustness milestone just cleared (issue #20 constraints).
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
FAILF="$(mktemp)"; printf '0' > "$FAILF"
_chk() { # ACTUAL EXPECTED MSG
  if [ "$1" = "$2" ]; then printf '  PASS %s\n' "$3"
  else printf '  FAIL %s (got [%s] want [%s])\n' "$3" "$1" "$2"
       printf '%s' "$(( $(cat "$FAILF") + 1 ))" > "$FAILF"; fi
}
# _rundir PATH → the run directory name of a resolved .runs/<run>/<file> path ('' if empty)
_rundir() { [ -n "$1" ] && basename "$(dirname "$1")" || echo ""; }

# Build a fixture: two runs; the STALE one is touched last so it wins any mtime race.
_fixture() { # $1=dir  [$2=pointer-run-id]
  mkdir -p "$1/.runs/run-old" "$1/.runs/run-active"
  printf '{"run":"run-old","intends_code":true}\n'            > "$1/.runs/run-old/RUN"
  printf '{"id":"OLD","kind":"code","status":"closed"}\n'     > "$1/.runs/run-old/batches.jsonl"
  printf '{"run":"run-active","intends_code":true}\n'         > "$1/.runs/run-active/RUN"
  printf '{"id":"NEW","kind":"code","status":"announced"}\n'  > "$1/.runs/run-active/batches.jsonl"
  [ -n "${2:-}" ] && printf '%s\n' "$2" > "$1/.runs/current"
  sleep 1; touch "$1/.runs/run-old/RUN" "$1/.runs/run-old/batches.jsonl"   # stale sibling wins mtime
}

echo "issue #20 — active-run selection (pointer beats mtime; marker/ledger coherent):"

# AC-20a — the pointer wins over a newer-mtime stale sibling.
T="$(mktemp -d)"; _fixture "$T" run-active
env -u TEAM_BOOTSTRAP_RUN bash -c "cd '$T'; . '$here/bin/delivery-lib.sh'; printf '%s|%s' \"\$(resolve_marker)\" \"\$(resolve_ledger)\"" > "$T/out"
IFS='|' read -r m l < "$T/out"
_chk "$(_rundir "$m")" "run-active" "AC-20a .runs/current pointer beats a newer-mtime stale sibling (marker)"
_chk "$(_rundir "$l")" "run-active" "AC-20a pointer selects the same run for the ledger"
rm -rf "$T"

# AC-20b — COHERENCE: marker and ledger always name the SAME run, even with no pointer
# (legacy mtime path) and even when the siblings' newest files disagree.
T="$(mktemp -d)"; _fixture "$T"                      # no pointer → legacy mtime fallback
touch "$T/.runs/run-active/batches.jsonl"            # make the OTHER run's ledger newest
env -u TEAM_BOOTSTRAP_RUN bash -c "cd '$T'; . '$here/bin/delivery-lib.sh'; printf '%s|%s' \"\$(resolve_marker)\" \"\$(resolve_ledger)\"" > "$T/out"
IFS='|' read -r m l < "$T/out"
_chk "$([ -n "$(_rundir "$m")" ] && echo nonempty || echo empty)" "nonempty" "AC-20b (guard) the fixture actually resolves a run"
_chk "$(_rundir "$l")" "$(_rundir "$m")" "AC-20b marker and ledger resolve to the SAME run (no split-brain)"
rm -rf "$T"

# AC-20c — $TEAM_BOOTSTRAP_RUN still outranks the pointer (explicit pin precedence, regression).
T="$(mktemp -d)"; _fixture "$T" run-active
out="$(cd "$T" && TEAM_BOOTSTRAP_RUN=run-old bash -c ". '$here/bin/delivery-lib.sh'; printf '%s|%s' \"\$(resolve_marker)\" \"\$(resolve_ledger)\"")"
IFS='|' read -r m l <<< "$out"
_chk "$(_rundir "$m")" "run-old" "AC-20c TEAM_BOOTSTRAP_RUN outranks the pointer (marker)"
_chk "$(_rundir "$l")" "run-old" "AC-20c TEAM_BOOTSTRAP_RUN outranks the pointer (ledger)"
rm -rf "$T"

# AC-20d — NO NEW FALSE-BLOCK: a dangling pointer (run removed) must fall back to the legacy
# newest-by-mtime rule, not resolve empty (empty marker = every fail-closed gate false-fires).
T="$(mktemp -d)"; _fixture "$T" run-deleted
env -u TEAM_BOOTSTRAP_RUN bash -c "cd '$T'; . '$here/bin/delivery-lib.sh'; printf '%s' \"\$(resolve_marker)\"" > "$T/out"
_chk "$([ -s "$T/out" ] && echo nonempty || echo empty)" "nonempty" \
  "AC-20d dangling .runs/current → falls back to mtime, never resolves empty"
rm -rf "$T"

# AC-20e — legacy contract preserved: with no pointer at all, newest-by-mtime still wins
# (this is the AC-1e recency contract from harness-robustness, deliberately re-specified here).
T="$(mktemp -d)"; _fixture "$T"
env -u TEAM_BOOTSTRAP_RUN bash -c "cd '$T'; . '$here/bin/delivery-lib.sh'; printf '%s' \"\$(resolve_marker)\"" > "$T/out"
_chk "$(_rundir "$(cat "$T/out")")" "run-old" "AC-20e no pointer → legacy newest-by-mtime selection preserved"
rm -rf "$T"

# AC-20f — the harness writer records the pointer: delivery-marker-init must write .runs/current
# naming the run it arms (otherwise the pointer never exists on real traffic).
T="$(mktemp -d)"
( cd "$T" && git init -q && git config user.email a@b.c && git config user.name t \
    && git commit -q --allow-empty -m base ) >/dev/null 2>&1
printf '{"prompt":"/team-bootstrap:deliver full specs/x"}' \
  | ( cd "$T" && env -u TEAM_BOOTSTRAP_RUN "$here/bin/delivery-marker-init.sh" ) >/dev/null 2>&1
armed="$(cd "$T" && ls .runs 2>/dev/null | grep -v '^current$' | head -1)"
_chk "$([ -f "$T/.runs/current" ] && echo yes || echo no)" "yes" \
  "AC-20f delivery-marker-init writes the .runs/current pointer when it arms a run"
_chk "$(cat "$T/.runs/current" 2>/dev/null)" "$armed" \
  "AC-20f the pointer names the run it just armed"
rm -rf "$T"

fail="$(cat "$FAILF")"; rm -f "$FAILF"
[ "$fail" -eq 0 ] && { echo "run-selection.test.sh: OK"; exit 0; }
echo "run-selection.test.sh: $fail failure(s)"; exit 1
