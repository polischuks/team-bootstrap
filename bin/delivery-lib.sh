#!/usr/bin/env bash
# shellcheck shell=bash
# delivery-lib.sh — shared helpers for the delivery-occurred gate, the batch
# stamper, and the delivery-aware Stop hook. Sourced, never executed.
#
# One definition of: ledger/marker resolution, the compact-JSONL field extractors,
# SHA resolution, the risk_rank enum, and — critically — the non-doc code delta.
# check-delivery.sh RECOMPUTES the delta to verify a stamp; verify-batch.sh COMPUTES
# it to write the stamp. They share THIS function so recompute and stamp cannot
# diverge (spec R1): a batch verify-batch stamps will, by construction, pass the
# check-delivery recompute. Sourcing has no side effects.

# resolve_ledger — echo the active batch ledger path (or empty).
#   If $TEAM_BOOTSTRAP_RUN names a run, resolve to THAT run only (empty if it has no
#   ledger yet) — a named run means that run, not "whatever's newest", and this keeps
#   a self-test run isolated from any real ledger in the tree. Unset => newest.
# _newest_run_file SUFFIX — echo the newest .runs/*/SUFFIX by mtime, GLOB-INDEPENDENT (harness-robustness
# WS-1). A caller running under `set -f` (delivery-stop-hook.sh sets noglob around its untrusted
# closed_ids loop, then calls reviewer_dispatch_count→resolve_marker) would otherwise leave `.runs/*/RUN`
# UNexpanded → `ls` matches nothing → empty marker → the reviewer floor falsely reads "not met" and the
# Stop-hook false-blocks in a loop. Enable globbing locally and restore the caller's prior -f state
# (all call sites are `$(resolve_*)` command-subs, so this cannot leak — the restore is belt-and-braces).
# `ls -t` preserves newest-by-mtime selection (a `find`-based scan would return directory order).
_newest_run_file() {
  local _had_noglob=0; case $- in *f*) _had_noglob=1 ;; esac
  set +f
  ls -t .runs/*/"$1" 2>/dev/null | head -1 || true
  [ "$_had_noglob" -eq 1 ] && set -f
  return 0
}
# _active_run_id → the id of the ACTIVE run, or empty. ONE selection rule, used by BOTH resolvers so
# the marker and the ledger can never name two different runs (issue #20: they were resolved
# independently, so a stale sibling could win one race and not the other — every gate reading both
# then reasoned about run A's marker with run B's ledger). Precedence:
#   1. $TEAM_BOOTSTRAP_RUN — an explicit pin means THAT run, always.
#   2. .runs/current — the pointer delivery-marker-init writes when it arms a run. EXPLICIT BEATS
#      MTIME: a finished sibling whose RUN merely gets touched can no longer hijack selection.
#   3. newest .runs/*/RUN by mtime — legacy fallback for runs armed before the pointer existed.
# Deliberately NOT fail-closed on ambiguity: this is on the hot path of every gate and the Stop hook,
# so refusing to resolve would manufacture a NEW false-block class — the exact failure mode
# harness-robustness (ADR-0015) removed. Ambiguity degrades to the legacy rule, never to empty.
# STICKINESS (accepted residual): the pointer is explicit, so it does NOT self-correct the way mtime did
# — if a stray prompt arms the wrong run mid-flight, that pointer holds for the session. Recovery is
# re-arming the intended run, `rm .runs/current`, or pinning $TEAM_BOOTSTRAP_RUN. The failure direction
# is fail-CLOSED (the Stop hook still blocks), never a silent pass.
_active_run_id() {
  local id
  if [ -n "${TEAM_BOOTSTRAP_RUN:-}" ]; then printf '%s' "$TEAM_BOOTSTRAP_RUN"; return 0; fi
  if [ -f .runs/current ]; then
    # `read` (not head|tr): fork-free and `set -e`-safe — a pipeline whose status is 1 on an
    # unreadable pointer must never abort a future -e caller into an EMPTY marker.
    id=""; read -r id < .runs/current 2>/dev/null || id=""
    id="${id//[[:space:]]/}"
    # Confine to a plain run id. A pointer like `..` (a prompt containing `specs/..`) would otherwise
    # escape `.runs/` — resolving a marker outside the gitignored tree, where the tracked-.runs
    # preflight remediation does not apply and the run-id regexes cannot extract an id. Rejected
    # values FALL THROUGH to the mtime rule (same as a dangling pointer), never to empty.
    case "$id" in ''|.|..|*/*|*[!A-Za-z0-9._-]*) id="" ;; esac
    # A DANGLING pointer (its run was removed/archived) must not resolve to empty — fall through.
    [ -n "$id" ] && [ -f ".runs/$id/RUN" ] && { printf '%s' "$id"; return 0; }
  fi
  id="$(_newest_run_file RUN)"        # .runs/<id>/RUN → <id>
  id="${id#.runs/}"; id="${id%/RUN}"
  printf '%s' "$id"
}

resolve_ledger() {
  local id; id="$(_active_run_id)"
  if [ -n "$id" ]; then
    [ -f ".runs/$id/batches.jsonl" ] && printf '%s' ".runs/$id/batches.jsonl"
    return 0
  fi
  # No run resolves at all (no RUN anywhere) — legacy behaviour: a ledger left behind by a run whose
  # marker was removed is still findable. Nothing is gated on it (every gate is marker-gated).
  _newest_run_file batches.jsonl
}

# resolve_marker — echo the active RUN marker path (or empty). Same run-scoping rule.
resolve_marker() {
  local id; id="$(_active_run_id)"
  [ -n "$id" ] || return 0
  [ -f ".runs/$id/RUN" ] && printf '%s' ".runs/$id/RUN"
  return 0
}

# Compact-or-spaced JSON field extractors. The `[[:space:]]*` after each colon is load-bearing:
# without it, a marker written with `": "` (e.g. python json.dumps' default) parses as EMPTY, so
# field_bool intends_code returns false and every fail-closed gate SILENTLY skips — the guard turns
# off with no error. Accept both compact and spaced forms (Postel's law).
# field_str LINE KEY  → "key": "value"  string value
field_str() { printf '%s' "$1" | grep -oE "\"$2\":[[:space:]]*\"[^\"]*\"" | head -1 | sed -E "s/\"$2\":[[:space:]]*\"([^\"]*)\"/\1/"; }
# field_num LINE KEY  → "key": <int>    integer value
field_num() { printf '%s' "$1" | grep -oE "\"$2\":[[:space:]]*-?[0-9]+" | head -1 | sed -E "s/\"$2\":[[:space:]]*//"; }
# field_bool LINE KEY → "key": true|false
field_bool() { printf '%s' "$1" | grep -oE "\"$2\":[[:space:]]*(true|false)" | head -1 | sed -E "s/\"$2\":[[:space:]]*//"; }

# extract every commit_sha from a ledger line as space-separated tokens (compact or spaced).
shas_of_line() {
  printf '%s' "$1" | grep -oE "\"commit_shas\":[[:space:]]*\[[^]]*\]" | head -1 \
    | grep -oE '"[0-9a-fA-F]+"' | tr -d '"' | tr '\n' ' '
}

# --- review-loop escalation (issue #22) ----------------------------------------
# Every gate in this plugin is CLOSURE-time, so the SHAPE of the review effort is invisible: a run can
# spend six architecture-review rounds in Phase A with zero closed batches, or sink 16 dispatches into
# one batch while a sibling closed on 4, and nothing notices until a human reads dispatch.jsonl.
#
# Three predicates over data already recorded. Each fires at most once and is NON-BLOCKING — blocking a
# dispatch would push the orchestrator to review INLINE, which is the spec-169 collapse that got
# attempt-budget-protocol rejected. Reporting IS the intervention.
#
# Thresholds are chosen against the healthy baseline actually observed (a batch closing on ONE full
# four-role fan-out = 4 dispatches):
#   P1  >=3 dispatches of ONE role while zero kind:code batches have closed   (the Phase-A loop)
#   P2  >=8 review dispatches on a single UNCLOSED batch  (= two full fan-outs: find → fix → re-verify
#       already happened once in full)
#   P3  total/closed > 8 once >=2 closures exist          (the aggregate P1 and P2 both miss: N batches
#       each costing a "healthy-looking" amount never trips a per-subject threshold)
# P3 is a RATIO, not a raw total: a large milestone legitimately has many batches, so punishing scale
# would be wrong — what matters is whether each closure costs more than it should.
_RL_P1_MIN=3; _RL_P2_MIN=8; _RL_RATIO_MAX=8; _RL_PER_DISPATCH="3.6-11.8 min"

review_loop_signals() {
  local ledger disp line l bid total=0 closed=0 role mk marker
  marker="$(resolve_marker)"; [ -n "$marker" ] && [ -f "$marker" ] || return 0
  disp="$(dirname "$marker")/dispatch.jsonl"
  [ -f "$disp" ] || return 0
  # Glob-free from here on: batch ids come from the ledger (`field_str`'s [^"]* capture), so an id like
  # `*` would otherwise expand against the CWD and make the advisory name FILES, and `B[1` / `-v` would
  # leak raw grep errors into operator-facing output (review MEDIUM-LOW). Same guard _newest_run_file uses.
  local _had_noglob=0; case $- in *f*) _had_noglob=1 ;; esac
  set -f
  ledger="$(resolve_ledger)"

  # closed code batches + the set of ids the ledger knows (records naming an unknown id are tolerated:
  # the #20 split-brain mis-stamped Phase-A reviews onto a FOREIGN batch id, and historical runs still
  # carry those, so the counter must not be surprised by them).
  local closed_ids="" open_ids=""
  if [ -n "$ledger" ] && [ -f "$ledger" ]; then
    while IFS= read -r l || [ -n "$l" ]; do
      [ -n "$l" ] || continue
      [ "$(field_str "$l" kind)" = "code" ] || continue
      bid="$(field_str "$l" id)"; [ -n "$bid" ] || continue
      case "$(field_str "$l" status)" in
        closed) closed=$((closed + 1)); closed_ids="$closed_ids $bid" ;;
        *)      open_ids="$open_ids $bid" ;;
      esac
    done < "$ledger"
  fi

  # tally review dispatches: total, per batch, per role
  local per_batch="" per_role="" stype r b
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    stype="$(field_str "$line" subagent_type)"
    is_review_type "$stype" || continue
    total=$((total + 1))
    r="$(role_of_slug "$stype")"; [ -n "$r" ] || r="$stype"
    per_role="$per_role $r"
    b="$(field_str "$line" batch)"; [ -n "$b" ] && per_batch="$per_batch $b"
  done < "$disp"
  [ "$total" -gt 0 ] || { [ "$_had_noglob" -eq 1 ] || set +f; return 0; }

  # --- P1: one role re-run while NOTHING has closed ---------------------------
  # Only for a run that intends to ship CODE. A doc-only run legitimately closes no code batch, and
  # telling it to "ship a batch" is advice it cannot act on (review MEDIUM-1).
  mk="$(cat "$marker" 2>/dev/null || true)"
  if [ "$closed" -eq 0 ] && [ "$(field_bool "$mk" intends_code)" = "true" ]; then
    for role in $(printf '%s\n' $per_role | sort -u); do
      local n; n="$(printf '%s\n' $per_role | grep -cxF -e "$role" || true)"
      if [ "${n:-0}" -ge "$_RL_P1_MIN" ]; then
        echo "review-loop: '$role' has run ${n}x with ZERO closed code batches. Each dispatch is a full subagent (~${_RL_PER_DISPATCH}). Reviews find gaps because that is what they are asked to do — ship a batch, or scope the next review to the remediation diff. (advisory, #22)"
      fi
    done
  fi

  # --- P2: a single UNCLOSED batch absorbing two full fan-outs ----------------
  for bid in $open_ids; do
    local nb; nb="$(printf '%s\n' $per_batch | grep -cxF -e "$bid" || true)"
    if [ "${nb:-0}" -ge "$_RL_P2_MIN" ]; then
      echo "review-loop: batch '$bid' has taken ${nb} review dispatches and is STILL OPEN (unclosed) — two full four-role fan-outs' worth. Close it and file the remainder, or re-review only the fix diff. (advisory, #22)"
    fi
  done

  # --- P3: the aggregate both of the above miss -------------------------------
  if [ "$closed" -ge 2 ]; then
    local ratio; ratio=$(( total / closed ))
    if [ "$ratio" -gt "$_RL_RATIO_MAX" ]; then
      echo "review-loop: this run has spent ${total} review dispatches across ${closed} closed batches (~${ratio} per closure; a healthy full fan-out is 4). At this rate the remaining batches cost hours. Scope re-reviews to the remediation diff, or split the batch. (advisory, #22)"
    fi
  fi
  [ "$_had_noglob" -eq 1 ] || set +f
  return 0
}

# --- harness-owned role sizing (issue #27) -------------------------------------
# required_roles_for_batch BATCH_ID → the review roles THIS batch needs, space-separated (empty for a
# doc batch). The harness decides; the operator no longer picks one tier for the whole run before any
# batch exists. The tier comes from select-pipeline --batch, so the size/risk classifier has ONE
# definition and cannot drift (the same discipline current_batch_base enforces for the diff window).
#
# Mapping (OQ-2): full ⇒ all four roles · mvp ⇒ code-reviewer + integration-verifier · single-thread ⇒
# code-reviewer alone. Role names are the ATTRIBUTED roles (review-types.txt column 2), the vocabulary
# roles_covered already speaks.
#
# INVARIANT: every code batch keeps at least `code-reviewer`. The ≥1 independent-reviewer floor is the
# anti-collapse guarantee (exec-role-integrity) and is never sized away, whatever the tier says.
# Sizing governs roles 2–4 only. A kind:doc batch is the one case with no review role at all.
# _tier_rank TIER → 1 single-thread · 2 mvp · 3 full · empty otherwise.
_tier_rank() { case "$1" in single-thread) printf 1 ;; mvp) printf 2 ;; full) printf 3 ;; *) : ;; esac; }

# spec_plan_tier_for_batch BATCH_ID → the tier the SPEC planned for the work-stream this batch belongs
# to (empty when there is no plan, no match, or nothing to match on).
#
# ADR-0018. The plan is a template keyed by work-stream, not by batch id, because the orchestrator may
# batch across phase boundaries and the harness cannot force its control flow (ADR-0006/0008) — only
# observe it. So a batch is attributed at read time by PATH OVERLAP with each planned work-stream, and
# the best-overlapping entry supplies the floor. No overlap ⇒ no floor, and the diff decides alone;
# that is the fail-SAFE direction, since the floor can only ever raise the role set.
spec_plan_tier_for_batch() {
  local bid="$1" list rest idx body ws tier wp wr bpaths best_t="" best_r="" best_n=0 n f
  list="$(marker_list role_plan)"
  [ -n "$list" ] || return 0
  bpaths="$(_batch_paths "$bid")"
  [ -n "$bpaths" ] || return 0
  rest="${list#[}"
  while [ -n "$rest" ]; do
    case "$rest" in \{*) : ;; *) break ;; esac
    rest="${rest#\{}"
    idx="$(_obj_span "$rest")"
    [ -n "$idx" ] || break
    body="{${rest:0:idx}}"
    rest="${rest:idx+1}"; rest="${rest#,}"
    ws="$(field_str "$body" ws)"; tier="$(field_str "$body" tier)"; wp="$(field_str "$body" paths)"
    wr="$(field_str "$body" roles)"
    [ -n "$tier" ] && [ -n "$wp" ] || continue
    n=0
    for f in $bpaths; do
      case " $wp " in *" $f "*) n=$((n + 1)) ;; esac
    done
    if [ "$n" -gt "$best_n" ]; then best_n="$n"; best_t="$tier"; best_r="$wr"; fi
  done
  # tier<TAB>roles — the caller lifts the tier and UNIONS the roles.
  [ "$best_n" -gt 0 ] && printf '%s\t%s' "$best_t" "$best_r"
  return 0
}

# _batch_paths BATCH_ID → the paths this batch's own window touches. Same window definition
# select-pipeline's _batch_numstat uses: recorded commit_shas when present, else current_batch_base.
_batch_paths() {
  local bid="$1" ledger line shas base c
  ledger="$(resolve_ledger)"; [ -n "$ledger" ] && [ -f "$ledger" ] || return 0
  line=""
  while IFS= read -r c || [ -n "$c" ]; do
    [ -n "$c" ] || continue
    [ "$(field_str "$c" id)" = "$bid" ] && line="$c"
  done < "$ledger"
  [ -n "$line" ] || return 0
  shas="$(shas_of_line "$line")"
  if [ -n "$shas" ]; then
    for c in $shas; do git diff --name-only "$c^" "$c" 2>/dev/null; done | sort -u
  else
    base="$(current_batch_base)"
    [ -n "$base" ] && git diff --name-only "$base" HEAD 2>/dev/null | sort -u
  fi
}

# review_depth_for_tier TIER → the /code-review level the tier buys: low | medium | high.
#
# ADR-0020 split composition from depth and only delivered the composition half — the tier stopped
# deciding WHO reviews, and nothing then consumed it as HOW DEEPLY. That left the tier a role list
# with a smaller list, which is not the split that was claimed. This is the other half: the tier is a
# number on the /code-review scale, and it is stated to the model and to each dispatched role.
#
# `ultra` is deliberately unreachable here: it is user-triggered and billed, and a harness that could
# spend it without being asked would be exactly the unbounded autonomy P1 rejects.
review_depth_for_tier() {
  case "$1" in
    full)          printf 'high' ;;
    mvp)           printf 'medium' ;;
    single-thread) printf 'low' ;;
    # UNRESOLVED ⇒ STRICTEST, not shallowest. `auto`, empty, or a word this scale does not know means
    # the harness cannot say how much review the change needs, and the safe answer to that is all of
    # it. This branch used to answer `low` — so a marker could state, in the same breath, "every
    # tier-reading gate fails closed until Phase A resolves it" AND "Review depth: low", telling the
    # gates to enforce maximally and the model to review minimally. Observed live on run
    # 176-withgauge-platform-integration. Same rule tier_base_roles already follows (AC-13).
    *)             printf 'high' ;;
  esac
}

# tier_base_roles TIER → the review roles the tier's DEPTH earns, before any risk category is added.
#
# SINGLE DEFINITION (AC-14, Д2 §1.1). This mapping used to exist twice — here, inside
# required_roles_for_batch, and again as `_roles_for` in size-from-spec.sh, which carried the comment
# "Mirrors delivery-lib's required_roles_for_batch mapping exactly". Two copies of one mapping is a
# drift waiting to happen, and Д2 §1.1 names this exact pair as the precedent for why an agent file
# must not restate its playbook. size-from-spec.sh now sources this file and calls this function.
#
# The list itself comes from `profiles/default.map` (AC-13), not from a case here: ADR-0020 moved the
# risk categories to the profile and left the tier base hardcoded, which is the same "the tier decides
# who reviews" the split was meant to end. `profile_map_path` is defined further down; bash resolves
# calls at call time, so the ordering is fine.
tier_base_roles() {
  local tier="$1" map line roles
  map="$(profile_map_path)"
  if [ -n "$map" ] && [ -f "$map" ]; then
    # `$tier` reaches here from select-pipeline's own `[a-z-]*` capture, so it carries no regex
    # metacharacters; the anchor and the trailing space class are what keep `tier:mvp` from matching a
    # hypothetical `tier:mvp-strict`.
    line="$(grep -E "^tier:${tier}[[:space:]]" "$map" 2>/dev/null | head -1)"
    if [ -n "$line" ]; then
      # Squeeze the value before testing it: a `tier:full` line with nothing but whitespace after it is
      # an ANSWERLESS key, and treating it as an answer would hand back a blank base — the silent empty
      # set the fallback below exists to prevent. `[ -n "$roles" ]` alone would call "   " an answer.
      roles="$(printf '%s' "$line" | sed -E 's/^tier:[^[:space:]]*[[:space:]]+//' \
               | tr '\t' ' ' | sed -E 's/^ +//; s/ +$//; s/  +/ /g')"
      [ -n "$roles" ] && { printf '%s' "$roles"; return 0; }
    fi
  fi
  # FAIL CLOSED, STRICTEST. No profile, no `tier:` key for this tier, or an empty one: the harness
  # cannot say what this tier's base is, and the safe answer to "I do not know how much review this
  # needs" is ALL of it, never the least of it. Same posture delivery-marker-init.sh takes on an
  # unresolved tier (pipeline=auto: every tier-reading gate fails closed until Phase A resolves it).
  # Returning the lightest base here would turn a missing config line into a silent bypass.
  printf 'integration-verifier architecture-reviewer regression-guardian code-reviewer'
}

# risk_categories_only "REASON..." → just the RISK CATEGORIES out of a select-pipeline `reasons` list.
#
# `reasons` mixes two kinds of token: size reasons (files>=3, lines>=150, layers>=2, docs-only) and risk
# categories. Only the second kind routes a role or belongs in the "risk categories detected" statement
# — telling the model that `docs-only` is a risk category would be false, and a false fact in the
# context channel is worse than a missing one. The vocabulary comes from `select-pipeline.sh
# --categories`, which publishes it beside the code that emits it.
_RISK_VOCAB=""
risk_categories_only() {
  local here_ vocab tok out=""
  [ -n "$1" ] || return 0
  # Cached for the life of the process: the vocabulary is a constant, and this is called once per
  # work-stream. A spawn per call would make the honest-categories fix cost more than the fact is
  # worth (ADR-0016).
  if [ -z "$_RISK_VOCAB" ]; then
    here_="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _RISK_VOCAB="$("$here_/select-pipeline.sh" --categories 2>/dev/null || true)"
  fi
  vocab="$_RISK_VOCAB"
  [ -n "$vocab" ] || return 0
  for tok in $1; do
    case " $vocab " in *" $tok "*) : ;; *) continue ;; esac
    case " $out " in *" $tok "*) : ;; *) out="$out $tok" ;; esac
  done
  printf '%s' "${out# }"
}

# roles_for_categories "CAT..." → the roles those risk categories earn under the active profile.
#
# Split out of profile_roles_for_batch so the SAME mapping serves both callers: the batch path (which
# gets its categories from the diff) and the spec path (which gets them from a work-stream's declared
# file list). Before this split the spec path had no access to the profile at all, so the harness could
# state a role plan at run start that no profile had ever been consulted about.
roles_for_categories() {
  local cats="$1" map cat roles r out="" tok
  map="$(profile_map_path)"; [ -n "$map" ] && [ -f "$map" ] || return 0
  [ -n "$cats" ] || return 0
  for tok in $cats; do
    while read -r cat roles; do
      # `tier:<name>` is the depth base set (AC-13), a different record kind in the same file. It can
      # never match a classifier token, so skipping it is defensive rather than load-bearing — but the
      # skip is explicit so a future category named `tier-something` cannot half-match by accident.
      case "$cat" in ''|'#'*|tier:*) continue ;; esac
      [ "$cat" = "$tok" ] || continue
      for r in $roles; do
        case " $out " in *" $r "*) : ;; *) out="$out $r" ;; esac
      done
    done < "$map"
  done
  printf '%s' "${out# }"
}

# profile_map_path → the active strictness profile. $TEAM_BOOTSTRAP_PROFILE overrides the shipped one,
# which is how an organisation supplies its own mapping without touching the core (the Spec Kit preset
# model: a preset overrides rules, it never adds capability). Empty when neither is readable.
profile_map_path() {
  local p
  if [ -n "${TEAM_BOOTSTRAP_PROFILE:-}" ]; then
    [ -f "$TEAM_BOOTSTRAP_PROFILE" ] && { printf '%s' "$TEAM_BOOTSTRAP_PROFILE"; return 0; }
    return 0                                        # named but unreadable ⇒ no map, never a silent default
  fi
  p="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/profiles/default.map"
  [ -f "$p" ] && printf '%s' "$p"
}

# profile_roles_for_batch BATCH_ID → roles the batch's RISK CATEGORIES earn, per the active profile.
# The categories come from select-pipeline.sh's own `(reasons: …)` line — the same computation that sizes
# the tier, so composition and depth cannot disagree about what the diff contains.
profile_roles_for_batch() {
  local bid="$1" map here_ reasons
  map="$(profile_map_path)"; [ -n "$map" ] && [ -f "$map" ] || return 0
  here_="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  reasons="$("$here_/select-pipeline.sh" --batch "$bid" 2>/dev/null \
    | sed -nE 's/.*\(reasons: (.*)\)$/\1/p' | tail -1)"
  [ -n "$reasons" ] || return 0
  roles_for_categories "$reasons"
}

required_roles_for_batch() {
  local bid="$1" ledger line l kind tier here_
  ledger="$(resolve_ledger)"; [ -n "$ledger" ] && [ -f "$ledger" ] || return 0
  line=""
  # `|| [ -n "$l" ]` is load-bearing: a final line with NO trailing newline is otherwise dropped, and a
  # freshly-announced entry (authored by the orchestrator) is exactly that. Dropping it made a kind:code
  # batch resolve to an EMPTY set — the >=1 anti-collapse floor evaporating in silence (review CRITICAL).
  while IFS= read -r l || [ -n "$l" ]; do
    [ -n "$l" ] || continue
    [ "$(field_str "$l" id)" = "$bid" ] && line="$l"
  done < "$ledger"
  # Unresolvable ⇒ fail SAFE, not open. Empty is the doc-batch answer, so returning it for a line we
  # simply could not find would tell a close gate that a real code batch needs NO reviewer. Mirrors the
  # declared-but-unresolvable precedent select-pipeline set (review HIGH).
  [ -n "$line" ] || { printf 'code-reviewer'; return 0; }
  kind="$(field_str "$line" kind)"
  [ "$kind" = "doc" ] && return 0                     # docs earn no review fan-out
  here_="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  tier="$("$here_/select-pipeline.sh" --batch "$bid" 2>/dev/null | sed -nE 's/.*RECOMMENDED pipeline: ([a-z-]+).*/\1/p' | tail -1)"
  # ADR-0018 — the spec-planned tier is a FLOOR the diff may LIFT but never lower. One-directional on
  # purpose: text-sourced sizing can under-state a risk the spec never names as a path (R2), so the
  # diff stays the backstop; and a plan that over-states can only cost review, never skip it.
  local plan ptier proles prank drank base r out=""
  plan="$(spec_plan_tier_for_batch "$bid" 2>/dev/null || true)"
  ptier="$(printf '%s' "$plan" | cut -f1)"; proles="$(printf '%s' "$plan" | cut -f2)"
  if [ -n "$ptier" ]; then
    prank="$(_tier_rank "$ptier")"; drank="$(_tier_rank "$tier")"
    [ -n "$prank" ] && [ "$prank" -gt "${drank:-0}" ] && tier="$ptier"
  fi
  # Model judgement (bin/judge-tier.sh) applies with the SAME one-directional discipline and for the
  # same reason: the path classifier is blind to what a milestone DOES, and a judgement that could lower
  # the tier would turn a blind spot into a bypass. It may raise; it may never lower. Absent, unreadable
  # or unrecognised ⇒ no effect whatsoever.
  local jtier jrank jf
  jf="$(dirname "$(resolve_marker 2>/dev/null || true)")/tier-judgment"
  if [ -f "$jf" ]; then
    jtier="$(sed -n 's/^tier=//p' "$jf" 2>/dev/null | head -1)"
    case "$jtier" in
      single-thread|mvp|full)
        jrank="$(_tier_rank "$jtier")"; drank="$(_tier_rank "$tier")"
        [ -n "$jrank" ] && [ "$jrank" -gt "${drank:-0}" ] && tier="$jtier" ;;
      *) : ;;                                   # unrecognised ⇒ ignored, never a guess
    esac
  fi
  base="$(tier_base_roles "$tier")"
  # roles-alive phase 2 — the tier decides DEPTH; the risk CATEGORIES decide composition. The classifier
  # already computes five (security/auth, data/schema, infra/deploy, api/contract, deps) and used to
  # discard them into `reasons=`: a ready routing signal with no addressee, which is why 47 of 51 roles
  # were unreachable. profiles/default.map gives them one. ADD-ONLY by construction — the map is unioned
  # into $base below, so a profile can never shrink a set the paths already earned, and the >=1
  # anti-collapse floor is never sized away. Absent/unreadable map ⇒ exactly the previous behaviour.
  local cats crole
  cats="$(profile_roles_for_batch "$bid" 2>/dev/null || true)"
  for crole in $cats; do
    case " $base " in *" $crole "*) : ;; *) base="$base $crole" ;; esac
  done
  # ADR-0019 — roles the task author DECLARED with `⚠ <role>` are unioned in, never subtracted. Same
  # trust model as the ledger's self-declared risk_rank (ADR-0006): forgeable, therefore permitted to
  # raise the requirement and never to lower it. Declaring `⚠ code-reviewer` on an auth batch cannot
  # shrink the full set the paths already earned.
  for r in $base $proles; do
    case " $out " in *" $r "*) : ;; *) out="$out $r" ;; esac
  done
  # F4 / AC-18 — the >=1 independent-reviewer floor, asserted HERE, after every configurable source has
  # had its say. It is not negotiable by profile, by judgement or by declaration.
  #
  # This became load-bearing the moment AC-13 moved the tier base into profiles/*.map. Until then the
  # floor held by ACCIDENT: every branch of the hardcoded case happened to contain code-reviewer, so no
  # code ever had to enforce it. An organisation shipping `tier:full  integration-verifier` would have
  # sized the anti-collapse floor away — silently, and on the strictest tier. A floor that depends on
  # every future config file remembering to include it is not a floor.
  case " $out " in
    *" code-reviewer "*) : ;;
    *) out="$out code-reviewer" ;;
  esac
  printf '%s' "${out# }"
}

# json_esc TEXT → TEXT safe inside a JSON string. Control characters are DROPPED rather than escaped:
# additionalContext is a one-line fact statement, so an embedded newline is a defect, not content.
json_esc() {
  printf '%s' "$1" | tr -d '\000-\037' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# emit_hook_context EVENT ESCAPED_TEXT → one line of hook stdout on the sanctioned context channel.
# ESCAPED_TEXT must already be json_esc'd. Empty text emits nothing at all.
#
# OVER THE CEILING: SPILL, NEVER CUT (AC-3). The documented ceiling is 10 000 characters, and the
# documented over-limit path is "write to a file and pass the path". This used to `cut -c1-9000` and
# emit the head — a silent truncation, which is the precise failure P10 refuses: the tail of a verdict
# vanished with no reason recorded, and nothing downstream could tell a short verdict from a cut one.
# Now the whole text lands in .runs/<id>/context.txt and the emission states the path, so the decision
# is never lost — only relocated, and the model is told where.
#
# The trailing-lone-backslash trim stays: a cut landing inside an escape pair would leave a dangling
# `\` and break the JSON. It now only ever applies to the summary line, which is built here.
emit_hook_context() {
  local ev="$1" t="$2" id dir spill head_
  [ -n "$t" ] || return 0
  if [ "${#t}" -gt 10000 ]; then
    id="$(_active_run_id 2>/dev/null || true)"
    dir=".runs/${id:-unknown}"
    if [ -n "$id" ] && mkdir -p "$dir" 2>/dev/null; then
      spill="$dir/context.txt"
      # json_unesc: the caller handed us an ESCAPED string; the spill file holds the plain text, so a
      # human (and a Read) sees the verdict, not its JSON encoding.
      printf '%s' "$t" | sed -e 's/\\"/"/g' -e 's/\\\\/\\/g' > "$spill" 2>/dev/null || spill=""
    fi
    if [ -n "${spill:-}" ] && [ -f "$spill" ]; then
      head_="$(printf '%s' "$t" | cut -c1-8000)"
      case "$head_" in *\\\\) : ;; *\\) head_="${head_%\\}" ;; esac
      t="$head_ [context continues; the full text of this verdict is in $spill]"
    else
      # No run directory to spill into. Cutting is still wrong, so say so IN the context rather than
      # dropping the tail in silence — an honest gap, never a green-by-skip (P6, P10).
      head_="$(printf '%s' "$t" | cut -c1-8000)"
      case "$head_" in *\\\\) : ;; *\\) head_="${head_%\\}" ;; esac
      t="$head_ [context truncated: over the 10000-character ceiling and no run directory was available to spill into]"
    fi
  fi
  printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"%s"}}\n' "$ev" "$t"
}

# inflight_batch → the in-flight ledger line (last announced; else last non-empty). Single source: it
# was copy-pasted into check-role-dispatch.sh and check-review-ack.sh, and verify-batch now needs the
# same window to record the sized role set before the dispatch gate reads it.
inflight_batch() {
  local ledger line
  ledger="$(resolve_ledger)"; [ -n "$ledger" ] && [ -f "$ledger" ] || return 0
  line="$(grep '"status":[[:space:]]*"announced"' "$ledger" 2>/dev/null | tail -1)"
  [ -n "$line" ] || line="$(grep -v '^[[:space:]]*$' "$ledger" 2>/dev/null | tail -1)"
  printf '%s' "$line"
}

# splice_marker_fields MARKER "key=value" … → replace those top-level STRING fields in MARKER,
# preserving every field the caller did not name.
#
# The marker accumulates state from gates that are not the sizing hook — precond, preflight, repro_env,
# reported_blocks, the acks — which is exactly why delivery-marker-init.sh refuses to rewrite an
# existing marker wholesale. But refusing to rewrite ANYTHING froze the sizing at first-arm, when a
# description-form run has no tasks.md yet and therefore always degrades. A field-level splice is the
# missing middle: the hook updates what it owns and cannot touch what it does not.
#
# Same durability discipline as record_required_roles: temp file + mv (atomic), and the result must
# parse as JSON-shaped before it lands, so a bad splice can never corrupt a run.
splice_marker_fields() {
  local mk="$1"; shift
  [ -n "$mk" ] && [ -f "$mk" ] || return 1
  local body kv k v tmp
  body="$(cat "$mk" 2>/dev/null || true)"
  [ -n "$body" ] || return 1
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    if printf '%s' "$body" | grep -q "\"$k\"[[:space:]]*:"; then
      body="$(printf '%s' "$body" | sed "s/\"$k\"[[:space:]]*:[[:space:]]*\"[^\"]*\"/\"$k\":\"$(printf '%s' "$v" | sed 's/[&/\\]/\\&/g')\"/")"
    else
      body="$(printf '%s' "$body" | sed "s/^{/{\"$k\":\"$(printf '%s' "$v" | sed 's/[&/\\]/\\&/g')\",/")"
    fi
  done
  case "$body" in \{*\}) : ;; *) return 1 ;; esac
  tmp="$mk.tmp.$$"
  printf '%s\n' "$body" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$mk" 2>/dev/null || { rm -f "$tmp"; return 1; }
  return 0
}

# record_required_roles BATCH_ID → compute the batch's role set and splice it into ITS ledger line as
# a flat "required_roles":[…] array.
#
# CALLED FROM verify-batch.sh, AT CLOSE — not at announce (AC-25). This comment used to say "recorded
# at announce", which is the practice that milestone deliberately ended: at announce the batch window
# is still EMPTY, so the computed set collapsed to the minimum [code-reviewer] and the whole
# recorded-set branch of check-role-dispatch was unreachable in production. The set is computed where
# the diff exists. A comment describing the superseded call site is worse than none — the next reader
# trusts it.
#
# Rewrite is temp-file + mv (atomic, #25) and the line is validated as JSON-shaped before it lands,
# so a bad splice can never corrupt the ledger.
record_required_roles() {
  local bid="$1" ledger roles arr tmp line out r
  ledger="$(resolve_ledger)"; [ -n "$ledger" ] && [ -f "$ledger" ] || return 0
  roles="$(required_roles_for_batch "$bid")"
  arr="["; for r in $roles; do arr="$arr\"$r\","; done; arr="${arr%,}]"
  tmp="$ledger.tmp.$$"; : > "$tmp"
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -n "$line" ] && [ "$(field_str "$line" id)" = "$bid" ]; then
      line="$(printf '%s' "$line" | sed 's/"required_roles"[[:space:]]*:[[:space:]]*\[/"required_roles":[/')"
      out="$(_marker_strip_flat_key "$line" required_roles)"
      out="${out%\}},\"required_roles\":$arr}"
      case "$out" in \{*\}) line="$out" ;; *) : ;; esac   # bad splice ⇒ keep the original line
    fi
    printf '%s\n' "$line" >> "$tmp"
  done < "$ledger"
  mv "$tmp" "$ledger" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  return 0
}

# required_roles_recorded BATCH_ID → the roles RECORDED on the entry, or empty when the field is absent.
# Empty means "no recorded set" — callers fall back to the legacy fixed floor rather than guessing, so
# old runs and hand-written ledgers behave exactly as before.
required_roles_recorded() {
  local bid="$1" ledger line l body
  ledger="$(resolve_ledger)"; [ -n "$ledger" ] && [ -f "$ledger" ] || return 0
  while IFS= read -r l || [ -n "$l" ]; do
    [ -n "$l" ] || continue
    [ "$(field_str "$l" id)" = "$bid" ] && line="$l"
  done < "$ledger"
  [ -n "${line:-}" ] || return 0
  # Space-tolerant, like every other reader here: a spaced `"required_roles": [` used to miss the
  # pattern, after which `%%]*` truncated at the first `]` anywhere and returned the LINE PREFIX as a
  # role list (review MEDIUM). Normalise the one separator before slicing.
  line="$(printf '%s' "$line" | sed 's/"required_roles"[[:space:]]*:[[:space:]]*\[/"required_roles":[/')"
  case "$line" in *'"required_roles":['*) : ;; *) return 0 ;; esac
  body="${line#*\"required_roles\":[}"; body="${body%%]*}"
  printf '%s' "$body" | tr -d '"' | tr ',' ' '
}

# --- expensive-gate result cache (issue #23 item 1) ----------------------------
# verify-batch re-runs EVERY gate on EVERY attempt, and the first attempt usually fails on some other
# gate — so a project that honestly declares `Coverage:`/`Mutation: enforce` pays a full Stryker (and a
# second instrumented suite run) again on each retry, with a byte-identical diff. These helpers let a
# gate reuse its own previous OUTPUT when the code under test is provably unchanged.
#
# FAIL-CLOSED BY CONSTRUCTION. The key covers everything that can change the answer:
#   - the gate id and the DECLARED COMMAND string (a different tool asks a different question),
#   - the committed window `base..HEAD`,
#   - the uncommitted tracked changes `git diff HEAD` (gates run against the WORKING TREE, so caching
#     on committed state alone would be a stale-pass fail-open).
# Anything that does not resolve (no marker, not a repo, no hash) returns an EMPTY key, and an empty
# key means DO NOT CACHE — the gate executes. A cache miss costs time; a stale hit costs correctness,
# which is the ADR-0015 class of defect, so every ambiguity resolves toward re-running.
#
# UNTRACKED files are in the key too, by CONTENT. Leaving them out looked defensible ("the gates derive
# their scope from git anyway") until this repo's own check-mutation self-test proved otherwise: its
# mutation tool reads an untracked fixture file, so a changed fixture kept hitting a stale verdict. Any
# input a gate can read must be able to invalidate. Ignored paths (build scratch such as `.stryker-tmp`)
# are excluded by `git status --porcelain`, which is what keeps this affordable.
# Pathological trees (many dirty/untracked files) simply DISABLE the cache rather than pay to hash them.

_GATE_CACHE_MAX_DIRTY=200

# gate_cache_key GATE_ID CMD → a stable key, or EMPTY when caching must not happen.
gate_cache_key() {
  local gate="$1" cmd="$2" marker base st n
  marker="$(resolve_marker)"; [ -n "$marker" ] && [ -f "$marker" ] || return 0
  git rev-parse --git-dir >/dev/null 2>&1 || return 0
  base="$(field_str "$(cat "$marker" 2>/dev/null)" baseline_sha)"
  [ -n "$base" ] || return 0
  st="$(git status --porcelain 2>/dev/null)"
  n="$(printf '%s\n' "$st" | grep -c . || true)"
  [ "${n:-0}" -le "$_GATE_CACHE_MAX_DIRTY" ] || return 0   # too noisy to key honestly → do not cache
  {
    printf '%s\0%s\0' "$gate" "$cmd"
    git diff "$base"..HEAD 2>/dev/null          # committed window
    printf '\0'
    git diff HEAD 2>/dev/null                   # uncommitted TRACKED changes
    printf '\0%s\0' "$st"                       # which paths are dirty/untracked at all
    # …and the CONTENT of every dirty/untracked path, so editing any of them invalidates.
    printf '%s\n' "$st" | while IFS= read -r line; do
      [ -n "$line" ] || continue
      p="${line#???}"; p="${p##* -> }"          # strip the XY status prefix; take a rename's target
      [ -f "$p" ] && printf '%s:%s\0' "$p" "$(git hash-object "$p" 2>/dev/null)"
    done
  } | git hash-object --stdin 2>/dev/null || true
}

# _gate_cache_dir → the active run's cache directory (created on demand), or empty.
_gate_cache_dir() {
  local marker d
  marker="$(resolve_marker)"; [ -n "$marker" ] || return 0
  d="$(dirname "$marker")/gate-cache"
  mkdir -p "$d" 2>/dev/null || return 0
  printf '%s' "$d"
}

# gate_cache_get KEY → print the cached payload and return 0 on a hit; return 1 on a miss.
gate_cache_get() {
  local key="$1" d
  [ -n "$key" ] || return 1
  d="$(_gate_cache_dir)"; [ -n "$d" ] || return 1
  [ -f "$d/$key" ] || return 1
  cat "$d/$key" 2>/dev/null || return 1
}

# gate_cache_put KEY PAYLOAD → store a verdict payload. Best-effort: a write failure just means the
# next run re-executes (the safe direction), so it never fails the gate.
gate_cache_put() {
  local key="$1" payload="$2" d
  [ -n "$key" ] || return 0
  d="$(_gate_cache_dir)"; [ -n "$d" ] || return 0
  printf '%s' "$payload" > "$d/$key" 2>/dev/null || true
  return 0
}

# --- marker list fields (closure-fidelity gates A/C) ---------------------------
# One definition of the pure-bash marker-list rewrite, mirroring record_precond's surgery in
# check-preconditions.sh: NO sed — list items (gap strings, seam paths) contain '/', which would
# collide with a sed s/// delimiter, silently fail, and clobber the marker (the v2.18.1 self-disarm
# class). Operates on top-level FLAT array keys (a value with no nested '[' or ']'): enforcement_gaps
# is a flat string array; high_risk_seams / seam_acks (which carry nested arrays) are written by the
# orchestrator/human, only READ here. resolve_marker scopes to the active run.

# _marker_strip_flat_key MK KEY → MK with a top-level flat "KEY":[…] removed (one separator comma with
# it, so no ',,' '{,' or ',}' is left). Absent KEY ⇒ MK unchanged. A flat array closes at the FIRST ']'
# after "KEY":[, so the prefix/suffix expansion is exact. NO ${//} substitution — bash 5.2 does
# backslash processing in the replacement string, which leaked literal backslashes into the marker (the
# very marker-rewrite seam this milestone guards); single-char slicing is version-stable instead.
_marker_strip_flat_key() {
  local mk="$1" key="$2" before after
  case "$mk" in *"\"$key\":["*) : ;; *) printf '%s' "$mk"; return 0 ;; esac
  before="${mk%%\"$key\":[*}"     # up to (not incl) "key":[  — ends with '{' or ','
  # Trim trailing whitespace: with a SPACED separator (`, "key": […]`) `before` ends in a space, so the
  # comma checks below both miss and the caller's splice emits `, ,` — invalid JSON that the first/last
  # character shape guard cannot see. Closes the class for every flat-key caller, not just one.
  before="${before%"${before##*[![:space:]]}"}"
  after="${mk#*\"$key\":[}"       # after "key":[
  after="${after#*]}"             # drop through the first ']' (flat array): starts with ',' or '}'
  if [ "${before: -1}" = "," ]; then
    before="${before%,}"          # key not first: drop the comma that preceded it
  elif [ "${after:0:1}" = "," ]; then
    after="${after#,}"            # key first: drop the comma that followed it
  fi
  printf '%s%s' "$before" "$after"
}

# record_marker_list KEY JSON_ARRAY → insert/replace a top-level "KEY":<JSON_ARRAY> in the active RUN
# marker (JSON_ARRAY = a complete flat array literal, e.g. '["red-first","mutation"]' or '[]'). No
# marker ⇒ no-op. Preserves every other field. Validates the result is still a single {…} object
# before writing (never leave a half-written marker).
# _marker_write MARKER CONTENT → replace MARKER atomically. rename(2) inside a directory is atomic,
# so a concurrent reader sees the OLD marker or the NEW one — never the truncate window that
# `printf > "$marker"` leaves open (issue #25). 19 scripts read this file and every fail-closed gate
# keys on `field_bool intends_code`, so a partial read is a SILENT FAIL-OPEN — the gate concludes
# "no active run" and allows. The temp file MUST live beside the marker: rename is only atomic within
# one filesystem, and $TMPDIR is frequently a different mount. A failed write leaves the previous
# marker untouched, which truncate-then-write could not guarantee. Mirrors verify-batch.sh:114.
_marker_write() {
  local marker="$1" content="$2" tmp
  tmp="$marker.tmp.$$"
  printf '%s\n' "$content" > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  mv "$tmp" "$marker" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  return 0
}

record_marker_list() {
  local key="$1" arr="$2" marker mk newmk
  marker="$(resolve_marker)"
  [ -n "$marker" ] && [ -f "$marker" ] || return 0
  mk="$(cat "$marker" 2>/dev/null || true)"
  [ -n "$mk" ] || return 0
  # The value must actually BE a JSON array. The outer `\{*\}` shape check below only validates the
  # WRAPPER, so a non-array payload used to splice in verbatim and leave the marker unparseable
  # (found by the issue-#25 red test). Reject instead, leaving the marker untouched.
  case "$arr" in \[*\]) : ;; *) return 1 ;; esac
  mk="$(_marker_strip_flat_key "$mk" "$key")"
  newmk="${mk%\}}"                          # strip the final '}'
  if [ "${newmk: -1}" = "{" ]; then
    newmk="${newmk}\"${key}\":${arr}}"      # empty object: no leading comma
  else
    newmk="${newmk},\"${key}\":${arr}}"     # append the field, re-close
  fi
  case "$newmk" in
    \{*\}) _marker_write "$marker" "$newmk" || return 1 ;;
    *) return 1 ;;
  esac
}

# marker_list KEY → echo the flat JSON array body for a top-level KEY (e.g. '["a","b"]'), empty if absent.
marker_list() {
  local key="$1" marker mk body
  marker="$(resolve_marker)"
  [ -n "$marker" ] && [ -f "$marker" ] || return 0
  mk="$(cat "$marker" 2>/dev/null || true)"
  case "$mk" in *"\"$key\":["*) : ;; *) return 0 ;; esac
  body="${mk#*\"$key\":[}"; body="${body%%]*}"
  printf '[%s]' "$body"
}

# --- object-scoped marker helpers (preflight-setup gate; object analogs of the flat helpers) --------
# Two marker objects — precond and preflight — both carry scalar keys "exit"/"ack". The flat field_*
# extractors are GLOBAL first-match, so reading OR stripping either object by those bare keys is order-
# fragile. These scope to a named object's own {…} span (brace-balanced AND string-aware — a '}' or the
# literal exit/ack inside a value string does not fool the close), so the two objects coexist safely.
# See specs/preflight-setup-phase (drift catch #2): the WRITE side is load-bearing — record_precond's
# historical greedy `${mk%,"precond":*}` strip silently deleted any object written AFTER precond.

# _obj_span REST → 0-based index of the '}' closing the object whose opening '{' was already consumed
# (REST begins just inside it). Honors JSON string quoting + nested braces. Echoes the index; empty if
# unbalanced (caller treats that as fail-safe: leave the marker untouched).
_obj_span() {
  local rest="$1" n="${#1}" i=0 ch depth=1 instr=0 esc=0
  while [ "$i" -lt "$n" ]; do
    ch="${rest:i:1}"
    if [ "$instr" -eq 1 ]; then
      if [ "$esc" -eq 1 ]; then esc=0
      elif [ "$ch" = "\\" ]; then esc=1
      elif [ "$ch" = '"' ]; then instr=0
      fi
    else
      case "$ch" in
        '"') instr=1 ;;
        '{') depth=$((depth + 1)) ;;
        '}') depth=$((depth - 1)); [ "$depth" -eq 0 ] && { printf '%s' "$i"; return 0; } ;;
      esac
    fi
    i=$((i + 1))
  done
  return 0
}

# field_in_obj MK OBJECT KEY → scalar value of KEY within MK's top-level "OBJECT":{…} span (string, int,
# or bool), empty if OBJECT absent or KEY is not a scalar in it. Collision-safe read for exit/ack, which
# now appear in BOTH precond and preflight (drift #2, read side).
field_in_obj() {
  local mk="$1" obj="$2" key="$3" rest idx body v
  # WS-4 (harness-robustness): tolerate whitespace/newlines between `"obj":` and `{` — a pretty-printer
  # (python json.dump(indent=2)) writes `"obj": {\n …`, not the compact `"obj":{`. Match the key, strip
  # everything up to its colon, ltrim whitespace (incl. newlines), then require an opening brace. Without
  # this, nested reads (precond/preflight/enforcement — all read via field_in_obj) false-skip on a pretty
  # marker, turning fail-closed gates OFF silently.
  case "$mk" in *"\"$obj\":"*) : ;; *) return 0 ;; esac
  rest="${mk#*\"$obj\":}"
  rest="${rest#"${rest%%[![:space:]]*}"}"   # ltrim leading whitespace/newlines
  case "$rest" in \{*) : ;; *) return 0 ;; esac   # the value must be an object
  rest="${rest#\{}"
  idx="$(_obj_span "$rest")"
  [ -n "$idx" ] || return 0
  body="{${rest:0:idx}}"
  v="$(field_str "$body" "$key")"; [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  v="$(field_num "$body" "$key")"; [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  v="$(field_bool "$body" "$key")"; [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  return 0
}

# _marker_strip_obj_key MK KEY → MK with the top-level "KEY":{…} object removed (with one separator
# comma, so no ',,' '{,' or ',}' remains). POSITION-INDEPENDENT (unlike a `%`-suffix strip): the span is
# found brace-balanced/string-aware, so an object written after KEY is never over-stripped. Absent KEY ⇒
# MK unchanged. Object analog of _marker_strip_flat_key; the write-side fix for the record_precond
# self-disarm (drift #2). NO sed.
_marker_strip_obj_key() {
  local mk="$1" key="$2" before rest idx after
  case "$mk" in *"\"$key\":{"*) : ;; *) printf '%s' "$mk"; return 0 ;; esac
  before="${mk%%\"$key\":\{*}"    # up to (not incl) "key":{  — ends with '{' or ','
  rest="${mk#*\"$key\":\{}"       # just inside the object
  idx="$(_obj_span "$rest")"
  [ -n "$idx" ] || { printf '%s' "$mk"; return 0; }   # unbalanced: fail-safe, leave untouched
  after="${rest:$((idx + 1))}"    # after the closing '}': starts with ',' or '}'
  if [ "${before: -1}" = "," ]; then
    before="${before%,}"          # key not first: drop the preceding comma
  elif [ "${after:0:1}" = "," ]; then
    after="${after#,}"            # key first: drop the following comma
  fi
  printf '%s%s' "$before" "$after"
}

# record_preflight EXIT GAPS_ARRAY → insert/replace top-level
# "preflight":{"exit":EXIT,"gaps":GAPS_ARRAY,"ack":<preserved>} in the active RUN marker. GAPS_ARRAY = a
# complete flat array literal ('[]' or '["missing: feature.json",…]'). Pure-bash via
# _marker_strip_obj_key — NO sed. Preserves an existing preflight.ack:true and every other field (incl. a
# sibling precond). Validates single {…} before writing; no marker ⇒ no-op. Mirrors record_precond.
record_preflight() {
  local ex="$1" gaps="$2" marker mk ack by reason expires pf newmk
  marker="$(resolve_marker)"
  [ -n "$marker" ] && [ -f "$marker" ] || return 0
  mk="$(cat "$marker" 2>/dev/null || true)"
  [ -n "$mk" ] || return 0
  ack="$(field_in_obj "$mk" preflight ack)"; [ "$ack" = "true" ] || ack="false"
  # WS-B — PRESERVE the governed-waiver fields (by/reason/expires) across a re-run of check-preflight, so
  # re-recording the verdict never wipes a human-recorded preflight waiver (arch-review finding 5). The
  # bare boolean ack alone no longer clears a failing preflight — check-delivery requires governed_waiver_ok.
  by="$(field_in_obj "$mk" preflight by)"
  reason="$(field_in_obj "$mk" preflight reason)"
  expires="$(field_in_obj "$mk" preflight expires)"
  # JSON-escape the preserved free-text before re-interpolating: a human `by`/`reason` can carry a `"` or
  # `\`, which field_str captures raw (stopping at the first inner quote, leaving a trailing `\`). Emitting
  # that raw would write invalid JSON and corrupt the marker (review HIGH-2). Escape `\` then `"`, exactly
  # as check-preflight escapes gap strings (review nb#1) — keeps the marker valid JSON on any input.
  by="$(printf '%s' "$by" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  reason="$(printf '%s' "$reason" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  mk="$(_marker_strip_obj_key "$mk" preflight)"
  pf="\"exit\":$ex,\"gaps\":$gaps,\"ack\":$ack"
  [ -n "$by" ]      && pf="$pf,\"by\":\"$by\""
  [ -n "$reason" ]  && pf="$pf,\"reason\":\"$reason\""
  [ -n "$expires" ] && pf="$pf,\"expires\":\"$expires\""
  newmk="${mk%\}}"
  if [ "${newmk: -1}" = "{" ]; then
    newmk="${newmk}\"preflight\":{$pf}}"
  else
    newmk="${newmk},\"preflight\":{$pf}}"
  fi
  case "$newmk" in
    \{*\}) _marker_write "$marker" "$newmk" || return 1 ;;
    *) return 1 ;;
  esac
}

# record_precond EXIT ITEMS_JSON → stamp the run marker's precond (deliverability advisory) as a
# BLOCKING, machine-readable fact (check-delivery refuses Phase B while precond.exit==2 && ack!=true).
# ITEMS_JSON = the array BODY (comma-joined quoted strings, no brackets), e.g. '"branch not pushed"'.
# Lives here (not in check-preconditions.sh) so the two marker writers share ONE surgery and are both
# unit-testable by sourcing the lib. Object-scoped ack read + position-independent strip (drift #2): it
# no longer deletes a trailing preflight object. Preserves an existing precond.ack:true. No marker ⇒ no-op.
record_precond() {
  local ex="$1" items="$2" marker mk ack newmk
  marker="$(resolve_marker)"
  [ -n "$marker" ] && [ -f "$marker" ] || return 0
  mk="$(cat "$marker" 2>/dev/null || true)"
  [ -n "$mk" ] || return 0
  ack="$(field_in_obj "$mk" precond ack)"; [ "$ack" = "true" ] || ack="false"
  mk="$(_marker_strip_obj_key "$mk" precond)"
  newmk="${mk%\}}"
  if [ "${newmk: -1}" = "{" ]; then
    newmk="${newmk}\"precond\":{\"exit\":$ex,\"items\":[$items],\"ack\":$ack}}"
  else
    newmk="${newmk},\"precond\":{\"exit\":$ex,\"items\":[$items],\"ack\":$ack}}"
  fi
  case "$newmk" in
    \{*\})
      _marker_write "$marker" "$newmk" || return 1
      echo "check-preconditions: recorded precond(exit=$ex) to $marker — Phase B is blocked until acknowledged (ack:true)." >&2 ;;
    *)
      echo "check-preconditions: WARN — could not update precond in $marker; left unchanged." >&2; return 1 ;;
  esac
}

# json_has_obj_field ARRAYJSON FIELD VALUE → rc 0 if any object in the array-of-objects ARRAYJSON has
# "FIELD":"VALUE" (whitespace-tolerant). Used by check-seam-ack to test seam_acks presence (AC-5).
json_has_obj_field() {
  printf '%s' "$1" | grep -qE "\"$2\":[[:space:]]*\"$3\""
}

# resolve_sha SHA → full commit hash if it names a commit, else empty (rc 1).
# Abbrev-safe: the historical ledger stores 7-char SHAs.
resolve_sha() { git rev-parse --verify -q "$1^{commit}" 2>/dev/null; }

# --- exec-role-integrity: the dedicated review subagent_type set (N3 single source) -----------
# review_types → echo the review subagent_type slugs (one per line), from the SINGLE SOURCE
# references/review-types.txt (blank lines and '#' comments stripped, surrounding space trimmed).
# The path is resolved relative to THIS lib's own location (BASH_SOURCE), so every sourcing script —
# record-dispatch (recorder), check-role-dispatch (gate), check-review-ack (corroboration) — reads the
# exact same set and it cannot drift. Missing file ⇒ empty set (callers treat that as "nothing counts").
review_types() {
  local f; f="$(dirname "${BASH_SOURCE[0]}")/../references/review-types.txt"
  [ -f "$f" ] || return 0
  # column 1 is the slug; an optional TAB-separated column 2 is the attributed role (all-four-role-dispatch).
  # `cut -f1` (TAB delimiter) returns the whole line for a tabless generic (identity) and the slug for a
  # `slug<TAB>role` dedicated line — so a tab-bearing dedicated slug still matches is_review_type (B1: a
  # whole-line match would let the interior tab break it → dropped at record → DOA).
  grep -vE '^[[:space:]]*(#|$)' "$f" 2>/dev/null | cut -f1 | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | grep -vE '^$' || true
}

# --- control-surface-protection: the plugin's own machinery path set (single source) ----------
# control_surface_globs → echo the control-surface globs (one per line), from the SINGLE SOURCE
# references/control-surface.txt (blank lines and '#' comments stripped, surrounding space trimmed).
# BASH_SOURCE-relative — like review_types() — so the gate (check-seam-ack) and any other reader see
# the exact same set and it cannot drift. Missing file ⇒ empty set (no standing seam; callers skip).
# Tokens are matched by check-seam-ack.sh:_intersects (equals / under-dir / glob, `*` spans `/`).
control_surface_globs() {
  local f; f="$(dirname "${BASH_SOURCE[0]}")/../references/control-surface.txt"
  _read_surface_list "$f"
}

# control_surface_globs_in DIR → the control-surface glob set from DIR/references/control-surface.txt —
# the TARGET repo's OWN declaration, not the plugin's. The control surface is a property of the repo being
# DELIVERED: a target that does not ship this file is not subject to any standing control-surface seam, so
# the standing seam never false-positives on a target's generically-named files (AGENTS.md, .claude, …).
# team-bootstrap ships the file for its own (self-)delivery, so the seam fires there. Missing file ⇒ empty.
# (Distinct from control_surface_globs(), which is plugin/BASH_SOURCE-relative — used by the CI example,
# whose copy already runs from the repo under check, so the two coincide there.)
control_surface_globs_in() {
  _read_surface_list "${1:-.}/references/control-surface.txt"
}

# _read_surface_list FILE → the surface globs in FILE (one/line; '#' comments + blank lines stripped,
# surrounding whitespace trimmed). Empty if FILE is absent. Single source for both readers above.
_read_surface_list() {
  [ -f "$1" ] || return 0
  grep -vE '^[[:space:]]*(#|$)' "$1" 2>/dev/null | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | grep -vE '^$' || true
}

# role_of_slug SLUG → the role attributed to SLUG (column 2), or EMPTY if SLUG is a generic (no column 2)
# or absent. Tab-safe: `cut -s -f2` yields nothing on a tabless generic line, so a generic can NEVER
# phantom-attribute (a naive cut -f2 / ${line#*TAB} would return the whole line). Milestone all-four.
role_of_slug() {
  local slug="$1" line c1 c2 f
  [ -n "$slug" ] || return 0
  f="$(dirname "${BASH_SOURCE[0]}")/../references/review-types.txt"
  [ -f "$f" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    c1="$(printf '%s' "$line" | cut -f1 | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    [ "$c1" = "$slug" ] || continue
    c2="$(printf '%s' "$line" | cut -s -f2 | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    printf '%s' "$c2"
    return 0
  done <<EOF
$(grep -vE '^[[:space:]]*(#|$)' "$f" 2>/dev/null)
EOF
}

# mandated_roles PIPELINE → the review roles a pipeline REQUIRES dispatched (space-separated), else empty.
# full → all four; mvp → the code-reviewer+regression-guardian subset; single-thread/unknown → none.
mandated_roles() {
  case "$1" in
    full) printf '%s' "integration-verifier architecture-reviewer regression-guardian code-reviewer" ;;
    mvp)  printf '%s' "code-reviewer regression-guardian" ;;
    *)    : ;;
  esac
}

# roles_covered BID → space-separated DISTINCT mandated roles with >=1 attributed dispatch in the active
# run's dispatch.jsonl for batch BID. Generics (empty role) are DROPPED, so a generic-only batch yields
# empty and fails enforce naming all mandated roles. Empty BID is non-matchable (parity with FIX#3).
roles_covered() {
  local bid="$1" marker rundir disp line stype rbatch role seen=""
  [ -n "$bid" ] || return 0
  marker="$(resolve_marker)"; [ -n "$marker" ] || return 0
  rundir="$(dirname "$marker")"; disp="$rundir/dispatch.jsonl"
  [ -f "$disp" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    rbatch="$(field_str "$line" batch)"
    [ "$rbatch" = "$bid" ] || continue
    stype="$(field_str "$line" subagent_type)"
    role="$(role_of_slug "$stype")"
    [ -n "$role" ] || continue
    case " $seen " in *" $role "*) ;; *) seen="${seen:+$seen }$role" ;; esac
  done < "$disp"
  printf '%s' "$seen"
}

# role_floor_mode → 'enforce' | 'warn' — the per-role floor mode (all-four-role-dispatch). Precedence
# (R5-NB4): an explicit TEAM_BOOTSTRAP_ROLE_FLOOR wins; else it is 'enforce' iff the committed evidence
# marker references/role-dispatch-enforce is present (BASH_SOURCE-relative — plugin-global, so one
# committed marker flips it for everyone), else 'warn'. TEAM_BOOTSTRAP_ROLE_ENFORCE_MARKER overrides the
# marker PATH (tests only — R4-1: committing the real marker must never change a self-test outcome).
role_floor_mode() {
  case "${TEAM_BOOTSTRAP_ROLE_FLOOR:-}" in
    enforce) printf 'enforce'; return 0 ;;
    warn)    printf 'warn'; return 0 ;;
  esac
  local m="${TEAM_BOOTSTRAP_ROLE_ENFORCE_MARKER:-$(dirname "${BASH_SOURCE[0]}")/../references/role-dispatch-enforce}"
  [ -f "$m" ] && printf 'enforce' || printf 'warn'
}

# missing_roles PIPELINE BID → space-separated mandated roles NOT covered by BID's dispatches (empty if
# all covered or the pipeline mandates none). The per-role gap both the role-dispatch gate and the
# review-ack parity read from one place (N3 — no drift).
missing_roles() {
  local pipeline="$1" bid="$2" covered r missing=""
  covered="$(roles_covered "$bid")"
  for r in $(mandated_roles "$pipeline"); do
    case " $covered " in *" $r "*) ;; *) missing="${missing:+$missing }$r" ;; esac
  done
  printf '%s' "$missing"
}

# is_review_type SLUG → rc 0 if SLUG EXACTLY matches a review type (anchored, whole-slug), else 1.
# Empty SLUG ⇒ 1. Exact match distinguishes a reviewer dispatch from a builder's (backend-developer,
# general-purpose, stack specialists — none of which appear in review-types.txt).
is_review_type() {
  local slug="$1" t
  [ -n "$slug" ] || return 1
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    [ "$slug" = "$t" ] && return 0
  done <<EOF
$(review_types)
EOF
  return 1
}

# reviewer_dispatch_count BID → count of .runs/<run>/dispatch.jsonl records (active run) credited to
# batch BID whose subagent_type is a review type. Prints 0 (never errors) when there is no active
# marker or no dispatch file. ONE definition of "a reviewer subagent was dispatched for this batch",
# shared by check-role-dispatch (the gate) and check-review-ack (the v2.20.0 corroboration) so the
# two cannot diverge on what counts as a reviewer dispatch (exec-role-integrity B3).
reviewer_dispatch_count() {
  local bid="$1" marker rundir disp line stype rbatch n=0
  # An empty batch id (malformed ledger entry with no "id") is NON-MATCHABLE: never credit it with an
  # orphan {"batch":""} dispatch record — that would be a false pass on a malformed ledger (review FIX#3).
  [ -n "$bid" ] || { printf '0'; return 0; }
  marker="$(resolve_marker)"; [ -n "$marker" ] || { printf '0'; return 0; }
  rundir="$(dirname "$marker")"; disp="$rundir/dispatch.jsonl"
  [ -f "$disp" ] || { printf '0'; return 0; }
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    stype="$(field_str "$line" subagent_type)"
    is_review_type "$stype" || continue
    rbatch="$(field_str "$line" batch)"
    [ "$rbatch" = "$bid" ] && n=$((n + 1))
  done < "$disp"
  printf '%s' "$n"
}

# risk_rank_int NAME → integer rank (higher = more load-bearing); empty if unknown.
risk_rank_int() {
  case "$1" in
    irreversible) printf '4' ;;
    run-rate)     printf '3' ;;
    feature)      printf '2' ;;
    doc)          printf '1' ;;
    *)            printf '' ;;
  esac
}

# _is_doc_path PATH → rc 0 if the path is documentation / non-code.
# ONE definition of the non-doc boundary, shared by delta + stamp.
# _is_doc_file PATH → rc 0 if the FILE ITSELF is prose, by extension. Split out of _is_doc_path because
# the two questions differ: "is this line documentation for the code-delta count?" takes the whole
# docs/ and references/ TREES, while "is this file prose rather than a suite?" must not — a real test
# living at docs/tests/gate_test.go is a suite, and exempting it from a gate would be a hole
# (check-gate-integrity, spec 021 AC-13). One definition each, and the tree rule composes the file rule.
_is_doc_file() {
  case "$1" in
    *.md|*.mdx|*.txt|LICENSE|CHANGELOG*) return 0 ;;
    *) return 1 ;;
  esac
}
_is_doc_path() {
  _is_doc_file "$1" && return 0
  case "$1" in
    docs/*|references/*) return 0 ;;
    *) return 1 ;;
  esac
}

# code_since_baseline BASELINE → rc 0 if there is > 0 non-doc code delta on commits
# reachable from HEAD since BASELINE, else rc 1 (incl. unresolvable/empty baseline).
#
# The direct-pipeline delivery signal. `/deliver` writes a batch ledger and closes it with
# verify-batch; but a direct pipeline run (`/team-bootstrap single-thread …`, which deliver.md
# itself recommends for small changes) writes NO ledger. Such a run still proves delivery the
# same git-grounded way: real code committed since the run baseline, reachable from HEAD —
# unforgeable by prose. The guard accepts EITHER a git-verified ledger closure OR this signal.
# Uses the same shared nondoc_delta_of_shas, so "code" means the same thing everywhere.
code_since_baseline() {
  local bfull shas d
  bfull="$(resolve_sha "${1:-}")" || bfull=""
  [ -n "$bfull" ] || return 1
  shas="$(git log --format=%h "${bfull}..HEAD" 2>/dev/null | head -200 | tr '\n' ' ')"
  [ -n "$shas" ] || return 1
  d="$(nondoc_delta_of_shas "$shas")"; case "$d" in ''|*[!0-9]*) d=0 ;; esac
  [ "$d" -gt 0 ]
}

# --- F1 (red-touches-tests) test-path detection --------------------------------
# is_test_path PATH [EXTRA_GLOBS] → rc 0 if PATH is a test file, else rc 1.
# Default set (OQ-1): basename matches *_test.* *.test.* test_*.* *.spec.* *Test.* *_spec.rb,
# OR any path segment ∈ {test, tests, spec, __tests__}. EXTRA_GLOBS (space/comma-separated,
# from AGENTS.md TestGlobs:) EXTENDS the default set — a project can widen the check, never
# shrink it. Extra globs are matched against BOTH the full path and the basename.
is_test_path() {
  local p="$1" extra="${2:-}" base glob
  base="${p##*/}"
  case "$base" in
    *_test.*|*.test.*|test_*.*|*.spec.*|*Test.*|*_spec.rb) return 0 ;;
  esac
  case "/$p/" in
    */test/*|*/tests/*|*/spec/*|*/__tests__/*) return 0 ;;
  esac
  if [ -n "$extra" ]; then
    extra="${extra//,/ }"
    for glob in $extra; do
      [ -n "$glob" ] || continue
      # shellcheck disable=SC2254  # unquoted on purpose: $glob is a glob pattern to match
      case "$p" in $glob) return 0 ;; esac
      # shellcheck disable=SC2254
      case "$base" in $glob) return 0 ;; esac
    done
  fi
  return 1
}

# _test_cmd [DOC] → the runnable `Test:` command from the agents-md contract (AGENTS.md, else CLAUDE.md),
# or empty (N/A|none ⇒ empty). PROMOTED here from check-tdd.sh (pipeline-integrity-hardening WS-B, the T0
# the preflight descope skipped) so check-tdd AND check-preflight read ONE definition of "the project's
# test command" and cannot diverge. Reads from the current directory (cd into the target first).
_test_cmd() {
  local doc="${1:-}" f c
  if [ -z "$doc" ]; then for f in AGENTS.md CLAUDE.md; do [ -f "$f" ] && { doc="$f"; break; }; done; fi
  [ -n "$doc" ] && [ -f "$doc" ] || return 0
  c="$(grep -iE "^[[:space:]]*[-*]?[[:space:]]*Test:" "$doc" 2>/dev/null | head -1 | grep -oE '`[^`]+`' | head -1 | tr -d '`')"
  case "$c" in N/A|n/a|None|none) c="" ;; esac
  printf '%s' "$c"
}

# governed_waiver_ok ACK BY REASON EXPIRES [NOW] → rc 0 IFF ACK=="true" AND by/reason/expires are all
# non-empty AND expires is YYYY-MM-DD AND expires >= NOW (default TEAM_BOOTSTRAP_NOW, else today). ONE
# reusable definition of "a dated, attributed, unexpired waiver" (OQ-5), shared by the preflight enforcer
# and any future ackable gate: a bare one-time ack is NOT a waiver — it must not become a standing free
# pass across a later independent failure on the same run (WS-B AC-B5). The comparison is a lexicographic
# string compare of YYYY-MM-DD (which sorts chronologically), so it needs NO date arithmetic and is
# darwin-portable (no `date -d`; only the default `now` touches `date`, overridable via TEAM_BOOTSTRAP_NOW).
governed_waiver_ok() {
  local ack="$1" by="$2" reason="$3" expires="$4" now="${5:-${TEAM_BOOTSTRAP_NOW:-$(date +%Y-%m-%d)}}"
  [ "$ack" = "true" ] && [ -n "$by" ] && [ -n "$reason" ] && [ -n "$expires" ] || return 1
  case "$expires" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) : ;;
    *) return 1 ;;
  esac
  [ "$expires" \< "$now" ] && return 1   # expired (string compare on YYYY-MM-DD = chronological)
  return 0
}

# read_test_globs [DOC] → echo the space-separated globs on a `TestGlobs:` line in
# AGENTS.md/CLAUDE.md (empty if none). Values may be backticked or bare, comma- or
# space-separated. Extends is_test_path's default set; never replaces it.
read_test_globs() {
  local doc="${1:-}" f rest
  if [ -z "$doc" ]; then for f in AGENTS.md CLAUDE.md; do [ -f "$f" ] && { doc="$f"; break; }; done; fi
  [ -n "$doc" ] && [ -f "$doc" ] || return 0
  rest="$(grep -iE "^[[:space:]]*[-*]?[[:space:]]*TestGlobs:" "$doc" 2>/dev/null | head -1 | sed -E 's/^[^:]*://')"
  [ -n "$rest" ] || return 0
  printf '%s' "$rest" | tr -d '`' | tr ',' ' ' | xargs 2>/dev/null || true
}

# window_touches_test BASE TIP [EXTRA_GLOBS] → rc 0 if the diff BASE..TIP changes ≥1 test path.
# BASE empty ⇒ compare against the canonical empty tree (TIP's whole content). Used by check-tdd
# (F1) to require a code batch's red window to have changed a test file.
window_touches_test() {
  local base="$1" tip="$2" extra="${3:-}" p
  [ -n "$base" ] || base="4b825dc642cb6eb9a060e54bf8d69288fbee4904"  # git empty tree
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    is_test_path "$p" "$extra" && return 0
  done < <(git diff --name-only "$base" "$tip" 2>/dev/null)
  return 1
}

# nondoc_delta_of_shas "sha1 sha2 …" → Σ (added+deleted) lines on NON-doc files
# across the commits, counted PER COMMIT (self-contained; does not drift with later
# history — OQ-4). Unresolvable SHAs contribute 0; callers enforce existence
# separately (AC-1). IFS is pinned locally so a caller's IFS cannot corrupt splitting.
nondoc_delta_of_shas() {
  local shas="$1" sha full add del path total=0
  local -a list=()
  IFS=' ' read -r -a list <<<"$shas"
  for sha in "${list[@]}"; do
    [ -n "$sha" ] || continue
    full="$(resolve_sha "$sha")" || full=""
    [ -n "$full" ] || continue
    while IFS="$(printf '\t')" read -r add del path; do
      [ -n "${path:-}" ] || continue
      _is_doc_path "$path" && continue
      case "$add" in ''|*[!0-9]*) add=0 ;; esac
      case "$del" in ''|*[!0-9]*) del=0 ;; esac
      total=$((total + add + del))
    done < <(git show --numstat --format= "$full" 2>/dev/null)
  done
  printf '%s' "$total"
}

# --- F2 (diff-coverage) batch window ------------------------------------------
# current_batch_base — echo the base ref/sha for the IN-FLIGHT batch's diff, using the EXACT
# chain verify-batch.sh's stamp uses: newest commit of the last `closed` ledger entry → the first
# existing of origin/main|main|origin/master|master (if it differs from HEAD) → HEAD~1. F2 and the
# code_delta stamp both take their window from HERE, so "the batch's changed lines" is one definition
# and cannot drift (spec R1). Echoes a usable base (empty only in a repo with no HEAD~1).
current_batch_base() {
  local ledger since base b marker mk bsha
  ledger="$(resolve_ledger)"
  if [ -n "$ledger" ] && [ -f "$ledger" ]; then
    since="$(grep '"status":"closed"' "$ledger" 2>/dev/null | tail -1 \
      | sed -nE 's/.*"commit_shas":\[[[:space:]]*"([0-9a-fA-F]+)".*/\1/p')"
    if [ -n "$since" ] && git rev-parse --verify -q "$since^{commit}" >/dev/null 2>&1; then
      printf '%s' "$since"; return 0
    fi
  fi
  # first batch (no closed batch yet): the window starts at the RUN's OWN baseline_sha, not
  # origin/main. Using origin/main here can drag pre-run commits (even the run baseline itself)
  # into commit_shas, which check-delivery then flags as predate/forged and check-tdd's oldest-
  # commit anchor breaks on. baseline_sha is the run's declared start — the correct window base.
  marker="$(resolve_marker)"
  if [ -n "$marker" ] && [ -f "$marker" ]; then
    mk="$(cat "$marker" 2>/dev/null || true)"; bsha="$(field_str "$mk" baseline_sha)"
    if [ -n "$bsha" ] && git rev-parse --verify -q "$bsha^{commit}" >/dev/null 2>&1 \
       && [ "$(git rev-parse -q "$bsha^{commit}" 2>/dev/null)" != "$(git rev-parse -q HEAD 2>/dev/null)" ]; then
      printf '%s' "$bsha"; return 0
    fi
  fi
  base=""
  for b in origin/main main origin/master master; do
    if git rev-parse --verify -q "$b^{commit}" >/dev/null 2>&1; then base="$b"; break; fi
  done
  if [ -n "$base" ] && [ "$(git rev-parse -q "$base" 2>/dev/null)" != "$(git rev-parse -q HEAD 2>/dev/null)" ]; then
    printf '%s' "$base"; return 0
  fi
  git rev-parse --verify -q 'HEAD~1^{commit}' >/dev/null 2>&1 && printf 'HEAD~1'
  return 0
}

# changed_nondoc_lines BASE → emit "path:line" for each added/changed NON-doc line in BASE..HEAD
# (git diff --unified=0, new-side hunk ranges). Doc paths (_is_doc_path) are filtered out. Pure
# deletions (new-side count 0) contribute nothing. Used by F2 as the denominator's source set.
changed_nondoc_lines() {
  local base="$1" path="" line plus start cnt i
  [ -n "$base" ] || return 0
  while IFS= read -r line; do
    case "$line" in
      "+++ b/"*) path="${line#+++ b/}" ;;
      "+++ "*)   path="" ;;
      "@@ "*)
        [ -n "$path" ] || continue
        _is_doc_path "$path" && continue
        plus="$(printf '%s' "$line" | sed -nE 's/^@@ [^+]*\+([0-9]+)(,([0-9]+))? @@.*/\1 \3/p')"
        [ -n "$plus" ] || continue
        start="${plus%% *}"; cnt="${plus##* }"
        case "$cnt" in ''|*[!0-9]*) cnt=1 ;; esac
        [ "$cnt" -eq 0 ] && continue
        i=0
        while [ "$i" -lt "$cnt" ]; do printf '%s:%s\n' "$path" "$((start + i))"; i=$((i + 1)); done
        ;;
    esac
  done < <(git diff --unified=0 "$base" HEAD 2>/dev/null)
}
