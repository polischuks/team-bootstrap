#!/usr/bin/env bash
# check-role-dispatch.sh — verify-batch gate: harness-verified role execution (exec-role-integrity, v2.21.0).
#
# full/mvp exist to give each batch a fresh INDEPENDENT reviewer mind (builder ≠ reviewer). spec-169
# collapsed that silently — the orchestrator ran build AND review inline, dispatched no reviewer subagent,
# and the user was told "delivered, gates passed." This gate makes the collapse catchable + announced:
# a full/mvp kind:code batch whose window recorded ZERO reviewer-typed Agent dispatches
# (record-dispatch.sh @ PreToolUse[Agent], subagent_type ∈ references/review-types.txt) fails closed with
# a LOUD, user-visible message that the run degraded to single-thread.
#
# Signal (probe-confirmed, plan §signal): a reviewer-typed DISPATCH OCCURRENCE — no completion status
# (background dispatch yields async_launched, never completed — soundness N1). A builder-typed dispatch
# (backend-developer / general-purpose / stack specialists — none in review-types.txt) does NOT satisfy it.
# Attribution is by the in-flight batch id the recorder stamped at dispatch time (soundness B4).
#
# HONEST LIMITS (ADR-0008): subagent_type is model-authored ⇒ DEGRADATION-proof, NOT forgery-proof (a decoy
# review-typed no-op dispatch satisfies it — the ADR-0006 quality/willingness limit); and a dispatch proves
# the reviewer was LAUNCHED, not that it completed or was good (NF1 — completion rests on check-review-ack).
#
# Graceful skips (exit 0): no active marker / not intends_code (AC-3); pipeline is not full|mvp — e.g.
# single-thread, where P1 sanctions inline roles (AC-3); in-flight batch not kind:code (AC-3).
#
# Usage: bin/check-role-dispatch.sh [project-dir]  ·  bin/check-role-dispatch.sh --self-test
# Exit:  0 pass / skip · 1 full/mvp code batch with zero reviewer-typed dispatch (degraded) · 64 bad usage
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/delivery-lib.sh
. "$here/delivery-lib.sh"

# _inflight_batch → the in-flight ledger line (last announced; else last non-empty).
_inflight_batch() {
  local ledger line
  ledger="$(resolve_ledger)"; [ -n "$ledger" ] && [ -f "$ledger" ] || return 0
  line="$(grep '"status":[[:space:]]*"announced"' "$ledger" 2>/dev/null | tail -1)"
  [ -n "$line" ] || line="$(grep -v '^[[:space:]]*$' "$ledger" 2>/dev/null | tail -1)"
  printf '%s' "$line"
}

_evaluate() {
  local marker mk pipeline bline bid bkind cnt
  marker="$(resolve_marker)"
  [ -n "$marker" ] && [ -f "$marker" ] || { echo "check-role-dispatch: no active delivery run — skipping."; return 0; }
  mk="$(cat "$marker" 2>/dev/null || true)"
  [ "$(field_bool "$mk" intends_code)" = "true" ] || { echo "check-role-dispatch: marker not intends_code — skipping."; return 0; }

  pipeline="$(field_str "$mk" pipeline)"
  # single-thread is the sanctioned one-mind contract (P1) — it never runs roles as independent subagents,
  # so role-dispatch does not apply. This is a KNOWN pipeline, not an undeterminable one.
  [ "$pipeline" = "single-thread" ] && { echo "check-role-dispatch: pipeline=single-thread — one mind is the sanctioned contract (P1); skipping."; return 0; }

  bline="$(_inflight_batch)"
  [ -n "$bline" ] || { echo "check-role-dispatch: no in-flight batch — nothing to check."; return 0; }
  bid="$(field_str "$bline" id)"; bkind="$(field_str "$bline" kind)"
  [ "$bkind" = "code" ] || { echo "check-role-dispatch: in-flight batch '$bid' is kind=$bkind (not code) — skipping."; return 0; }

  # The batch is now intends_code + kind:code. full/mvp enforce reviewer independence below; an
  # UNKNOWN/absent pipeline on such a batch is a malformed marker whose execution model cannot be
  # certified — FAIL-CLOSED, never a silent skip (a well-formed harness marker always records
  # full|mvp|single-thread; skipping here would fail OPEN on exactly the undeterminable input the
  # fail-closed design forbids — review FIX#1).
  case "$pipeline" in
    full|mvp) : ;;
    *)
      echo "check-role-dispatch: UNVERIFIABLE — pipeline='$pipeline' is not a recognized code pipeline (full|mvp|single-thread) on an intends_code kind:code batch '$bid'. The run's execution model cannot be certified; failing closed rather than skipping a possibly-full run that collapsed."
      echo "  FAIL-CLOSED: unrecognized pipeline '$pipeline' on intends_code code batch '$bid' — cannot verify reviewer independence (malformed marker)." >&2
      return 1 ;;
  esac

  cnt="$(reviewer_dispatch_count "$bid")"   # shared delivery-lib definition (single source, B3)
  # The ≥1 total-collapse floor (exec-role-integrity) is HARD under BOTH warn and enforce — warn only
  # relaxes the per-role UPGRADE below, never this (AC-8). A zero-dispatch batch is the spec-169 signature.
  if [ "${cnt:-0}" -eq 0 ]; then
    # AC-4 — the degradation message MUST reach the user (stdout), not only stderr.
    echo "check-role-dispatch: DEGRADED — $pipeline/code batch '$bid' closed with ZERO independent-review-typed subagent dispatches. The run degraded to single-thread: no reviewer ran in a fresh context (builder ≠ reviewer was not honored). Dispatch the required review roles as subagents with a dedicated review type (references/review-types.txt) before closing, or run single-thread if one mind is intended."
    echo "  FAIL-CLOSED: batch '$bid' — no reviewer-typed Agent dispatch recorded for its window (spec-169 collapse signature)." >&2
    return 1
  fi

  # --- per-role floor (all-four-role-dispatch): every MANDATED role must be dispatched, not just >=1 ---
  local mode mandated covered missing
  mode="$(role_floor_mode)"
  covered="$(roles_covered "$bid")"
  # issue #27 — the harness sizes each batch: prefer the set RECORDED on this batch's ledger entry over
  # the blanket per-pipeline mandate. Absent ⇒ the legacy fixed set, so old runs and hand-written
  # ledgers behave exactly as before. The >=1 reviewer floor above is unaffected either way — it is the
  # anti-collapse invariant and is never sized away.
  local recorded surplus r
  recorded="$(required_roles_recorded "$bid" 2>/dev/null || true)"
  if [ -n "$recorded" ]; then
    # A RECORDED set is right-sized for this batch, so its floor is hard REGARDLESS of role_floor_mode.
    # Hardness follows from the set having been computed — not from a global flag. That is what makes
    # it safe: the blanket per-pipeline mandate was deliberately never armed, because demanding four
    # roles for a one-line change leaves under-declaring risk as the only escape (worse than overspend).
    mandated="$recorded"
    missing=""
    for r in $mandated; do
      case " $covered " in *" $r "*) : ;; *) missing="${missing:+$missing }$r" ;; esac
    done
    mode="enforce"
  else
    # No recorded set ⇒ exactly today's behaviour, untouched: warn unless the operator/marker says
    # enforce. This milestone changes nothing for legacy runs and hand-written ledgers.
    #
    # …but the harness still SIZES the batch and says so, so the feature is not inert on a run whose
    # orchestrator never recorded the set (review HIGH: nothing wired record_required_roles, which made
    # the whole recorded-set branch unreachable in production). Computing here is also more accurate
    # than at announce, where the batch window is still empty. Advisory only — upgrading a
    # non-adopter's run to hard per-role enforcement is exactly the blanket demand this design rejects.
    mandated="$(mandated_roles "$pipeline")"
    missing="$(missing_roles "$pipeline" "$bid")"
    local sized sized_missing
    sized="$(required_roles_for_batch "$bid" 2>/dev/null || true)"
    if [ -n "$sized" ]; then
      sized_missing=""
      for r in $sized; do
        case " $covered " in *" $r "*) : ;; *) sized_missing="${sized_missing:+$sized_missing }$r" ;; esac
      done
      if [ "$sized" != "$mandated" ]; then
        echo "check-role-dispatch: SIZED — the harness sizes batch '$bid' at [$sized] (not the blanket [$mandated]); dispatched [${covered:-none}]${sized_missing:+, short of the sized set: [$sized_missing]}. Record required_roles on the ledger entry to make this floor hard (#27)."
      fi
    fi
  fi
  # Surplus is REPORTED, never blocked (#27 boundary): blocking a supernumerary dispatch would push the
  # orchestrator to review INLINE — the spec-169 collapse. Cost is visible where gate results are read.
  surplus=""
  for r in $covered; do
    case " $mandated " in *" $r "*) : ;; *) surplus="${surplus:+$surplus }$r" ;; esac
  done
  if [ -n "$surplus" ]; then
    echo "check-role-dispatch: SURPLUS — batch '$bid' dispatched [$surplus] beyond the required set [$mandated]. Each is a separate subagent (~3.6-11.8 min). Not a failure; sizing is advice (#27)."
  fi
  if [ -n "$missing" ]; then
    if [ "$mode" = "enforce" ]; then
      echo "check-role-dispatch: MISSING ROLES — $pipeline/code batch '$bid' dispatched roles [${covered:-none}] but the mandate requires [$mandated]; MISSING: [$missing]. Dispatch each missing role under its dedicated review type (references/review-types.txt) before closing."
      echo "  FAIL-CLOSED: batch '$bid' missing mandated review role(s) [$missing] (per-role floor, enforce)." >&2
      return 1
    fi
    # warn mode (default until references/role-dispatch-enforce is committed after the T5b adoption probe):
    # the >=1 floor is satisfied; announce the per-role gap + record telemetry, but do not fail (AC-3).
    echo "check-role-dispatch: warn (per-role) — batch '$bid' covered [${covered:-none}], missing mandated [$missing]. Ships warn; commit references/role-dispatch-enforce after the adoption probe to enforce. (>=1 floor satisfied.)"   # gate-integrity: sanctioned — warn-mode per-role upgrade
    local rundir; rundir="$(dirname "$marker")"
    printf '{"batch":"%s","covered":"%s","missing":"%s","mode":"warn"}\n' "$bid" "$covered" "$missing" >> "$rundir/role-telemetry.jsonl" 2>/dev/null || true
    return 0
  fi
  echo "check-role-dispatch: batch '$bid' recorded $cnt reviewer dispatch(es) covering all mandated roles [$mandated] ($pipeline). OK."
  return 0
}

# --- self-test ---------------------------------------------------------------
if [ "${1:-}" = "--self-test" ]; then
  fail=0; T="$(mktemp -d)"; mkdir -p "$T/.runs/r"
  # R4-1: point the enforce marker at a temp path so NO self-test case touches the shipped
  # references/role-dispatch-enforce (committing the real marker must never change a test outcome).
  unset TEAM_BOOTSTRAP_ROLE_FLOOR; export TEAM_BOOTSTRAP_ROLE_ENFORCE_MARKER="$T/enforce-marker"; rm -f "$T/enforce-marker"
  ( cd "$T" && git init -q && git config user.email t@t && git config user.name t
    echo base > f && git add . && git commit -qm base ) >/dev/null 2>&1
  base="$(cd "$T" && git rev-parse --short HEAD)"
  _marker() { printf '%s\n' "$1" > "$T/.runs/r/RUN"; }
  _batch()  { printf '%s\n' "$1" > "$T/.runs/r/batches.jsonl"; }
  _disp()   { printf '%s\n' "$1" > "$T/.runs/r/dispatch.jsonl"; }
  _run() { ( cd "$T" && TEAM_BOOTSTRAP_RUN=r "$here/check-role-dispatch.sh" . >/dev/null 2>&1 ); echo $?; }
  _chk() { if [ "$2" = "$3" ]; then echo "  PASS (exit $2) $1"; else echo "  FAIL (exit $2 want $3) $1" >&2; fail=$((fail + 1)); fi; }
  MK='"run":"r","pipeline":"full","intends_code":true,"source":"harness","baseline_sha":"'"$base"'"'
  _batch '{"id":"B1","kind":"code","status":"announced"}'
  rm -f "$T/.runs/r/dispatch.jsonl"

  # AC-1 — full+code, no dispatch.jsonl at all → fail (degraded)
  _marker "{$MK}"
  _chk "AC-1 full+code, zero reviewer dispatch → fail" "$(_run)" 1
  # AC-1 — full+code, ONLY a builder-typed dispatch recorded → fail (builder does not satisfy)
  _disp '{"batch":"B1","subagent_type":"backend-developer"}'
  _chk "AC-1 builder-typed dispatch only → fail" "$(_run)" 1
  # AC-1 — full+code, a review-typed dispatch for a DIFFERENT batch → fail (attribution, B4)
  _disp '{"batch":"B0","subagent_type":"code-reviewer"}'
  _chk "AC-1 reviewer dispatch credited to another batch → fail" "$(_run)" 1
  # AC-1 — full+code, ≥1 review-typed dispatch for THIS batch → pass
  _disp '{"batch":"B1","subagent_type":"code-reviewer"}'
  _chk "AC-1 ≥1 reviewer-typed dispatch for this batch → pass" "$(_run)" 0
  # AC-1 — the dedicated plugin-scoped type also satisfies
  _disp '{"batch":"B1","subagent_type":"independent-reviewer"}'
  _chk "AC-1 dedicated review type satisfies → pass" "$(_run)" 0
  # AC-4 — the degradation message is on STDOUT (user-visible)
  rm -f "$T/.runs/r/dispatch.jsonl"
  out="$( cd "$T" && TEAM_BOOTSTRAP_RUN=r "$here/check-role-dispatch.sh" . 2>/dev/null )"
  case "$out" in *DEGRADED*|*degraded*) echo "  PASS AC-4 degradation message on stdout" ;; *) echo "  FAIL AC-4 no stdout message (got: $out)" >&2; fail=$((fail + 1)) ;; esac
  # AC-3 — single-thread pipeline → skip even with zero dispatch
  _marker '{"run":"r","pipeline":"single-thread","intends_code":true,"source":"harness","baseline_sha":"'"$base"'"}'
  _chk "AC-3 single-thread → skip" "$(_run)" 0
  # AC-3 — non-code batch → skip
  _marker "{$MK}"; _batch '{"id":"Z","kind":"doc","status":"announced"}'
  _chk "AC-3 kind:doc batch → skip" "$(_run)" 0
  # AC-3 — mvp pipeline is in scope (fails on zero, like full)
  _batch '{"id":"B1","kind":"code","status":"announced"}'; rm -f "$T/.runs/r/dispatch.jsonl"
  _marker '{"run":"r","pipeline":"mvp","intends_code":true,"source":"harness","baseline_sha":"'"$base"'"}'
  _chk "AC-3 mvp+code, zero reviewer dispatch → fail (in scope)" "$(_run)" 1
  # AC-3 — no active marker → skip
  rm -f "$T/.runs/r/RUN"
  _chk "AC-3 no active marker → skip" "$(_run)" 0
  # not intends_code → skip
  _marker '{"run":"r","pipeline":"full","intends_code":false,"source":"harness"}'
  _chk "not intends_code → skip" "$(_run)" 0

  # FIX#1 (review) — an intends_code kind:code batch whose pipeline is UNKNOWN/absent must FAIL-CLOSED,
  # not silently skip (a well-formed harness marker always records full|mvp|single-thread; anything else
  # is malformed and its execution model cannot be certified).
  _batch '{"id":"B1","kind":"code","status":"announced"}'; rm -f "$T/.runs/r/dispatch.jsonl"
  _marker '{"run":"r","pipeline":"audit","intends_code":true,"source":"harness","baseline_sha":"'"$base"'"}'
  _chk "FIX#1 unknown pipeline (audit) + intends_code + code → fail-closed" "$(_run)" 1
  _marker '{"run":"r","intends_code":true,"source":"harness","baseline_sha":"'"$base"'"}'
  _chk "FIX#1 absent pipeline + intends_code + code → fail-closed" "$(_run)" 1
  # single-thread stays a SANCTIONED skip (must NOT be swept up by the unknown-pipeline fail-closed)
  _marker '{"run":"r","pipeline":"single-thread","intends_code":true,"source":"harness","baseline_sha":"'"$base"'"}'
  _chk "FIX#1 single-thread still skips (sanctioned, not unknown)" "$(_run)" 0
  # a non-code batch under an unknown pipeline still skips (no code to certify)
  _marker '{"run":"r","pipeline":"audit","intends_code":true,"source":"harness","baseline_sha":"'"$base"'"}'
  _batch '{"id":"Z","kind":"doc","status":"announced"}'
  _chk "FIX#1 unknown pipeline + kind:doc → skip (no code)" "$(_run)" 0

  # FIX#3 (review) — an EMPTY batch id (malformed ledger) must not be satisfied by an orphan batch:""
  # dispatch record → fail-closed (empty bid is non-matchable).
  _marker "{$MK}"; _batch '{"kind":"code","status":"announced"}'    # no id
  _disp '{"batch":"","subagent_type":"code-reviewer"}'
  _chk "FIX#3 empty bid not satisfied by orphan batch:\"\" record → fail-closed" "$(_run)" 1

  # --- all-four-role-dispatch: per-role floor (T3), marker-gated warn/enforce -------------------
  _marker "{$MK}"; _batch '{"id":"B1","kind":"code","status":"announced"}'
  _cover4() { { printf '{"batch":"B1","subagent_type":"integration-verifier"}\n'
    printf '{"batch":"B1","subagent_type":"architecture-reviewer"}\n'
    printf '{"batch":"B1","subagent_type":"regression-guardian"}\n'
    printf '{"batch":"B1","subagent_type":"tb-code-reviewer"}\n'; } > "$T/.runs/r/dispatch.jsonl"; }
  _cover4; rm -f "$T/enforce-marker"
  _chk "per-role warn (marker absent): all four roles covered → pass" "$(_run)" 0
  touch "$T/enforce-marker"
  _chk "per-role enforce: all four roles covered → pass" "$(_run)" 0
  _disp '{"batch":"B1","subagent_type":"tb-code-reviewer"}'   # only code-reviewer role
  _chk "AC-2/AC-4 enforce: only 1 mandated role → fail (missing 3)" "$(_run)" 1
  rm -f "$T/enforce-marker"
  _chk "AC-3 warn: only 1 mandated role → pass (warn, not fail)" "$(_run)" 0
  { for _i in 1 2 3 4; do printf '{"batch":"B1","subagent_type":"tb-code-reviewer"}\n'; done; } > "$T/.runs/r/dispatch.jsonl"
  touch "$T/enforce-marker"
  _chk "AC-4 enforce: 4× same role → fail (per-role, NOT a bare count)" "$(_run)" 1
  _disp '{"batch":"B1","subagent_type":"code-reviewer"}'   # generic: ≥1 ok but ∅ roles
  _chk "AC-2 enforce: generic-only (≥1 ok, ∅ attributed) → fail" "$(_run)" 1
  rm -f "$T/enforce-marker"
  _chk "AC-3 warn: generic-only → pass (warn)" "$(_run)" 0
  # AC-8 — the ≥1 total-collapse floor stays HARD under WARN: zero dispatch → fail even in warn
  rm -f "$T/.runs/r/dispatch.jsonl" "$T/enforce-marker"
  _chk "AC-8 warn + ZERO dispatch → still fail (≥1 floor hard under warn)" "$(_run)" 1
  # mvp subset {code-reviewer, regression-guardian}: covering both → pass enforce; missing one → fail
  _marker '{"run":"r","pipeline":"mvp","intends_code":true,"source":"harness","baseline_sha":"'"$base"'"}'
  { printf '{"batch":"B1","subagent_type":"tb-code-reviewer"}\n'; printf '{"batch":"B1","subagent_type":"regression-guardian"}\n'; } > "$T/.runs/r/dispatch.jsonl"
  touch "$T/enforce-marker"
  _chk "mvp enforce: subset both covered → pass" "$(_run)" 0
  _disp '{"batch":"B1","subagent_type":"tb-code-reviewer"}'   # missing regression-guardian
  _chk "mvp enforce: subset missing one → fail" "$(_run)" 1
  # override precedence (R5-NB4): TEAM_BOOTSTRAP_ROLE_FLOOR wins over marker presence
  _marker "{$MK}"; { printf '{"batch":"B1","subagent_type":"tb-code-reviewer"}\n'; } > "$T/.runs/r/dispatch.jsonl"
  touch "$T/enforce-marker"
  _chk "override: FLOOR=warn beats marker-present → pass" "$( cd "$T" && TEAM_BOOTSTRAP_RUN=r TEAM_BOOTSTRAP_ROLE_FLOOR=warn "$here/check-role-dispatch.sh" . >/dev/null 2>&1; echo $? )" 0
  rm -f "$T/enforce-marker"
  _chk "override: FLOOR=enforce beats marker-absent → fail" "$( cd "$T" && TEAM_BOOTSTRAP_RUN=r TEAM_BOOTSTRAP_ROLE_FLOOR=enforce "$here/check-role-dispatch.sh" . >/dev/null 2>&1; echo $? )" 1

  rm -rf "$T"
  if [ "$fail" -eq 0 ]; then echo "check-role-dispatch --self-test: OK"; exit 0; fi
  echo "check-role-dispatch --self-test: $fail case(s) FAILED" >&2; exit 1
fi

root="${1:-.}"
cd "$root" 2>/dev/null || { echo "check-role-dispatch: bad dir '$root'" >&2; exit 64; }
if _evaluate; then exit 0; else exit 1; fi
