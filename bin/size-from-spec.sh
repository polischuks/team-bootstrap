#!/usr/bin/env bash
# size-from-spec.sh — evaluate an ON-DISK milestone (spec.md/plan.md/tasks.md) into a pipeline tier.
#
# WHY THIS EXISTS (ADR-0018). `/deliver` chose its tier from the first argument token, before Phase A
# had produced anything to size against — and when the operator handed it a spec that ALREADY existed,
# the path was simply "not mvp|full" and fell through to the heaviest 20-role tier
# (commands/deliver.md:9-11, delivery-marker-init.sh:50). When the milestone is on disk the ordering
# problem disappears: tasks.md names its own target paths, so the sizing input is readable before the
# first dispatch.
#
# REUSE, NOT A SECOND CLASSIFIER. The path -> layer -> risk-category mapping lives in
# select-pipeline.sh (`recommend`), is covered by its --self-test, and is NOT duplicated here. This
# script only turns tasks.md into the numstat that classifier already accepts on stdin. If the two
# ever disagree, select-pipeline is right by construction — there is only one of it.
#
# VOLUME SIGNAL. A spec has no diff, so there are no line counts: the `lines>=150` / `lines>=600`
# thresholds cannot fire. File count, layer count and the five risk categories are all still REAL
# (they come from the paths tasks.md names). Task count substitutes for the missing volume signal, and
# deliberately lifts only as far as `mvp` — escalation to `full` stays owned by the risk signals, so a
# merely long milestone cannot buy the 20-role pipeline on length alone.
#
# Usage:  bin/size-from-spec.sh <specs/<slug> | specs/<slug>/spec.md>
# Stdout: key=value lines — tier, files, tasks, layers, reasons  (or degraded=1 + reason=)
# Exit:   0 always, EXCEPT 64 on bad usage. This is called from the UserPromptSubmit hook; a non-zero
#         exit there would take the whole run's fail-closed posture down with it, which is a far worse
#         failure than declining to size (the caller then behaves exactly as v2.32.0 did).
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"

_degrade() { printf 'degraded=1\nreason=%s\n' "$1"; exit 0; }

per_batch=0
[ "${1:-}" = "--per-batch" ] && { per_batch=1; shift; }
[ $# -ge 1 ] || { echo "usage: size-from-spec.sh [--per-batch] <specs/<slug>|specs/<slug>/spec.md>" >&2; exit 64; }

arg="$1"
case "$arg" in
  *.md) dir="$(dirname "$arg")" ;;
  *)    dir="${arg%/}" ;;
esac
[ -d "$dir" ] || _degrade "no-spec-dir"

tasks="$dir/tasks.md"
[ -f "$tasks" ] || _degrade "no-tasks-md"

# _tier_for PATHS — hand a newline-separated path list to select-pipeline's classifier and read back
# the tier. One place calls the classifier; both modes go through it.
_tier_for() {
  local v
  v="$(printf '%s\n' "$1" | while IFS= read -r q || [ -n "$q" ]; do
         [ -n "$q" ] && printf '0\t0\t%s\n' "$q"
       done | "$here/select-pipeline.sh" --from-stdin 2>/dev/null || true)"
  printf '%s\n' "$v" | sed -n 's/^select-pipeline: RECOMMENDED pipeline: \([a-z-]*\).*/\1/p' | head -1
}

# _paths_in TEXT — the `- file: a, b · (meta)` convention, then the conservative backtick fallback.
_paths_in() {
  local out
  out="$(printf '%s\n' "$1" | sed -n 's/^[[:space:]]*-[[:space:]]*file:[[:space:]]*\(.*\)$/\1/p' \
         | sed 's/·.*$//' | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' \
         | sort -u || true)"   # dedup: one file named by two tasks is one file, not two — counting it
                                # twice inflates the files>=3 / files>=10 thresholds and buys a tier
  if [ -z "$out" ]; then
    out="$(printf '%s\n' "$1" | grep -oE '`[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+\.[A-Za-z0-9]+`' 2>/dev/null \
           | tr -d '`' | sort -u || true)"
  fi
  printf '%s' "$out"
}

# --- per-work-stream mode (ADR-0018, OQ-2) -----------------------------------
# One entry per `## …` section of tasks.md, each sized on ITS OWN paths. Emitted as a template rather
# than as batch ids, because the orchestrator is free to batch across phase boundaries and the harness
# cannot force its control flow (ADR-0006/0008) — only observe it. A batch is matched to an entry at
# announce time by path overlap; no overlap means no floor, and the diff decides alone.
if [ "$per_batch" -eq 1 ]; then
  _ws=""; _body=""
  _emit_ws() {
    [ -n "$_ws" ] || return 0
    local wp wt
    wp="$(_paths_in "$_body")"
    [ -n "$wp" ] || return 0                 # a section that names no path earns no floor
    wt="$(_tier_for "$wp")"
    [ -n "$wt" ] || return 0
    printf 'ws=%s\ttier=%s\tpaths=%s\n' "$_ws" "$wt" \
      "$(printf '%s' "$wp" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  }
  # Read in the CURRENT shell (redirect on `done`), not a pipeline — a subshell would discard the
  # accumulated section on every iteration and emit nothing.
  while IFS= read -r _line || [ -n "$_line" ]; do
    case "$_line" in
      '## '*)
        _emit_ws
        _ws="$(printf '%s' "$_line" | grep -oE 'WS-[A-Za-z0-9]+' | head -1)"
        [ -n "$_ws" ] || _ws="$(printf '%s' "$_line" \
          | sed -E 's/^##[[:space:]]*//; s/[[:space:]]*[—:-].*$//; s/[^A-Za-z0-9]+/-/g; s/^-//; s/-$//')"
        _body=""
        ;;
      *) _body="$_body$_line
" ;;
    esac
  done < "$tasks"
  _emit_ws
  exit 0
fi

# --- target paths ------------------------------------------------------------
# Primary form is this repo's task convention:  `  - file: bin/a.sh, tests/b.sh · (feat · P10) — AC-1`
# Everything after the ` · ` is metadata, not a path, so the field is cut at the first middot.
paths="$(_paths_in "$(cat "$tasks")")"
[ -n "$paths" ] || _degrade "no-target-paths"

# --- task count --------------------------------------------------------------
ntasks="$(grep -cE '^[[:space:]]*-[[:space:]]*\[[ xX]\][[:space:]]*T[0-9]' "$tasks" 2>/dev/null || true)"
case "$ntasks" in ''|*[!0-9]*) ntasks=0 ;; esac
if [ "$ntasks" -eq 0 ]; then
  ntasks="$(sed -n 's/^[[:space:]]*-[[:space:]]*Total tasks:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$tasks" | head -1)"
  case "$ntasks" in ''|*[!0-9]*) ntasks=0 ;; esac
fi

# --- classify (delegated) ----------------------------------------------------
numstat="$(printf '%s\n' "$paths" | while IFS= read -r p || [ -n "$p" ]; do
  [ -n "$p" ] && printf '0\t0\t%s\n' "$p"
done)"

verdict="$(printf '%s\n' "$numstat" | "$here/select-pipeline.sh" --from-stdin 2>/dev/null || true)"
tier="$(_tier_for "$paths")"
[ -n "$tier" ] || _degrade "classifier-unavailable"

files="$(printf '%s\n' "$paths" | grep -c . || true)"
layers="$(printf '%s\n' "$paths" | sed -n 's#^\([^/]*\)/.*#\1#p' | sort -u | grep -c . || true)"
reasons="$(printf '%s\n' "$verdict" | sed -n 's/.*(reasons: \(.*\))$/\1/p' | head -1)"

# --- volume substitute -------------------------------------------------------
# Lift to mvp only. See the header: length is not a reason for twenty roles.
if [ "$ntasks" -ge 12 ] && [ "$tier" = "single-thread" ]; then
  tier="mvp"; reasons="${reasons:+$reasons }tasks>=12"
fi

printf 'tier=%s\nfiles=%s\ntasks=%s\nlayers=%s\nreasons=%s\n' \
  "$tier" "$files" "$ntasks" "$layers" "$reasons"
exit 0
