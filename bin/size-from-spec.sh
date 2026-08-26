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
# The tier→roles mapping and the profile lookup live in ONE place (AC-14). This file used to carry a
# second copy as `_roles_for`, self-described as "Mirrors delivery-lib's required_roles_for_batch
# mapping exactly" — the drift Д2 §1.1 names by example. Sourcing is safe: delivery-lib never sources
# this script, it execs it, so there is no cycle.
# shellcheck source=bin/delivery-lib.sh
. "$here/delivery-lib.sh"

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

# --- complexity the PATHS cannot show (ADR-0019) ------------------------------
# The path classifier reads file count, layer count and five path-pattern risk categories. It is blind
# to what the milestone actually DOES. A spec about exactly-once distributed settlement — consensus,
# split-brain reconciliation, irreversible money movement — sized to single-thread because it touched
# two files in one directory. The hard part is described in spec.md and plan.md, and was never read.
#
# LIFT-ONLY, and word-boundary matched using this repo's portable idiom ((^|[^a-z])term([^a-z]|$)) —
# `\b` is not dependable across BSD and GNU grep. Bare `auth` is deliberately NOT a term: it matches
# "author", which appears in ordinary spec prose.
_PROSE_SECURITY='authentication|authoris|authoriz|oauth|jwt|credential|password|session token|access token|rbac|permission'
_PROSE_MONEY='payout|payment|billing|invoice|refund|settlement|irreversible'
_PROSE_DATA='migration|migrate|backfill|schema|reindex'
_PROSE_DIST='consensus|split-brain|partition|idempotent|idempotency|exactly-once|race|concurrency|concurrent|distributed|deadlock|lock-free'
_PROSE_INFRA='rollout|kubernetes|terraform|failover|blue-green|canary'

# _prose_reasons DIR → space-separated category names the milestone's prose trips (empty if none).
_prose_reasons() {
  local txt r="" c pat
  # Headings and <angle-bracket placeholders> are template scaffolding, not description. The stock
  # plan.md ships `## Data / schema changes (if any)` and `## Migration shape (if applicable)`, so
  # scanning them lifted EVERY milestone that used the template — which would make everything `full`
  # and destroy the point of sizing. Strip both, then match on what the author actually wrote.
  txt="$( { cat "$1/spec.md" "$1/plan.md"; } 2>/dev/null \
          | grep -v '^[[:space:]]*#' | sed 's/<[^>]*>//g' | tr '[:upper:]' '[:lower:]' )"
  [ -n "$txt" ] || return 0
  for c in "security:$_PROSE_SECURITY" "money:$_PROSE_MONEY" "data:$_PROSE_DATA" \
           "dist:$_PROSE_DIST" "infra:$_PROSE_INFRA"; do
    pat="${c#*:}"
    printf '%s' "$txt" | grep -qE "(^|[^a-z])(${pat})([^a-z]|\$)" && r="$r prose:${c%%:*}"
  done
  printf '%s' "${r# }"
}

# _declared_roles TEXT → the roles the task author asked for with `⚠ <role>`. A DECLARATION, not a
# heuristic — the strongest signal available, and it was being thrown away. Same trust model as the
# ledger's self-declared risk_rank (ADR-0006): forgeable, therefore one-directional. It can buy extra
# review; it can never remove review the paths or the prose already earned.
# `tb-code-reviewer` is the subagent type; `code-reviewer` is the attributed role (review-types.txt).
_declared_roles() {
  printf '%s\n' "$1" \
    | grep -oE '⚠[[:space:]]*[a-z-]+' 2>/dev/null \
    | sed 's/⚠[[:space:]]*//; s/^tb-code-reviewer$/code-reviewer/' \
    | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//'
}

# _roles_set TIER DECLARED CATEGORIES → the review set: the tier's DEPTH base, UNION whatever the task
# author declared with `⚠ <role>`, UNION whatever the risk CATEGORIES earn under the active profile.
#
# The base comes from delivery-lib's tier_base_roles — one definition, not a mirrored copy (AC-14).
# The category half is new here: this file could previously state a role plan for a work-stream whose
# paths clearly tripped security/auth without ever naming security-reviewer, because the profile was
# only consulted at batch time. The run-start plan and the close-time requirement now read the same
# two sources. The >=1 code-reviewer floor on a code batch is an invariant here too and is never sized,
# declared or profiled away — it is in every branch of tier_base_roles.
_roles_set() {
  local tier="$1" declared="$2" cats="$3" r out=""
  for r in $(tier_base_roles "$tier") $declared $(roles_for_categories "$cats" 2>/dev/null || true); do
    case " $out " in *" $r "*) : ;; *) out="$out $r" ;; esac
  done
  printf '%s' "${out# }"
}

# _tier_for PATHS — hand a newline-separated path list to select-pipeline's classifier and read back
# the tier. One place calls the classifier; both modes go through it.
_tier_for() { _classify "$1" | sed -n 's/^tier=//p'; }

# _cats_for PATHS → the risk categories those paths trip, space-separated (empty for none).
#
# Prefer _classify_once + _pick in a caller that needs BOTH facts: each _classify is a select-pipeline
# process, and asking twice for one path list costs a spawn to recompute an answer already in hand
# (ADR-0016 gate cost). _emit_ws does exactly that. This wrapper stays for callers that need only the
# categories.
_cats_for() { _pick cats "$(_classify "$1")"; }

# _pick KEY CLASSIFY_OUTPUT → the value of `KEY=` in a _classify result. Categories are filtered to the
# risk vocabulary here, at the one place that reads them, so no caller can forget to.
_pick() {
  local v; v="$(printf '%s\n' "$2" | sed -n "s/^$1=//p" | head -1)"
  case "$1" in cats) risk_categories_only "$v" ;; *) printf '%s' "$v" ;; esac
}

# _classify PATHS → `tier=<t>` and `cats=<c>` from ONE select-pipeline run, so composition and depth
# can never disagree about what the paths hold.
_classify() {
  local v
  v="$(printf '%s\n' "$1" | while IFS= read -r q || [ -n "$q" ]; do
         [ -n "$q" ] && printf '0\t0\t%s\n' "$q"
       done | "$here/select-pipeline.sh" --from-stdin 2>/dev/null || true)"
  printf 'tier=%s\n' "$(printf '%s\n' "$v" | sed -n 's/^select-pipeline: RECOMMENDED pipeline: \([a-z-]*\).*/\1/p' | head -1)"
  printf 'cats=%s\n' "$(printf '%s\n' "$v" | sed -nE 's/.*\(reasons: (.*)\)$/\1/p' | tail -1)"
}

# _sane_paths — drop anything that is not plausibly a repo path. tasks.md is AUTHORED content and its
# paths are spliced into the run marker's JSON; a value carrying a double quote or a backslash produced
# an UNPARSEABLE marker, and the marker is the machine fact every gate reads (atomic-marker AC-A1 pins
# an unreadable marker as a fail-OPEN). Filtering is the right shape rather than escaping: a path with
# a quote in it is a parse artifact, not a target file, so keeping it would be wrong even if it were
# encodable. Rejecting the token also keeps the surviving paths in the same task usable.
_sane_paths() {
  # A single leading dot is allowed and load-bearing: `.github/workflows/` is one of the five risk
  # categories, so anchoring on [A-Za-z0-9] silently declined to escalate CI changes — caught by the
  # AC-3 infra fixture. `..` is rejected in any position: a traversal is never a milestone target.
  grep -E '^\.?[A-Za-z0-9][A-Za-z0-9._/-]*$' 2>/dev/null | grep -v '\.\.' || true
}

# _paths_in TEXT — the `- file: a, b · (meta)` convention, then the conservative backtick fallback.
_paths_in() {
  local out
  out="$(printf '%s\n' "$1" | sed -n 's/^[[:space:]]*-[[:space:]]*file:[[:space:]]*\(.*\)$/\1/p' \
         | sed 's/·.*$//' | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' \
         | sort -u || true)"   # dedup: one file named by two tasks is one file, not two — counting it
                                # twice inflates the files>=3 / files>=10 thresholds and buys a tier
  out="$(printf '%s\n' "$out" | _sane_paths)"
  if [ -z "$out" ]; then
    out="$(printf '%s\n' "$1" | grep -oE '`[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+\.[A-Za-z0-9]+`' 2>/dev/null \
           | tr -d '`' | sort -u || true)"
  fi
  out="$(printf '%s\n' "$out" | _sane_paths)"
  printf '%s' "$out"
}

# --- per-work-stream mode (ADR-0018, OQ-2) -----------------------------------
# One entry per `## …` section of tasks.md, each sized on ITS OWN paths. Emitted as a template rather
# than as batch ids, because the orchestrator is free to batch across phase boundaries and the harness
# cannot force its control flow (ADR-0006/0008) — only observe it. A batch is matched to an entry at
# announce time by path overlap; no overlap means no floor, and the diff decides alone.
if [ "$per_batch" -eq 1 ]; then
  _ws=""; _body=""; _prose="$(_prose_reasons "$dir")"; _emitted=0
  _emit_ws() {
    [ -n "$_ws" ] || return 0
    local wp wt dr wc_ cl_
    wp="$(_paths_in "$_body")"
    [ -n "$wp" ] || return 0                 # a section that names no path earns no floor
    cl_="$(_classify "$wp")"          # ONE classifier run; both facts are read out of it below
    wt="$(_pick tier "$cl_")"
    [ -n "$wt" ] || return 0
    # The prose describes the MILESTONE, so it lifts every work-stream — except an all-doc one.
    # Applying it uniformly would re-create the flat fan-out ADR-0017 removed; skipping it for docs
    # is the same line select-pipeline's all-doc short-circuit already draws.
    if [ -n "$_prose" ] && [ "$wt" != "full" ] \
       && printf '%s\n' "$wp" | grep -qvE '\.(md|mdx|txt)$|^docs/|^references/'; then
      wt="full"        # a non-doc path is present, so the milestone's stated complexity applies here
    fi
    dr="$(_declared_roles "$_body")"
    wc_="$(_pick cats "$cl_")"
    printf 'ws=%s\ttier=%s\troles=%s\tcats=%s\tpaths=%s\n' "$_ws" "$wt" "$(_roles_set "$wt" "$dr" "$wc_")" "$wc_" \
      "$(printf '%s' "$wp" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    _emitted=$((_emitted + 1))
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
  # Degradation NEVER returns empty-and-green. A tasks.md with no `## ` sections (or whose sections name
  # no path) produced ZERO lines and rc=0 — indistinguishable, to every caller, from "sized it, no floors
  # apply". That is the silent-degradation class the audit calls out on its own: a log is not a control,
  # and neither is silence. Say so in the same machine-readable shape the other degrade paths use.
  [ "$_emitted" -gt 0 ] || _degrade "no-sized-work-streams"
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

# --- what the paths cannot show (ADR-0019) -----------------------------------
prose="$(_prose_reasons "$dir")"
if [ -n "$prose" ] && [ "$tier" != "full" ]; then
  tier="full"; reasons="${reasons:+$reasons }$prose"
fi
declared="$(_declared_roles "$(cat "$tasks")")"
[ -n "$declared" ] && reasons="${reasons:+$reasons }declared-roles"
roles="$(_roles_set "$tier" "$declared" "$reasons")"

printf 'tier=%s\nroles=%s\nfiles=%s\ntasks=%s\nlayers=%s\nreasons=%s\n' \
  "$tier" "$roles" "$files" "$ntasks" "$layers" "$reasons"
exit 0
