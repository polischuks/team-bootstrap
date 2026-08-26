#!/usr/bin/env bash
# record-task.sh — TaskCreated / TaskCompleted observer.
#
# Both events CAN block (TaskCreated even rolls the task back). This one does neither: batches are not
# native Tasks today, so any blocking rule here would be a guess about a mapping that does not exist
# yet — and a guessed gate is worse than an absent one, because it looks like coverage.
#
# What it does is make the native task lifecycle OBSERVABLE alongside the batch ledger, so that if and
# when batches do map onto Tasks the correlation is already recorded rather than reconstructed. Same
# posture as record-dispatch.sh: record, never block, no-op off-delivery.
#
# Exit: always 0.
set -uo pipefail
[ "${TEAM_BOOTSTRAP_DELIVERY_GATE:-on}" = "off" ] && exit 0
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/delivery-lib.sh
. "$here/delivery-lib.sh" 2>/dev/null || exit 0

EVENT="${1:-TaskCreated}"

if [ "$EVENT" = "--self-test" ]; then
  fail=0
  _c() { if [ "$1" = "$2" ]; then echo "  PASS $3"; else echo "  FAIL $3 (got [$1] want [$2])" >&2; fail=$((fail + 1)); fi; }
  T="$(mktemp -d)"
  _c "$( ( cd "$T" || exit 1; printf '{}' | "$here/record-task.sh" TaskCreated >/dev/null 2>&1 ); echo $? )" 0 "no marker ⇒ exit 0"
  _c "$( ( cd "$T" || exit 1; printf 'not json' | "$here/record-task.sh" TaskCreated >/dev/null 2>&1 ); echo $? )" 0 "unparseable payload ⇒ exit 0"
  ( cd "$T" || exit 1; mkdir -p .runs/r; printf '{"run":"r","intends_code":true}\n' > .runs/r/RUN
    printf '{"id":"B1","kind":"code","status":"announced"}\n' > .runs/r/batches.jsonl
    printf '{"task_id":"T7","description":"x"}' | TEAM_BOOTSTRAP_RUN=r "$here/record-task.sh" TaskCreated ) >/dev/null 2>&1
  _c "$(grep -c '"task":"T7"' "$T/.runs/r/tasks.jsonl" 2>/dev/null || echo 0)" 1 "a task is recorded against the run"
  rm -rf "$T"
  [ "$fail" -eq 0 ] && { echo "record-task --self-test: OK"; exit 0; }
  echo "record-task --self-test: $fail FAILED" >&2; exit 1
fi

payload="$(head -c 262144 2>/dev/null || true)"
marker="$(resolve_marker 2>/dev/null || true)"
[ -n "$marker" ] && [ -f "$marker" ] || exit 0

tid="$(printf '%s' "$payload" | grep -oE '"(task_id|taskId|id)"[[:space:]]*:[[:space:]]*"[^"]*"' \
  | head -1 | sed -E 's/.*"([^"]*)"[[:space:]]*$/\1/')"
[ -n "$tid" ] || exit 0
bline="$(inflight_batch 2>/dev/null || true)"
printf '{"event":"%s","task":"%s","batch":"%s"}\n' \
  "$EVENT" "$tid" "$(field_str "$bline" id)" >> "$(dirname "$marker")/tasks.jsonl" 2>/dev/null || true
exit 0
