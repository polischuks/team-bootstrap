#!/usr/bin/env bash
# delivery-marker-init.sh — harness-owned RUN-marker writer (UserPromptSubmit hook).
#
# The delivery gate's "self-starting" property depends on the run marker being a
# MACHINE fact, not an orchestrator courtesy. If the marker were written by /deliver
# prose, an orchestrator that skips the protocol writes no marker and every gate
# no-ops — the fail-open seam just moves from "no ledger" to "no marker" (see the
# Step-7 architecture review, F-1). So the HARNESS writes it: this hook fires on
# prompt submission, and when the prompt invokes a /deliver-style command it ensures
# .runs/<run>/RUN exists BEFORE any Skill/tool runs. deliver.md step 0 only ENRICHES.
#
# Safety: this hook must never disrupt a prompt. It reads stdin, and on ANYTHING it
# does not recognise it exits 0 with no output. It only ever CREATES a marker (never
# clobbers an existing one — baseline_sha must be stable). It writes to a gitignored
# .runs/ path. Disable with TEAM_BOOTSTRAP_DELIVERY_GATE=off.
#
# Registered under UserPromptSubmit in hooks/hooks.json. (If a future Claude Code
# contract does not carry slash-command args on UserPromptSubmit, the documented
# fallback is a PreToolUse floor on the first Skill call + deliver.md step 0 — see
# specs/.../plan.md §2.4.)
#
# Exit: always 0 (non-blocking). STDOUT carries the harness's sizing verdict to the
# model via hookSpecificOutput.additionalContext — the sanctioned UserPromptSubmit
# context channel. It used to go to stderr, which at exit 0 reaches only the debug
# log: the harness decided the tier and had no way to say so, leaving .runs/<id>/RUN
# (a format built for scripts) as the sole carrier and the model free to never read
# it. An unrecognised prompt still produces NO output at all.
set -uo pipefail

# The JSON escaper and the context emitter live in delivery-lib.sh — ONE definition (AC-3, AC-14).
# This file used to carry private copies named _json_esc/_emit_ctx, and the copy here kept the old
# `cut -c1-9000` truncation after delivery-lib had already learned to SPILL: the same mapping in two
# places, drifting, on the channel whose whole job is not losing the decision. Sourcing delivery-lib
# has no side effects (see its header).
# shellcheck source=bin/delivery-lib.sh
. "$(cd "$(dirname "$0")" && pwd)/delivery-lib.sh"

_json_esc() { json_esc "$1"; }
_emit_ctx() { emit_hook_context UserPromptSubmit "$1"; }

# _spec_ref_in_git PATH → echo the short ref (HEAD, or a branch name) that CONTAINS PATH as a blob, or
# nothing. Issue #105: `spec_present` is on-disk truth, but a spec that exists on a git branch and is not
# checked out must NOT be silently read as a bare description. Consult git before concluding "description":
# HEAD first, then every local/remote branch. Best-effort and offline-safe — a non-git tree or a repo
# where cat-file fails just yields nothing (the genuine-description path is preserved).
_spec_ref_in_git() {
  local _p="$1" _r
  [ -n "$_p" ] || return 0
  git rev-parse --git-dir >/dev/null 2>&1 || return 0
  if git cat-file -e "HEAD:$_p" 2>/dev/null; then printf 'HEAD'; return 0; fi
  for _r in $(git for-each-ref --format='%(refname:short)' refs/heads refs/remotes 2>/dev/null); do
    if git cat-file -e "$_r:$_p" 2>/dev/null; then printf '%s' "$_r"; return 0; fi
  done
  return 0
}

# _retarget_feature_json NEW_ACTIVE_SPEC → reconcile feature.json's `active_spec` to NEW (the marker's
# feature dir) when they disagree; echo the OLD value so the caller can name the mismatch, else nothing.
# Issue #114: the speckit skills (specify/plan/tasks/analyze) read feature.json, so a stale active_spec
# silently drives the WRONG milestone even though the harness sizes off the marker. The hook otherwise
# only writes gitignored .runs/, but the run's feature IS a machine fact the hook owns, so it is the one
# place that can keep the pointer honest. In-place value replacement (targeted sed) preserves the rest of
# the file; best-effort — any failure leaves feature.json untouched.
_retarget_feature_json() {
  local _new="$1" _fj="feature.json" _cur _tmp _esc
  [ -n "$_new" ] || return 0
  [ -f "$_fj" ] || return 0
  _cur="$(field_str "$(cat "$_fj" 2>/dev/null)" active_spec)"
  [ -n "$_cur" ] || return 0            # no pointer to reconcile (null/absent) — leave alone
  [ "$_cur" = "$_new" ] && return 0     # already agrees — no churn, no notice
  _tmp="$(mktemp 2>/dev/null)" || return 0
  _esc="$(printf '%s' "$_new" | sed 's/[\\/&]/\\&/g')"
  if sed -E "s#(\"active_spec\"[[:space:]]*:[[:space:]]*\")[^\"]*(\")#\1$_esc\2#" "$_fj" > "$_tmp" 2>/dev/null; then
    cat "$_tmp" > "$_fj" 2>/dev/null && printf '%s' "$_cur"
  fi
  rm -f "$_tmp" 2>/dev/null || true
}

[ "${TEAM_BOOTSTRAP_DELIVERY_GATE:-on}" = "off" ] && exit 0

payload="$(cat 2>/dev/null || true)"
[ -n "$payload" ] || exit 0

# Arm on ANY team-bootstrap delivery invocation — not just /deliver. Two entry points ship
# code and must be guarded equally:
#   - the orchestrated command:  /team-bootstrap:deliver <pipeline> …   (signature: :deliver)
#   - a direct pipeline run:      /team-bootstrap:team-bootstrap <pipeline> …  (any /team-bootstrap: cmd)
# Reliable signature = a "/team-bootstrap:" slash command, or a bare /deliver (back-compat).
is_deliver=0
printf '%s' "$payload" | grep -qE 'commands:deliver|:deliver|(^|[^A-Za-z])/deliver([^A-Za-z]|$)' && is_deliver=1
if [ "$is_deliver" -eq 0 ]; then
  printf '%s' "$payload" | grep -qE '(^|[^A-Za-z])/team-bootstrap:' || exit 0
fi

# Derive the run name + feature from a specs/<slug>[/…] path in the prompt; else a stable fallback.
# The trailing path is OPTIONAL: `/deliver full specs/<slug>` (a bare directory, no /spec.md) must still
# be captured — else `feature` falls to "unknown" and the completeness gate can only skip (green-by-skip;
# see check-completeness.sh). Both `specs/<slug>` and `specs/<slug>/spec.md` derive run=<slug>.
# Resolved ahead of tier selection (ADR-0018): when this path exists on disk it IS the sizing input.
spec="$(printf '%s' "$payload" | grep -oE 'specs/[A-Za-z0-9._-]+(/[A-Za-z0-9._/-]*)?' | head -1)"

# The tier is the FIRST ARGUMENT TOKEN — the one immediately after the command — exactly as
# commands/deliver.md has always specified. Nothing else in the prompt is a tier.
#
# It used to be grepped from the whole payload, so ANY prompt containing `full`, `mvp` or
# `single-thread` selected that pipeline: `/deliver "give the user full control over billing"` bought
# the 20-role fan-out from a sentence. v2.33.0 patched one symptom — a specs/ slug containing a tier
# word — by excising the path before the grep, which did nothing for the same word in prose. Position
# is the actual contract, so position is what gets read.
#
# Anchoring on the command name also removes any need to parse JSON. The real UserPromptSubmit payload
# is an envelope ({"cwd":"…","prompt":"/deliver …"}), and a command sits contiguously with its
# arguments inside the prompt string — so a tier word in `cwd` (e.g. /Users/x/full-stack-app) can never
# be mistaken for a tier, which a whole-payload grep could not guarantee.
#
# `full` is NOT a fallback (ADR-0018). No recognised first token means `auto`: the harness sizes the run
# from the spec. Analysis pipelines (audit/audit-dd/l2p) still never arm a code run — their first token
# is not one of the three code tiers, so `pipeline` stays empty and a non-/deliver invocation exits.
_first_arg="$(printf '%s' "$payload" \
  | grep -oE '(/deliver|:deliver|/team-bootstrap:[A-Za-z0-9_-]+)[[:space:]]+[^[:space:]]+' \
  | head -1 | sed -E 's#^.*[[:space:]]+##')"
pipeline=""
tier_source="operator"
case "$_first_arg" in
  single-thread|mvp|full) pipeline="$_first_arg" ;;
esac
if [ -z "$pipeline" ]; then
  [ "$is_deliver" -eq 1 ] || exit 0        # a bare skill invocation still needs an explicit token
  tier_source="harness"
fi

run="$(printf '%s' "$spec" | sed -E 's#^specs/([^/]+).*#\1#')"
[ -n "$run" ] || run="deliver-run"

marker=".runs/$run/RUN"
mkdir -p ".runs/$run" 2>/dev/null || exit 0
# issue #20 — record the ACTIVE run EXPLICITLY so the resolvers never have to guess by mtime (a
# finished sibling whose RUN gets touched used to win that race, and marker vs ledger could even
# resolve to two different runs). Written on EVERY arm — including when the marker already exists —
# so re-arming an in-flight run re-points the pointer at it. Best-effort: a write failure just
# degrades to the legacy mtime rule, it never blocks the run.
{ printf '%s\n' "$run" > .runs/current; } 2>/dev/null || true
# Idempotent: never clobber baseline_sha. The verdict is RE-STATED, though — a run spans many prompts
# and a context compaction, and the sizing is only useful in the window where it is read.
if [ -f "$marker" ]; then
  _mk_prev="$(cat "$marker" 2>/dev/null || true)"
  _prev_degraded="$(field_str "$_mk_prev" sizing_degraded)"
  _prev_ctx="$(sed -n 's/.*"harness_context":"\([^"]*\)".*/\1/p' "$marker" 2>/dev/null | head -1)"
  _prev_spec="$(field_str "$_mk_prev" spec_path)"
  _prev_src="$(field_str "$_mk_prev" tier_source)"
  _prev_pipe="$(field_str "$_mk_prev" pipeline)"

  # RECONCILE AN OPERATOR-DECLARED TIER (issue #47). Choosing the tier by hand is legitimate (P1) — but
  # a marker written by an earlier harness/auto arm carries dependent fields that describe a computation
  # the operator's choice SUPERSEDED: review_depth, sizing_degraded, risk_categories, assigned_roles and
  # the harness_context sentence all still speak for the old tier. A field that describes a superseded
  # computation is worse than an absent one, because a reader trusts it. So when tier_source is operator
  # we bring those fields into agreement with the DECLARED tier and never touch the tier itself:
  #   - review_depth and the tier's depth-BASE roles are a function of the declared tier alone, so they
  #     are always recomputable — even with no spec on disk.
  #   - risk_categories and the category-earned roles need the spec; when one is resolvable we size it,
  #     when it is not we mark them "not computed" (fail closed — never a stale "none" a reader trusts).
  # The re-size below must NOT run for this path: recomputing the tier would OVERRULE the human (the
  # bug this issue also exposes), so it is guarded to the harness path it was built for.
  #
  # Cheap staleness gate first: recompute only when a dependent visibly disagrees with the declared
  # tier (wrong depth, a stale degradation, or an empty role floor). Once reconciled these all agree, so
  # a settled operator run costs no size-from-spec spawn on later arms and re-announces nothing.
  if [ "$_prev_src" = "operator" ]; then
    _op_depth="$(review_depth_for_tier "$_prev_pipe")"
    _op_stale=0
    [ "$(field_str "$_mk_prev" review_depth)" = "$_op_depth" ] || _op_stale=1
    [ -n "$_prev_degraded" ] && _op_stale=1
    [ -n "$(field_str "$_mk_prev" assigned_roles)" ] || _op_stale=1
    if [ "$_op_stale" -eq 1 ]; then
      # The depth-base roles the declared tier earns — knowable without a spec (delivery-lib, AC-14).
      _op_roles=""
      for _r in $(tier_base_roles "$_prev_pipe"); do
        case " $_op_roles " in *" $_r "*) : ;; *) _op_roles="${_op_roles:+$_op_roles }$_r" ;; esac
      done
      # Resolve a spec to size the CATEGORIES against: the marker's recorded path first, else the path
      # named in this prompt normalised to spec.md (the fresh-path rule).
      _op_spec="$_prev_spec"
      if [ -z "$_op_spec" ] && [ -n "$spec" ]; then
        case "$spec" in *.md) _op_spec="$spec" ;; *) _op_spec="${spec%/}/spec.md" ;; esac
      fi
      _op_cats=""; _op_degraded=""; _op_selran=""
      if [ -n "$_op_spec" ] && [ -f "$_op_spec" ]; then
        _op_out="$("$(dirname "$0")/size-from-spec.sh" "$_op_spec" 2>/dev/null || true)"
        case "$_op_out" in
          *degraded=1*)
            # Spec present but not sizable yet: the categories cannot be computed. Record WHY, and leave
            # them not-computed rather than inventing a "none".
            _op_degraded="$(printf '%s\n' "$_op_out" | sed -n 's/^reason=//p' | head -1)"
            [ -n "$_op_degraded" ] || _op_degraded="unknown"
            ;;
          *)
            if [ -n "$_op_out" ]; then
              _op_selran=1
              _op_cats="$(risk_categories_only "$(printf '%s\n' "$_op_out" | sed -n 's/^reasons=//p' | head -1)")"
              for _r in $(roles_for_categories "$_op_cats" 2>/dev/null || true); do
                case " $_op_roles " in *" $_r "*) : ;; *) _op_roles="${_op_roles:+$_op_roles }$_r" ;; esac
              done
            fi
            ;;
        esac
      fi
      # The reconciled sentence, phrased as FACT STATEMENTS like the main path. "none" and "not computed"
      # stay DIFFERENT facts: $_op_selran is set only when the classifier was actually consulted.
      _op_ctx="team-bootstrap harness sizing for run $run: pipeline=$_prev_pipe, tier_source=operator, marker=$marker."
      _op_ctx="$_op_ctx Review depth: $_op_depth (the /code-review low-medium-high scale; the tier sets depth, the risk categories set composition)."
      if [ -n "$_op_selran" ]; then
        _op_ctx="$_op_ctx Risk categories detected: ${_op_cats:-none}."
      else
        if [ -n "$_op_degraded" ]; then _op_why="the classifier ran and could not classify: $_op_degraded"
        else _op_why="no spec is resolvable on disk, so the operator's tier cannot be sized for categories"; fi
        _op_ctx="$_op_ctx Risk categories detected: not computed ($_op_why)."
      fi
      _op_ctx="$_op_ctx Assigned review roles for this run: ${_op_roles:-none} (the declared tier's review floor; the batch diff may lift it)."
      [ -n "$_op_degraded" ] && _op_ctx="$_op_ctx Per-work-stream sizing DEGRADED (reason: $_op_degraded) — no work-stream floors were derived; the batch diff sizes each batch alone."
      if splice_marker_fields "$marker" \
           "review_depth=$_op_depth" "sizing_degraded=$_op_degraded" \
           "risk_categories=$_op_cats" "assigned_roles=$_op_roles" \
           "harness_context=$(_json_esc "$_op_ctx")"; then
        _op_note="$_op_ctx The tier was declared by the operator; its dependent fields were RECONCILED to it just now — they had described a superseded sizing."
        _emit_ctx "$(_json_esc "$_op_note")"
        exit 0
      fi
    fi
    _emit_ctx "$_prev_ctx"
    exit 0
  fi

  # RE-SIZE A DEGRADED RUN. The marker is written once, and for a description-form run that moment is
  # always BEFORE Phase A produces tasks.md — so the sizing degrades, and because every later arm took
  # this branch and exited, it never recovered. The run stayed `pipeline=auto` for its whole life with
  # a perfectly sizable tasks.md on disk beside it. Observed on run 176-withgauge-platform-integration,
  # where the orchestrator hand-edited the marker to `full`: it was doing the harness's job because the
  # harness had stopped doing it, and `tier_source` went on claiming the harness had decided.
  #
  # The recompute is resize_degraded_marker (delivery-lib.sh) — ONE definition, shared with the mid-turn
  # hook (delivery-resize.sh, PostToolBatch) so the same recovery fires whether a new prompt arrives OR
  # the artefacts land inside one agentic turn (issue #48). It is narrow: only an UNRESOLVED run is
  # recomputed — one that DEGRADED, or one still at `auto` because it armed description-form with no spec
  # on disk (issue #92; the function resolves the spec through the marker's `feature` field and records
  # spec_path) — only the fields the hook owns are spliced (precond / preflight / repro_env / the acks
  # survive; baseline_sha is never touched), and a run that sized cleanly is left alone. On a re-size it
  # returns the RE-SIZED notice; empty ⇒ nothing to recompute, so re-state the stored verdict.
  # ISSUE #104 — advance the code-delivery baseline PAST Phase A. `baseline_sha` is stamped at /deliver,
  # before Phase A commits spec/plan/tasks (and `feature.json`), so those commits fall inside the FIRST
  # code batch's `baseline..HEAD` window and become its tdd anchor — a bug #93's impl-delta filter cannot
  # catch for a commit that touches a non-doc, non-test file like `feature.json`. Stamp `code_baseline_sha`
  # ONCE at the A->B boundary so `current_batch_base` uses it for the first batch. The boundary is proven,
  # not guessed: tasks.md must be COMMITTED at HEAD (`git cat-file -e HEAD:<tasks>`), so HEAD is *after*
  # the Phase-A docs commits — cbsha=HEAD then excludes them from the first batch's window. Fires only on
  # an armed harness run with no code batch announced yet and the field unset; additive (baseline_sha is
  # never touched, so predate/reachable checks are unaffected); once set, a later prompt leaves it alone.
  if [ -z "$(field_str "$_mk_prev" code_baseline_sha)" ]; then
    _cb_spec="$(field_str "$_mk_prev" spec_path)"; [ -n "$_cb_spec" ] || _cb_spec="$(field_str "$_mk_prev" feature)"
    _cb_tasks=""
    case "$_cb_spec" in ""|unknown) : ;; *.md) _cb_tasks="$(dirname "$_cb_spec")/tasks.md" ;; *) _cb_tasks="${_cb_spec%/}/tasks.md" ;; esac
    # Read THIS run's own ledger — the one beside the marker being stamped (.runs/$run) — never
    # resolve_ledger, which honours $TEAM_BOOTSTRAP_RUN and could point at a different run than the
    # path-derived $run this arm is writing (a real skew: the harness exports the active run id).
    _cb_led=".runs/$run/batches.jsonl"
    _cb_hascode=0
    [ -f "$_cb_led" ] && grep -q '"kind"[[:space:]]*:[[:space:]]*"code"' "$_cb_led" 2>/dev/null && _cb_hascode=1
    _cb_head="$(git rev-parse --short HEAD 2>/dev/null || true)"
    if [ -n "$_cb_tasks" ] && [ "$_cb_hascode" -eq 0 ] && [ -n "$_cb_head" ] \
       && git cat-file -e "HEAD:$_cb_tasks" 2>/dev/null; then
      splice_marker_fields "$marker" "code_baseline_sha=$_cb_head" 2>/dev/null || true
    fi
  fi

  _rs_note="$(resize_degraded_marker "$marker" "$tier_source" "$run")"
  if [ -n "$_rs_note" ]; then
    _emit_ctx "$(_json_esc "$_rs_note")"
    exit 0
  fi
  _emit_ctx "$_prev_ctx"
  exit 0
fi
base="$(git rev-parse --short HEAD 2>/dev/null || true)"
# Normalize the feature to the spec.md PATH check-completeness expects: a bare dir/slug gets /spec.md
# appended (a value already ending in .md is left as-is; no specs path ⇒ "unknown", the no-spec sentinel).
feat="${spec:-unknown}"
case "$feat" in unknown|*.md) : ;; *) feat="${feat%/}/spec.md" ;; esac

# Issue #114 — keep feature.json's active_spec in agreement with THIS run's feature. The speckit skills
# read feature.json; the harness sizes off the marker. When they disagree, the producing skills operate
# against the previous milestone until someone retargets by hand. Reconcile it here (only when the run
# names a real spec dir), and remember the old value so the context sentence can name the mismatch.
ftgt_was=""
case "$feat" in unknown|"") : ;; *) ftgt_was="$(_retarget_feature_json "$(dirname "$feat")")" ;; esac

# --- ADR-0018: is the milestone already ON DISK? -----------------------------
# When it is, the sizing input exists NOW — before the first dispatch — and Phase A's producing steps
# have nothing left to produce. Both facts are recorded as machine facts here rather than left to
# deliver.md prose, because prose lands ~70% of the time against a hook's ~100%
# (references/enforcement.md). `spec_present` is the on-disk truth, never the operator's claim: a path
# that does not resolve is a description, and Phase A must run in full for it.
spec_present=false; spec_path=""; artifacts=""; sizing=""; spec_in_git=""
if [ -n "$spec" ] && [ -f "$feat" ]; then
  spec_present=true; spec_path="$feat"
  # Hash every present artifact at run start. WS-5 compares later: an artifact that CHANGED during a
  # Phase A that was supposed to only CHECK it means something re-drafted finished work.
  _sd="$(dirname "$feat")"
  for _a in spec.md plan.md tasks.md; do
    [ -f "$_sd/$_a" ] || continue
    _h="$( { shasum -a 256 "$_sd/$_a" 2>/dev/null || sha256sum "$_sd/$_a" 2>/dev/null; } | cut -d' ' -f1 )"
    [ -n "$_h" ] || continue
    artifacts="${artifacts:+$artifacts,}{\"file\":\"$_a\",\"sha256\":\"$_h\"}"
  done
elif [ -n "$spec" ] && [ "$feat" != unknown ]; then
  # Issue #105 — the arg names a spec PATH but the working tree does not carry it. Before concluding
  # "bare description → Mode 1", ask git: a milestone authored on a branch and not checked out exists,
  # and paying for the full producing chain against it (or forcing a manual spec move) is the cost this
  # avoids. spec_present stays false (on-disk truth — downstream has nothing to CHECK), but the git-not-
  # tree fact is recorded and stated so the operator checks it out rather than re-producing it.
  spec_in_git="$(_spec_ref_in_git "$feat")"
fi

# --- ADR-0018: resolve the tier the harness owns -----------------------------
# `auto` is deliberately NOT a recognized tier downstream, and that is safe by construction: every
# reader (check-review-ack:131, check-role-dispatch:47, delivery-stop-hook:105) exempts ONLY
# single-thread and fails CLOSED on anything else. So an unresolved tier enforces the strictest
# posture rather than opening a bypass — enforce until we know, which is the correct default. It
# persists only on the description form, where Phase A resolves it at the A->B boundary.
role_plan=""; ctx_ws=""; sizing_degraded=""; all_cats=""; all_roles=""; sel_ran=""
# _uniq_into VARNAME "item..." → append each item to the named accumulator, skipping duplicates.
_uniq_into() {
  local __n="$1" __cur __i
  eval "__cur=\"\$$__n\""
  for __i in $2; do
    case " $__cur " in *" $__i "*) : ;; *) __cur="${__cur:+$__cur }$__i" ;; esac
  done
  eval "$__n=\"\$__cur\""
}
if [ "$spec_present" = "true" ]; then
  # Per-work-stream floors (OQ-2). `paths` is a SPACE-SEPARATED STRING, not a nested array: the shipped
  # marker_list reader slices its body at the first ']', so an entry containing an array would truncate
  # the whole list. Match the parser that exists rather than widen it here.
  while IFS= read -r _l || [ -n "$_l" ]; do
    [ -n "$_l" ] || continue
    _w="$(printf '%s' "$_l" | sed -n 's/^ws=\([^	]*\).*/\1/p')"
    _t="$(printf '%s' "$_l" | sed -n 's/.*	tier=\([a-z-]*\).*/\1/p')"
    _pp="$(printf '%s' "$_l" | sed -n 's/.*	paths=\(.*\)$/\1/p')"
    _rr="$(printf '%s' "$_l" | sed -n 's/.*	roles=\([^	]*\).*/\1/p')"
    _cc="$(printf '%s' "$_l" | sed -n 's/.*	cats=\([^	]*\).*/\1/p')"
    case "$_l" in degraded=1*) sizing_degraded="unknown" ;; reason=*) [ -n "$sizing_degraded" ] && sizing_degraded="${_l#reason=}" ;; esac
    [ -n "$_w" ] && [ -n "$_t" ] || continue
    role_plan="${role_plan:+$role_plan,}{\"ws\":\"$_w\",\"tier\":\"$_t\",\"roles\":\"$_rr\",\"cats\":\"$_cc\",\"paths\":\"$_pp\"}"
    ctx_ws="${ctx_ws:+$ctx_ws; }$_w tier=$_t roles=${_rr:-unsized}"
    # Run-level union of what the work-streams found and earned. These two facts are the whole output
    # of the selector, and until now neither reached the model: the categories were computed and thrown
    # away into `reasons=`, and the composition existed only per work-stream inside the marker.
    _uniq_into all_cats "$_cc"
    _uniq_into all_roles "$_rr"
    sel_ran=1
  done <<EOF
$("$(dirname "$0")/size-from-spec.sh" --per-batch "$spec_path" 2>/dev/null || true)
EOF
fi

if [ "$tier_source" = "harness" ]; then
  pipeline="auto"
  if [ "$spec_present" = "true" ]; then
    _out="$("$(dirname "$0")/size-from-spec.sh" "$spec_path" 2>/dev/null || true)"
    # UNION, not a fallback: this runs on every harness-sized run, not only the degraded one. The
    # whole-spec pass classifies files no single work-stream owns, so it can name a category the
    # per-work-stream loop never saw. Unioning is add-only and therefore keeps the one-directional
    # discipline the whole selector is built on (ADR-0018/0020) — a second source may raise the set,
    # never shrink it. It also covers the degraded case for free, where --per-batch reports nothing.
    _uniq_into all_cats "$(risk_categories_only "$(printf '%s\n' "$_out" | sed -n 's/^reasons=//p' | head -1)")"
    _uniq_into all_roles "$(printf '%s\n' "$_out" | sed -n 's/^roles=//p' | head -1)"
    # sel_ran means the classifier CLASSIFIED, not that it produced bytes. `degraded=1
    # reason=no-tasks-md` is non-empty output and no classification at all; treating it as a run turned
    # "there was nothing to classify" into "Risk categories detected: none" — a computed result that
    # was never computed. AC-1g fixed this for the branch where the classifier is never consulted; the
    # degraded branch walked straight through it. Observed live on run 176-withgauge-platform-integration.
    case "$_out" in
      *degraded=1*) : ;;
      *) [ -n "$_out" ] && sel_ran=1 ;;
    esac
    _t="$(printf '%s\n' "$_out" | sed -n 's/^tier=//p' | head -1)"
    case "$_t" in
      single-thread|mvp|full)
        pipeline="$_t"
        sizing="$(printf '%s\n' "$_out" | sed -n 's/^reasons=//p' | head -1)"
        ;;
    esac
  fi
fi
# Write baseline_sha only when HEAD resolves. A bogus "unknown" would silently disarm the
# predate check (R-3); omitting it is honest — reachable-from-HEAD (R-2) still anchors closure.
# The tier is a DEPTH as well as a role list (the other half of ADR-0020): derive it once, here,
# where the tier has just resolved, so the marker field and the context sentence cannot disagree.
# ONE definition of the depth mapping, in delivery-lib.sh. This line used to be a second copy, and it
# drifted the moment the library learned that an unresolved tier must buy the STRICTEST depth.
_depth="$(review_depth_for_tier "$pipeline")"

# PROVENANCE. This hook rewrites the marker on every prompt, so an edit to a harness-owned field is
# erased on the next one — silently. Silently is the defect: while the edit lived, every reader saw a
# model-authored value wearing `tier_source: harness`, and when it vanished nobody learned it had been
# there. Observed on run 176-withgauge-platform-integration, where `pipeline`, `sizing_degraded` and
# `risk_categories` had all been hand-written (`sizing_degraded: resolved-in-phase-a` is a string no
# script in this repo has ever emitted).
#
# The overwrite is CORRECT and stays — a computed field belongs to the computation. What changes is
# that the replacement is STATED, naming the fields that diverged. This does not detect forgery: an
# edit that happens to match what the harness computes is invisible by construction. It closes the
# SILENCE, not the gap (the standing ADR-0006/0008 limit).
#
# Computed HERE, before the context sentence is built, so the notice is part of that sentence rather
# than patched into it afterwards.
_prov=""
if [ -f "$marker" ]; then
  _prev="$(cat "$marker" 2>/dev/null || true)"
  for _pf in pipeline sizing_degraded risk_categories assigned_roles review_depth; do
    # field_str, not a hand-rolled sed: a hand-edited marker is written by an editor or a JSON
    # serialiser and comes back as `"pipeline": "full"` WITH the space, which a `":"` pattern misses
    # entirely — the detector would then be blind to precisely the edits it exists to notice.
    _old="$(field_str "$_prev" "$_pf")"
    [ -n "$_old" ] || continue
    case "$_pf" in
      pipeline)        _new="$pipeline" ;;
      sizing_degraded) _new="$sizing_degraded" ;;
      risk_categories) _new="$all_cats" ;;
      assigned_roles)  _new="$all_roles" ;;
      review_depth)    _new="$_depth" ;;
      *)               _new="" ;;
    esac
    [ "$_old" = "$_new" ] || _prov="${_prov:+$_prov }$_pf(was:$_old)"
  done
fi

_base_f=""; [ -n "$base" ] && _base_f="\"baseline_sha\":\"$base\","
_spec_f="\"spec_present\":$spec_present,\"tier_source\":\"$tier_source\","
[ -n "$spec_in_git" ] && _spec_f="$_spec_f\"spec_in_git\":\"$spec_in_git\","
[ -n "$spec_path" ] && _spec_f="$_spec_f\"spec_path\":\"$spec_path\","
[ -n "$artifacts" ] && _spec_f="$_spec_f\"spec_artifacts\":[$artifacts],"
[ -n "$sizing" ]    && _spec_f="$_spec_f\"sizing\":\"$sizing\","
_spec_f="$_spec_f\"review_depth\":\"$_depth\","
[ -n "$role_plan" ] && _spec_f="$_spec_f\"role_plan\":[$role_plan],"
[ -n "$sizing_degraded" ] && _spec_f="$_spec_f\"sizing_degraded\":\"$sizing_degraded\","
# The selector's two outputs as first-class marker fields, so a later gate reads a recorded FACT
# instead of re-running the classifier against a window that has since moved (the record_required_roles
# precedent). Empty stays empty here; the CONTEXT states "none" explicitly — a marker field and a
# sentence have different jobs.
_spec_f="$_spec_f\"risk_categories\":\"$all_cats\",\"assigned_roles\":\"$all_roles\","
[ -n "$_prov" ] && _spec_f="$_spec_f\"provenance_overwritten\":\"$(_json_esc "$_prov")\","

# The verdict, as FACT STATEMENTS. The hooks reference is explicit that additionalContext phrased as
# out-of-band imperatives trips the prompt-injection defence — Claude then shows the text to the user
# instead of accepting it as context. So: what the harness computed, never what the model should do.
_ctx="team-bootstrap harness sizing for run $run: pipeline=$pipeline, tier_source=$tier_source, spec_present=$spec_present, marker=$marker."
_ctx="$_ctx Review depth: $_depth (the /code-review low-medium-high scale; the tier sets depth, the risk categories set composition)."
[ -n "$sizing" ]  && _ctx="$_ctx Sizing reasons: $sizing."
# The two facts the selector exists to produce, in the channel, phrased as statements (AC-1, Д2 Ф0.1).
#
# "none" and "not computed" are DIFFERENT facts and are never collapsed. Empty accumulators mean either
# "the classifier ran and this run trips no category" or "the classifier never ran" (no `## ` headings
# and an operator-chosen tier, so neither source was consulted). Printing "none" for the second case
# would report a result that was never computed — the silent degradation AC-47 removed from the sizing
# path, re-introduced on the context channel. $sel_ran is set only where classifier output was actually
# consumed, so it distinguishes them at the one place that knows.
if [ -n "$sel_ran" ]; then
  _ctx="$_ctx Risk categories detected: ${all_cats:-none}."
  _ctx="$_ctx Assigned review roles for this run: ${all_roles:-none}."
else
  # Two different facts, and the reason names which. "Not consulted" is a run the classifier never saw;
  # "could not classify" is a run it saw and degraded on. Collapsing them into one sentence sends the
  # reader looking in the wrong place — the first is a wiring question, the second an artefact one.
  if [ -n "$sizing_degraded" ]; then
    _why="the classifier ran and could not classify: $sizing_degraded"
  else
    _why="the classifier was not consulted for this run"
  fi
  _ctx="$_ctx Risk categories detected: not computed ($_why)."
  _ctx="$_ctx Assigned review roles for this run: not computed; the batch diff sizes each batch alone."
fi
[ -n "$ctx_ws" ]  && _ctx="$_ctx Per-work-stream plan: $ctx_ws."
[ -n "$_prov" ] && _ctx="$_ctx Harness-owned marker fields were overwritten with the computed values: $_prov."
# Degradation is stated, never inferred from an absent plan. An empty per-work-stream result used to be
# indistinguishable from "sized it, no floors apply"; size-from-spec now says degraded=1 + a reason, and
# the marker and the model both carry it. The batch diff remains the backstop either way.
[ -n "$sizing_degraded" ] && _ctx="$_ctx Per-work-stream sizing DEGRADED (reason: $sizing_degraded) — no work-stream floors were derived; the batch diff sizes each batch alone."
[ "$tier_source" = "harness" ] && [ "$pipeline" = "auto" ] && \
  _ctx="$_ctx The tier is unresolved on disk, so every tier-reading gate fails closed until Phase A resolves it."
# Issue #105 — git-not-tree spec: state it as a FACT so the operator checks the milestone out instead of
# re-producing it. spec_present is still false (the tree has nothing to check), so this run is Mode 1
# UNLESS the spec is checked out; the sentence says which and how.
[ -n "$spec_in_git" ] && \
  _ctx="$_ctx The spec '$feat' is NOT in the working tree but EXISTS in git (ref: $spec_in_git); this run is classified as a description (spec_present=false) only because the tree lacks it. If the milestone already exists, check it out (git checkout $spec_in_git -- $feat) before Phase A rather than re-producing it."
# Issue #114 — feature.json was pointed at a different milestone than this run; it was reconciled.
[ -n "$ftgt_was" ] && \
  _ctx="$_ctx feature.json.active_spec was retargeted from '$ftgt_was' to '$(dirname "$feat")' to match this run's feature — the speckit skills read feature.json and would otherwise have driven the previous milestone."
_ctx_esc="$(_json_esc "$_ctx")"
_spec_f="$_spec_f\"harness_context\":\"$_ctx_esc\","

printf '{"run":"%s","pipeline":"%s","source":"harness","feature":"%s","intends_code":true,%s%s"precond":{"exit":0,"items":[],"ack":false}}\n' \
  "$run" "$pipeline" "$feat" "$_base_f" "$_spec_f" > "$marker" 2>/dev/null || true
# issue #117 — durability. Drop a sibling RUN.bak at ARM time too, so even a run that has taken no
# ack/waiver update yet (whose marker was never rewritten through delivery-lib's _marker_write) is
# recoverable by `marker.sh restore` if an external `.runs` cleanup deletes RUN. Best-effort and additive:
# a backup failure never blocks the arm (the marker is the source of truth, the .bak only its recovery copy).
cp "$marker" "$marker.bak" 2>/dev/null || true
_emit_ctx "$_ctx_esc"
exit 0
