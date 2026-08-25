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

[ $# -ge 1 ] || { echo "usage: size-from-spec.sh <specs/<slug>|specs/<slug>/spec.md>" >&2; exit 64; }

arg="$1"
case "$arg" in
  *.md) dir="$(dirname "$arg")" ;;
  *)    dir="${arg%/}" ;;
esac
[ -d "$dir" ] || _degrade "no-spec-dir"

tasks="$dir/tasks.md"
[ -f "$tasks" ] || _degrade "no-tasks-md"

# --- target paths ------------------------------------------------------------
# Primary form is this repo's task convention:  `  - file: bin/a.sh, tests/b.sh · (feat · P10) — AC-1`
# Everything after the ` · ` is metadata, not a path, so the field is cut at the first middot.
paths="$(sed -n 's/^[[:space:]]*-[[:space:]]*file:[[:space:]]*\(.*\)$/\1/p' "$tasks" \
         | sed 's/·.*$//' | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' || true)"

# Fallback for milestones that do not use the `file:` convention: backtick-quoted tokens that look
# like a repo path (a slash and a file extension). Deliberately conservative — a false path would
# invent a risk category and inflate the tier, which is the failure mode this milestone exists to fix.
if [ -z "$paths" ]; then
  paths="$(grep -oE '`[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+\.[A-Za-z0-9]+`' "$tasks" 2>/dev/null \
           | tr -d '`' | sort -u || true)"
fi
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
tier="$(printf '%s\n' "$verdict" | sed -n 's/^select-pipeline: RECOMMENDED pipeline: \([a-z-]*\).*/\1/p' | head -1)"
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
