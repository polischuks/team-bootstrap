#!/usr/bin/env bash
# atomic-marker.test.sh — the run marker must never be observable in a partial state (issue #25).
#
# `printf … > "$marker"` truncates then writes. 19 scripts read the marker, and every fail-closed gate
# keys on `field_bool intends_code`, so a read landing between truncate and write sees an EMPTY marker,
# concludes "no active delivery run", and SILENTLY ALLOWS. That is a fail-OPEN — quieter, and therefore
# worse, than the false-block class ADR-0015 addressed.
#
# Contract: a concurrent reader sees the OLD marker or the NEW one. Never a partial one.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
FAILF="$(mktemp)"; printf '0' > "$FAILF"
_chk() { if [ "$1" = "$2" ]; then printf '  PASS %s\n' "$3"
  else printf '  FAIL %s (got [%s] want [%s])\n' "$3" "$1" "$2"
       printf '%s' "$(( $(cat "$FAILF") + 1 ))" > "$FAILF"; fi; }

echo "issue #25 — the run marker is never observable half-written:"

# AC-A1 — the fail-open this protects against: an empty marker makes the Stop hook allow a run that
# still has undelivered code. Pinned so the consequence stays visible even if the writer changes.
T="$(mktemp -d)"
( cd "$T" || exit 1; git init -q; git config user.email a@b.c; git config user.name t
  git commit -q --allow-empty -m base; printf 'x\n' > c.js; git add -A; git commit -q -m work
  mkdir -p .runs/r
  printf '{"run":"r","pipeline":"full","source":"harness","intends_code":true,"baseline_sha":"%s"}\n' "$(git rev-parse HEAD~1)" > .runs/r/RUN
  printf '{"id":"B1","kind":"code","status":"announced"}\n' > .runs/r/batches.jsonl
  rc=0; TEAM_BOOTSTRAP_RUN=r "$here/bin/delivery-stop-hook.sh" <<<'{}' >/dev/null 2>&1 || rc=$?
  _chk "$rc" "2" "AC-A1 intact marker → the Stop hook blocks undelivered code"
  : > .runs/r/RUN
  rc=0; TEAM_BOOTSTRAP_RUN=r "$here/bin/delivery-stop-hook.sh" <<<'{}' >/dev/null 2>&1 || rc=$?
  _chk "$rc" "0" "AC-A1 …and an EMPTY marker makes it allow — the fail-open being fixed" )
rm -rf "$T"

# AC-A2 — THE PROPERTY: hammer the writer while a reader polls. With a truncate-then-write the reader
# eventually catches an empty/partial marker; with write-temp-then-rename it never can.
T="$(mktemp -d)"
( cd "$T" || exit 1
  mkdir -p .runs/r
  printf '{"run":"r","intends_code":true,"baseline_sha":"abc"}\n' > .runs/r/RUN
  export TEAM_BOOTSTRAP_RUN=r
  # reader: 400 samples; a sample is BAD if the marker is empty or not a complete JSON object
  ( bad=0
    for _ in $(seq 1 400); do
      c="$(cat .runs/r/RUN 2>/dev/null)"
      case "$c" in
        '')      bad=$((bad+1)) ;;
        \{*\}*)  : ;;
        *)       bad=$((bad+1)) ;;
      esac
    done
    printf '%s' "$bad" > reader.out ) &
  rpid=$!
  # writer: rewrite a list field repeatedly through the real library path
  ( . "$here/bin/delivery-lib.sh"
    for i in $(seq 1 120); do
      record_marker_list seam_acks "[{\"seam\":\"s$i\",\"commit\":\"c$i\"}]" 2>/dev/null || true
    done )
  wait "$rpid" 2>/dev/null
  _chk "$(cat reader.out 2>/dev/null || echo ?)" "0" "AC-A2 a concurrent reader never observes a partial marker" )
rm -rf "$T"

# AC-A3 — a FAILED write must leave the PREVIOUS marker intact. Truncate-then-write can destroy a good
# marker on failure; write-temp-then-rename cannot.
T="$(mktemp -d)"
( cd "$T" || exit 1; mkdir -p .runs/r
  printf '{"run":"r","intends_code":true,"baseline_sha":"abc"}\n' > .runs/r/RUN
  before="$(cat .runs/r/RUN)"
  ( . "$here/bin/delivery-lib.sh"; export TEAM_BOOTSTRAP_RUN=r
    record_marker_list seam_acks 'THIS-IS-NOT-A-JSON-ARRAY' 2>/dev/null || true )
  _chk "$(cat .runs/r/RUN)" "$before" "AC-A3 a rejected/failed write leaves the previous marker intact" )
rm -rf "$T"

# AC-A4 — normal operation still works: the field lands and the marker stays valid single-line JSON.
T="$(mktemp -d)"
( cd "$T" || exit 1; mkdir -p .runs/r
  printf '{"run":"r","intends_code":true}\n' > .runs/r/RUN
  ( . "$here/bin/delivery-lib.sh"; export TEAM_BOOTSTRAP_RUN=r
    record_marker_list seam_acks '[{"seam":"control-surface","commit":"abc123"}]' )
  ok="$(python3 -c "import json;d=json.load(open('.runs/r/RUN'));print(d['seam_acks'][0]['seam'])" 2>/dev/null)"
  _chk "$ok" "control-surface" "AC-A4 the write still lands and the marker stays valid JSON"
  _chk "$(wc -l < .runs/r/RUN | tr -d ' ')" "1" "AC-A4 …and stays single-line (compact) as before" )
rm -rf "$T"

fail="$(cat "$FAILF")"; rm -f "$FAILF"
[ "$fail" -eq 0 ] && { echo "atomic-marker.test.sh: OK"; exit 0; }
echo "atomic-marker.test.sh: $fail failure(s)"; exit 1
