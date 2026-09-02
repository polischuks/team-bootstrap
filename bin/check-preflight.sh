#!/usr/bin/env bash
# check-preflight.sh — Phase 0 SETUP-READINESS gate. Runs BEFORE Phase A.
#
# check-preconditions.sh (end of Phase A) answers "can the output LAND?" (remote, deploy source).
# This answers the OTHER half, at the START: "is the project scaffolded so the pre-implementation
# flow can even RUN correctly here?" A /deliver against a directory with no constitution / no specs/
# convention / no feature.json pointer / no docs/adr/ / no run marker will produce a spec-plan-tasks
# stack the downstream gates cannot enforce against, and the failure surfaces late (mid-Phase-B) or
# never (a gate no-ops because the marker is absent). This makes setup-readiness a machine verdict
# that fails CLOSED and is recorded to the run marker as a blocking fact (parity with precond) — the
# P10 invariant: a gate that structurally cannot run is a failure, not a silent skip.
#
# DETECT-AND-REPORT ONLY: never mutates the target project (no mkdir, no file creation).
#
# Checks (fail/warn split — see specs/preflight-setup-phase, OQ-2; RUNTIME probes added by
# pipeline-integrity-hardening WS-B):
#   HARD (exit 1): SCAFFOLD — not a git repo (non-ackable) · feature.json present+parseable · constitution
#                  (resolved VIA feature.json 'constitution' key) · specs dir · adr dir · run marker with
#                  intends_code:true + baseline_sha.
#                  READINESS (WS-B) — a runnable Test: command exists (AC-B1) · its binary resolves on
#                  PATH / as a file (AC-B2) · a present dep lockfile has its install dir (AC-B2) ·
#                  baseline_sha RESOLVES to a commit (AC-B3a, was WARN) · the marker's `feature`
#                  docs-contract (spec/plan/tasks.md) is present in the build tree (AC-B3b).
#   WARN (does not fail): specs/TEMPLATE absent.
# HARD gaps are ackable via a governed, dated waiver (delivery-lib governed_waiver_ok; enforced by
# check-delivery), NOT a bare one-time ack (WS-B AC-B5).
# A feature.json that DECLARES a constitution/specs_dir/adr_dir which does not resolve fails LOUD,
# naming the declared path (parity with check-completeness, 823a19f) — P11 (ground in mechanism).
#
# On completion, records preflight:{exit,gaps,ack} to the active run marker via record_preflight
# (delivery-lib), unless there is no marker or it is not intends_code (graceful skip, AC-5).
#
# Usage: bin/check-preflight.sh [project-dir]   # default: current dir
#        bin/check-preflight.sh --self-test
# Exit:  0 setup-ready (or graceful skip) · 1 fail-closed (>=1 HARD gap) · 64 bad usage
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/delivery-lib.sh
. "$here/delivery-lib.sh"

# _feature_val FILE KEY → top-level "KEY":"value" string from feature.json (grep-based, NO jq — the
# marker/feature path is deliberately jq-free for portability, drift #1). Empty if absent.
_feature_val() { [ -f "$1" ] && field_str "$(cat "$1" 2>/dev/null)" "$2"; }

# _stale_baseline_warn DIR BASELINE_SHA — issue #102. Emit a single WARN line (never HARD, never a
# non-zero verdict) when the run's baseline_sha is an ancestor of origin/<default> and behind by >=1
# commit: the "forked from a stale base" shape. That one fact is the root of the run's most expensive
# frictions — a missing run-rate CapabilityOptOut (#66), constitution/ADR drift, doc-commit-in-
# commit_shas (#93) — each of which otherwise surfaces as a SEPARATE fail-closed wall with no signal to
# rebase. Name the root ONCE, non-blocking (the operator may have a reason to fork off an old base).
#
# Default-branch resolution mirrors guard-git._branch_query / current_batch_base: origin/HEAD symbolic
# ref, else the first of origin/main|origin/master that resolves — never a hardcoded `main`. All refs
# read here are LOCAL remote-tracking refs (rev-parse / merge-base / rev-list / grep — no network), so
# this is offline-safe: if origin/<default> cannot be resolved (no remote / never fetched) it emits
# nothing and never errors. Inlined here (not a delivery-lib helper) to keep the change scoped to #102.
_stale_baseline_warn() {
  local dir="$1" bs="$2" def defref count cap
  [ -n "$bs" ] || return 0
  git -C "$dir" rev-parse --verify -q "${bs}^{commit}" >/dev/null 2>&1 || return 0   # unresolvable base → AC-B3a owns it
  # resolve origin/<default> to a LOCAL commit
  def="$(git -C "$dir" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)"
  if [ -n "$def" ] && git -C "$dir" rev-parse --verify -q "${def}^{commit}" >/dev/null 2>&1; then
    defref="$def"
  else
    defref=""
    for def in origin/main origin/master; do
      git -C "$dir" rev-parse --verify -q "${def}^{commit}" >/dev/null 2>&1 && { defref="$def"; break; }
    done
  fi
  [ -n "$defref" ] || return 0                                                       # no origin/<default> locally → silent (offline-safe)
  # only the stale-FORK shape: baseline is a strict ANCESTOR of the default tip. A baseline that is not an
  # ancestor (diverged, or ahead of the default) is a different situation the operator owns — stay silent.
  git -C "$dir" merge-base --is-ancestor "$bs" "$defref" 2>/dev/null || return 0
  count="$(git -C "$dir" rev-list --count "${bs}..${defref}" 2>/dev/null)"
  case "$count" in ''|*[!0-9]*) return 0 ;; esac
  [ "$count" -ge 1 ] || return 0                                                     # at the tip (behind by 0) → not stale → silent
  # cheap capability-drift hint: the run-rate CapabilityOptOut (#66) is present on the default tip's tree
  # but not on the baseline's. git grep against each tree-ish (no checkout); any failure ⇒ treated as absent.
  cap=""
  if git -C "$dir" grep -qI CapabilityOptOut "$defref" 2>/dev/null \
     && ! git -C "$dir" grep -qI CapabilityOptOut "$bs" 2>/dev/null; then
    cap=" A CapabilityOptOut (e.g. the run-rate enforcement opt-out, #66) exists on '$defref' but not on your baseline — arm it by rebasing rather than cherry-picking it back."
  fi
  echo "WARN stale baseline — baseline_sha '$bs' is an ancestor of origin default '$defref' and behind it by $count commit(s). A branch forked from a stale base fail-closes at every step (missing run-rate CapabilityOptOut, ADR/constitution drift, doc-commit-in-commit_shas) with no single signal — this is the common cause. Rebase onto '$defref' to avoid the fail-closed friction.${cap}"
}

# _scan DIR → print one gap line per problem: "HARD <msg>" (fail-closed) or "WARN <msg>" (advisory).
# Pure inspection of DIR; no cd side effects leak (marker lookup is scoped to DIR/.runs).
_scan() {
  local dir="$1" fj con sd ad mkfile mk bs tc tcbin feat fslug _d
  # not a git repo: no run can be anchored here at all — check-preflight fails outright and there is no
  # run marker to hold an ack (the non-git case is why the spec's separate "non-ackable class" is moot).
  if ! git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
    echo "HARD not a git repository — no delivery run can be anchored here (fix the repo; there is no run to ack)"
    return 0
  fi
  # WS-5 (harness-robustness): a target repo that TRACKS .runs/ makes the delivery gate Sisyphean — git
  # restores stale session markers under it, so `rm` never sticks and the Stop-hook re-blocks every
  # prompt (the retro's committed-.runs cascade, where deleting one orphan surfaced the next). Session
  # state must never be tracked. Fail HARD with the exact untrack remediation. No `| head` (WS-3): the
  # whole ls-files output is captured, non-empty ⇒ tracked.
  if [ -n "$(git -C "$dir" ls-files -- .runs/ 2>/dev/null)" ]; then
    echo "HARD .runs/ is TRACKED in git — session markers get restored and re-block every run; untrack them: git rm -r --cached .runs/ && echo '.runs/' >> .gitignore"
  fi
  # WS-6 (harness-robustness): plugin version skew. Hooks run from $CLAUDE_PLUGIN_ROOT; if that root's
  # VERSION differs from the VERSION of the bin/ actually invoked (this script, BASH_SOURCE-relative),
  # review-types.txt and gate logic diverge — the retro's 2.19.1-vs-2.28.0 skew where reviewer dispatches
  # went unrecognized. Detect-and-report WARN (advisory) with the reinstall remediation; matched → silent;
  # no $CLAUDE_PLUGIN_ROOT (bin run outside a session) → skipped.
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/VERSION" ]; then
    local hookv binv
    hookv="$(cat "${CLAUDE_PLUGIN_ROOT}/VERSION" 2>/dev/null)"
    binv="$(cat "$(dirname "${BASH_SOURCE[0]}")/../VERSION" 2>/dev/null)"
    if [ -n "$hookv" ] && [ -n "$binv" ] && [ "$hookv" != "$binv" ]; then
      echo "WARN plugin version skew — live hooks are $hookv (\$CLAUDE_PLUGIN_ROOT) but this bin is $binv; review-types.txt/gate logic can diverge (dispatches unrecognized). Reinstall the plugin so hooks and bin share one root."
    fi
  fi
  # feature.json present + minimally parseable
  fj="$dir/feature.json"
  if [ ! -f "$fj" ]; then
    echo "HARD missing: feature.json — the pre-impl flow has no active-spec pointer"
    fj=""   # can't resolve declared paths without it; fall back to defaults below
  elif ! grep -qE '"[a-zA-Z_]+"[[:space:]]*:' "$fj" 2>/dev/null; then
    echo "HARD feature.json present but not parseable (no JSON keys found)"
    fj=""
  fi
  # constitution — resolved VIA the feature.json key (default constitution.md); declared-but-missing = loud
  con="$(_feature_val "$fj" constitution)"; [ -n "$con" ] || con="constitution.md"
  [ -f "$dir/$con" ] || echo "HARD constitution '$con' (via feature.json) not found — no principles doc to gate against"
  # specs dir — feature.json specs_dir (default specs)
  sd="$(_feature_val "$fj" specs_dir)"; [ -n "$sd" ] || sd="specs"
  [ -d "$dir/$sd" ] || echo "HARD specs dir '$sd' not found — no milestone convention to write into"
  # adr dir — feature.json adr_dir (default docs/adr)
  ad="$(_feature_val "$fj" adr_dir)"; [ -n "$ad" ] || ad="docs/adr"
  [ -d "$dir/$ad" ] || echo "HARD adr dir '$ad' not found — architectural decisions have nowhere to land"
  # run marker — present with intends_code:true + baseline_sha
  mkfile="$(cd "$dir" 2>/dev/null && resolve_marker)"
  if [ -z "$mkfile" ] || [ ! -f "$dir/$mkfile" ]; then
    echo "HARD no run marker (.runs/<run>/RUN) — the delivery gate is unarmed here"
  else
    mk="$(cat "$dir/$mkfile" 2>/dev/null || true)"
    [ "$(field_bool "$mk" intends_code)" = "true" ] || echo "HARD run marker missing intends_code:true — gates would fail-open (silently skip)"
    bs="$(field_str "$mk" baseline_sha)"
    [ -n "$bs" ] || echo "HARD run marker missing baseline_sha — the batch-window diff has no anchor"

    # ADR-0018 (AC-7) — spec-artifact drift. When the milestone was already on disk, Phase A is
    # supposed to CHECK it, not re-draft it (deliver.md Mode 2). That skip cannot be observed
    # directly: record-dispatch matches Agent|Task, and speckit-specify is a *Skill*, so its
    # invocation is invisible to the harness. So the ARTIFACT is watched instead — hashed at run
    # start by delivery-marker-init, compared here.
    #
    # WARN, not HARD, for one release (OQ-3). Revising a spec mid-flight is legitimate and common;
    # blocking on an unvalidated heuristic would reproduce the false-block class ADR-0015 spent a
    # milestone removing. Arm it once there is real drift data.
    if [ "$(field_bool "$mk" spec_present)" = "true" ]; then
      _sp="$(field_str "$mk" spec_path)"
      _sdir="$(dirname "$_sp")"
      # Slice the list out of $mk directly. marker_list resolves the marker RELATIVE TO CWD, but this
      # gate is handed an explicit $dir and is routinely run from elsewhere — using it here read the
      # caller's own .runs/, not the scanned tree's, and silently found nothing.
      _al=""
      case "$mk" in *'"spec_artifacts":['*) _al="${mk#*\"spec_artifacts\":[}"; _al="[${_al%%]*}]" ;; esac
      if [ -n "$_al" ] && [ -n "$_sp" ]; then
        _rest="${_al#[}"
        while [ -n "$_rest" ]; do
          case "$_rest" in \{*) : ;; *) break ;; esac
          _rest="${_rest#\{}"
          _idx="$(_obj_span "$_rest")"; [ -n "$_idx" ] || break
          _body="{${_rest:0:_idx}}"; _rest="${_rest:_idx+1}"; _rest="${_rest#,}"
          _f="$(field_str "$_body" file)"; _want="$(field_str "$_body" sha256)"
          [ -n "$_f" ] && [ -n "$_want" ] || continue
          [ -f "$dir/$_sdir/$_f" ] || continue   # missing-recorded is HARD-owned by the AC-B3b coherence check below (issue #69); here we only compare hashes of files that ARE present
          _got="$( { shasum -a 256 "$dir/$_sdir/$_f" 2>/dev/null || sha256sum "$dir/$_sdir/$_f" 2>/dev/null; } | cut -d' ' -f1 )"
          [ -n "$_got" ] || continue
          [ "$_got" = "$_want" ] || echo "WARN spec artifact '$_f' CHANGED since run start — Phase A Mode 2 checks the milestone, it does not re-draft it. Legitimate only if a recorded analyze/architecture-reviewer finding called for the edit; otherwise a producing step re-ran over finished work (the 2h21m Phase A this gate exists to surface)."
        done
      fi
    fi
    # WS-B AC-B3a — baseline-unreachable is now HARD (ackable), not WARN: a run whose batch-window base
    # does not resolve cannot be diff-gated at all (an unenforceable window, not a cosmetic warning).
    if [ -n "$bs" ] && ! git -C "$dir" rev-parse --verify -q "${bs}^{commit}" >/dev/null 2>&1; then
      echo "HARD baseline_sha '$bs' does not resolve to a commit — the batch-window diff has no anchor (unenforceable)"
    fi
    # issue #102 — stale-baseline advisory (WARN, non-blocking; offline-safe). Only meaningful when the
    # baseline actually resolves, so it lives after the AC-B3a resolve check.
    _stale_baseline_warn "$dir" "$bs"
    # WS-B AC-B3b (+ issue #69) — operating-tree coherence: guard a SPLIT-BRAIN tree — the run's feature
    # dir EXISTS here but is INCOMPLETE. A wholly-ABSENT feature dir is NOT flagged: at Phase 0 (before
    # Phase A) a greenfield feature's spec/plan/tasks have not been generated yet — Phase A's
    # specify/plan/tasks create them — so firing on an absent dir would HARD-fail every greenfield
    # delivery (review HIGH-1).
    #
    # The original present-but-partial check fired on the mere ABSENCE of any of spec/plan/tasks. That
    # conflated two states it cannot tell apart by absence alone (issue #69):
    #   • Mode 2, pre-Phase-A: spec.md is on disk (spec_present) but plan.md/tasks.md are NOT YET produced
    #     — the normal precondition the flow exists to satisfy, not a partial tree.
    #   • genuine split-brain: plan.md/tasks.md WERE on disk at run start and are gone now — a producing
    #     step removed finished work.
    # The distinguishing signal is OBSERVABLE, not a guess: the run-start artifact ledger `spec_artifacts`
    # (each present artifact hashed by delivery-marker-init at arm time). A docs-contract OUTPUT
    # (plan/tasks) is a coherence failure only if it was RECORDED present at run start and is absent now;
    # one that was never recorded is to-be-produced by Phase A, not lost. spec.md is the flow INPUT: if
    # the feature dir exists at all, its anchoring spec must be present with it (a dir shell with no spec
    # is incoherent regardless of the ledger). Fail-closed stays intact for the genuine partial tree.
    feat="$(field_str "$mk" feature)"
    case "$feat" in
      ""|unknown) : ;;                          # no spec declared → nothing to check (direct/non-spec run)
      *)
        case "$feat" in *.md) fslug="$(dirname "$feat")" ;; *) fslug="${feat%/}" ;; esac
        if [ -d "$dir/$fslug" ]; then
          for _d in spec.md plan.md tasks.md; do
            [ -f "$dir/$fslug/$_d" ] && continue
            if [ "$_d" = spec.md ]; then
              echo "HARD run's spec '$fslug/$_d' absent though its dir '$fslug' exists — split-brain/partial operating tree (the feature's input spec is missing here)"
            else
              # OUTPUT: HARD only if recorded present at run start (a `"file":"<name>"` entry lives ONLY in
              # spec_artifacts; marker-init writes it with no spaces). Never-recorded ⇒ pre-Phase-A gap.
              case "$mk" in
                *"\"file\":\"$_d\""*) echo "HARD run's docs-contract '$fslug/$_d' was recorded present at run start but is absent now — a producing step removed finished work (genuine split-brain, not a pre-Phase-A gap)" ;;
                *) : ;;   # never recorded at run start → Phase A produces it → normal Mode-2 precondition, not a partial tree (issue #69)
              esac
            fi
          done
        fi ;;
    esac
  fi
  # WS-B AC-B1 — a runnable test command must exist (readiness, not just scaffold): a code run with no
  # Test:/CLAUDE Test: cannot be red-first-verified. HARD (ackable via a governed waiver).
  tc="$( cd "$dir" 2>/dev/null && _test_cmd )"
  if [ -z "$tc" ]; then
    echo "HARD no runnable test command — AGENTS.md/CLAUDE.md declares no \`Test:\` (a code run cannot be red-first-verified without one)"
  else
    # WS-E / AC-E3 — strip any leading ENV=val assignments (NODE_ENV=test npm test → npm test) before
    # resolving the binary, so an env-prefixed Test: does not false-HARD on the `NODE_ENV=test` token
    # (review #4). Anchored to the FIRST token only: a later assignment (`make VAR=x test`) must NOT strip
    # the real command word `make` and resolve the builtin `test` — that was a fail-open (WS-E arch review F1).
    while :; do
      case "${tc%%[[:space:]]*}" in
        [A-Za-z_]*=*)                                   # first token IS a NAME=val assignment → drop it
          case "$tc" in *[[:space:]]*) tc="${tc#*[[:space:]]}" ;; *) break ;; esac ;;
        *) break ;;                                     # first token is the real command (or no more) → stop
      esac
    done
    # WS-B AC-B2 — the declared toolchain resolves: the Test: command's binary is on PATH, a file in the
    # tree, or a project-local binary (node_modules/.bin, a venv) — BEFORE Phase B, rather than reactively
    # when quality-gate hits "command not found". Project-local paths (AC-E3) avoid a false-HARD on
    # venv/Yarn-PnP toolchains that are legitimately not on the global PATH.
    tcbin="${tc%% *}"
    if case "$tcbin" in
         */*) [ -e "$dir/$tcbin" ] || [ -e "$tcbin" ] ;;
         *)   command -v "$tcbin" >/dev/null 2>&1 \
              || [ -x "$dir/node_modules/.bin/$tcbin" ] \
              || [ -x "$dir/.venv/bin/$tcbin" ] || [ -x "$dir/venv/bin/$tcbin" ] ;;
       esac; then :; else
      echo "HARD test-command binary '$tcbin' not resolvable (not on PATH, not a file, not in node_modules/.bin or a venv) — the toolchain the Test: command needs is absent before Phase B"
    fi
  fi
  # WS-B AC-B2 / WS-E AC-E3 — declared-dependency presence is a WARN, not HARD: a lockfile with no install
  # dir usually means deps were not provisioned (run the Prepare: step), but Yarn PnP legitimately ships a
  # lockfile with NO node_modules — a HARD here false-blocks a valid project (review #4). Advisory only.
  if { [ -f "$dir/package-lock.json" ] || [ -f "$dir/yarn.lock" ] || [ -f "$dir/pnpm-lock.yaml" ]; } && [ ! -d "$dir/node_modules" ]; then
    echo "WARN dependency lockfile present but node_modules/ absent — if not Yarn PnP, provision deps via the Prepare: step before Phase B"
  fi
  # issue #124 — speckit runner presence (readiness, WARN). Phase A's producing chain (deliver.md steps
  # 4–6: speckit-plan/tasks/analyze) drives a setup runner under .specify/scripts/bash/…. A repo that
  # ships only the speckit TEMPLATES has no runner, so those skills produce NOTHING — a fail-quiet the
  # operator discovers only when plan.md/tasks.md come back empty mid-flow (observed live on M108). Detect
  # it and name it, so the operator authors the producing artifacts by hand rather than invoking empty
  # shells. WARN not HARD: producing manually is a legitimate mode (this plugin's own repo has no runner),
  # so this states the mode; it does not block the run.
  if [ ! -d "$dir/.specify/scripts/bash" ] || ! ls "$dir"/.specify/scripts/bash/* >/dev/null 2>&1; then
    echo "WARN speckit runner absent — .specify/scripts/bash/* not found; the Phase-A producing skills (speckit-plan/speckit-tasks/speckit-analyze) have no runner here and produce nothing. Author spec.md/plan.md/tasks.md manually (deliver.md Phase A templates-only note), or provision the runner."
  fi
  # warn-level scaffold
  [ -d "$dir/$sd/TEMPLATE" ] || echo "WARN $sd/TEMPLATE absent — a milestone can copy a prior spec's structure, but the template helps"
}

# _run DIR → run the scan, print human lines, record the verdict, return the exit code (0 ready / 1 hard).
_run() {
  local dir="$1" gaps hard=0 line msg arr="" ex=0
  dir="$(cd "$dir" 2>/dev/null && pwd)" || { echo "check-preflight: bad dir '$1'" >&2; return 64; }
  gaps="$(_scan "$dir")"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    msg="${line#* }"
    case "$line" in
      HARD*) hard=$((hard + 1))
             echo "check-preflight: HARD — $msg" >&2
             # JSON-escape before interpolating into the recorded gaps array: a feature.json path
             # value can carry a backslash (field_str stops at the first '"', so `a\"b` is captured as
             # `a\`), which would otherwise write an invalid \-escape into the marker. sed on stdin with
             # FIXED patterns (no value in the s/// delimiter → no '/'-in-path collision); escape '\'
             # first, then '"'. Keeps the marker valid JSON on any input (review nb#1).
             msg="$(printf '%s' "$msg" | sed 's/\\/\\\\/g; s/"/\\"/g')"
             arr="${arr:+$arr,}\"$msg\"" ;;
      WARN*) echo "check-preflight: WARN — $msg" >&2 ;;
    esac
  done <<EOF
$gaps
EOF
  [ "$hard" -gt 0 ] && ex=1
  # record the verdict to the active marker (scoped to DIR), unless graceful-skip (AC-5)
  ( cd "$dir" 2>/dev/null || exit 0   # gate-integrity: sanctioned — exits the SUBSHELL, not the gate; the caller still evaluates
    mk_="$(resolve_marker)"
    if [ -n "$mk_" ] && [ -f "$mk_" ] && [ "$(field_bool "$(cat "$mk_")" intends_code)" = "true" ]; then
      record_preflight "$ex" "[$arr]"
    fi )
  if [ "$ex" -eq 0 ]; then
    echo "check-preflight: setup-ready."
  else
    echo "check-preflight: $hard setup gap(s) — STOP, scaffold before Phase A (or ack a scaffold gap in the run marker)." >&2
  fi
  return "$ex"
}

# ---------------------------------------------------------------------------------------------------
_self_test() {
  local fail=0 T bt out rc gaps
  _scaffold() { # DIR — write a full, valid scaffold + an armed run marker anchored to a real commit
    local d="$1" sha
    git -C "$d" init -q
    printf '# constitution\n' > "$d/constitution.md"
    printf '{\n  "active_spec": "specs/x",\n  "specs_dir": "specs",\n  "constitution": "constitution.md",\n  "adr_dir": "docs/adr"\n}\n' > "$d/feature.json"
    mkdir -p "$d/specs/TEMPLATE" "$d/docs/adr"
    printf 'Test: `true`\n' > "$d/AGENTS.md"
    git -C "$d" add -A >/dev/null 2>&1
    git -C "$d" -c user.email=t@t -c user.name=t commit -q -m init >/dev/null 2>&1
    sha="$(git -C "$d" rev-parse --short HEAD)"
    mkdir -p "$d/.runs/r"
    printf '{"run":"r","intends_code":true,"baseline_sha":"%s"}\n' "$sha" > "$d/.runs/r/RUN"
  }
  _expect() { # LABEL DIR WANT_RC
    # Hermetic: unset any ambient TEAM_BOOTSTRAP_RUN so resolve_marker falls back to `ls .runs/*/RUN` in the
    # scaffolded DIR (finding its own run), instead of an outer delivery run that isn't present in DIR — else
    # the self-test spuriously reports "missing run marker" when run under an active delivery (e.g. verify-batch
    # → check-tdd → run-tests exports TEAM_BOOTSTRAP_RUN).
    local o r; o="$(env -u TEAM_BOOTSTRAP_RUN "$0" "$2" 2>&1)"; r=$?
    if [ "$r" -eq "$3" ]; then echo "  PASS $1"; else
      echo "  FAIL $1 — want rc=$3 got $r; out: $o" >&2; fail=$((fail + 1)); fi
  }

  # AC-1 — fully scaffolded → exit 0, records preflight:exit0
  T="$(mktemp -d)"; _scaffold "$T"; _expect "all present → ready (0)" "$T" 0
  grep -q '"preflight":{"exit":0' "$T/.runs/r/RUN" || { echo "  FAIL preflight:exit0 not recorded" >&2; fail=$((fail + 1)); }
  # AC-2/AC-3 — one HARD per required element
  T="$(mktemp -d)"; _scaffold "$T"; rm -f "$T/feature.json"; _expect "missing feature.json → fail (1)" "$T" 1
  T="$(mktemp -d)"; _scaffold "$T"; rm -rf "$T/docs/adr"; _expect "missing docs/adr → fail (1)" "$T" 1
  T="$(mktemp -d)"; _scaffold "$T"; rm -f "$T/constitution.md"; _expect "missing constitution → fail (1)" "$T" 1
  T="$(mktemp -d)"; _scaffold "$T"; rm -rf "$T/specs"; _expect "missing specs/ → fail (1)" "$T" 1
  T="$(mktemp -d)"; _scaffold "$T"; rm -rf "$T/.runs"; _expect "missing run marker → fail (1)" "$T" 1
  # AC-3 — declared-but-unresolvable constitution fails loud
  T="$(mktemp -d)"; _scaffold "$T"
  printf '{"constitution":"nope.md","specs_dir":"specs","adr_dir":"docs/adr"}\n' > "$T/feature.json"
  out="$("$0" "$T" 2>&1)"; rc=$?
  if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "nope.md"; then echo "  PASS declared-but-unresolvable constitution → loud fail"; else
    echo "  FAIL declared-but-unresolvable constitution (rc=$rc)" >&2; fail=$((fail + 1)); fi
  # warn-only: TEMPLATE absent does NOT fail (still a WARN)
  T="$(mktemp -d)"; _scaffold "$T"; rm -rf "$T/specs/TEMPLATE"; _expect "no TEMPLATE → still ready (0, WARN only)" "$T" 0
  # WS-B AC-B1 — no runnable Test: (AGENTS.md absent, no CLAUDE.md) → HARD (was WARN pre-WS-B)
  T="$(mktemp -d)"; _scaffold "$T"; rm -f "$T/AGENTS.md"
  git -C "$T" -c user.email=t@t -c user.name=t commit -aqm "drop AGENTS" >/dev/null 2>&1
  _expect "AC-B1 no runnable Test: command → HARD fail (1)" "$T" 1
  # WS-B AC-B2 — Test: binary not resolvable → HARD
  T="$(mktemp -d)"; _scaffold "$T"; printf '# AGENTS\n\n- Test: `no-such-bin-zzz run`\n' > "$T/AGENTS.md"
  git -C "$T" -c user.email=t@t -c user.name=t commit -aqm "bad tool" >/dev/null 2>&1
  _expect "AC-B2 Test: binary absent → HARD fail (1)" "$T" 1
  # WS-B AC-B3a — baseline_sha unresolvable → HARD (was WARN)
  T="$(mktemp -d)"; _scaffold "$T"; printf '{"run":"r","intends_code":true,"baseline_sha":"deadbeef"}\n' > "$T/.runs/r/RUN"
  _expect "AC-B3a baseline_sha unresolvable → HARD fail (1)" "$T" 1
  # WS-B AC-B3b — the marker's feature docs-contract absent from the tree → HARD
  T="$(mktemp -d)"; _scaffold "$T"; mkdir -p "$T/specs/y"
  sha_b="$(git -C "$T" rev-parse --short HEAD)"
  printf '{"run":"r","intends_code":true,"baseline_sha":"%s","feature":"specs/y"}\n' "$sha_b" > "$T/.runs/r/RUN"
  _expect "AC-B3b feature docs-contract absent (split-brain tree) → HARD fail (1)" "$T" 1
  # issue #69 — a docs-contract file that was NEVER present at run start (plan.md/tasks.md not yet
  # produced) must be distinguished from one that was RECORDED present then LOST. The run-start artifact
  # ledger (spec_artifacts, hashed by delivery-marker-init) is the observable signal.
  _mode2run() { # DIR "extra-recorded-among:plan.md tasks.md" — Mode-2 marker: spec.md ON DISK, feature dir present
    local d="$1" extra="$2" sha sh art a
    mkdir -p "$d/specs/f"; printf '# spec\n' > "$d/specs/f/spec.md"
    sh="$( { shasum -a 256 "$d/specs/f/spec.md" 2>/dev/null || sha256sum "$d/specs/f/spec.md" 2>/dev/null; } | cut -d' ' -f1 )"
    art="{\"file\":\"spec.md\",\"sha256\":\"$sh\"}"
    for a in $extra; do art="$art,{\"file\":\"$a\",\"sha256\":\"deadbeefdeadbeef\"}"; done
    sha="$(git -C "$d" rev-parse --short HEAD)"
    printf '{"run":"r","intends_code":true,"baseline_sha":"%s","feature":"specs/f/spec.md","spec_present":true,"spec_path":"specs/f/spec.md","spec_artifacts":[%s]}\n' "$sha" "$art" > "$d/.runs/r/RUN"
  }
  # #69(a) — spec-only start (spec_present, spec.md on disk, plan/tasks NOT yet produced, before Phase A):
  # NOT a split-brain failure. Only spec.md was on disk at run start, so plan.md/tasks.md were never
  # recorded — their absence is the precondition Phase A exists to satisfy, not a partial tree.
  T="$(mktemp -d)"; _scaffold "$T"; _mode2run "$T" ""
  out="$(env -u TEAM_BOOTSTRAP_RUN "$0" "$T" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -q 'split-brain'; then
    echo "  PASS #69(a) spec-only pre-Phase-A start → NOT split-brain (0)"
  else
    echo "  FAIL #69(a) spec-only start flagged as split-brain — rc=$rc; out: $out" >&2; fail=$((fail + 1)); fi
  # #69(b) — a dir that genuinely LOST plan/tasks after they existed still fails: plan.md/tasks.md were
  # RECORDED in spec_artifacts at run start but are absent now (a producing step removed finished work).
  T="$(mktemp -d)"; _scaffold "$T"; _mode2run "$T" "plan.md tasks.md"
  out="$(env -u TEAM_BOOTSTRAP_RUN "$0" "$T" 2>&1)"; rc=$?
  if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'HARD.*recorded present at run start but is absent now'; then
    echo "  PASS #69(b) recorded-then-lost plan/tasks → HARD fail (1)"
  else
    echo "  FAIL #69(b) recorded-then-lost plan/tasks not caught — rc=$rc; out: $out" >&2; fail=$((fail + 1)); fi
  # not a git repo → fail-closed (non-ackable)
  T="$(mktemp -d)"; _expect "not a git repo → fail (1)" "$T" 1
  # AC-5 graceful skip — marker not intends_code: records nothing, exits on scaffold verdict (ready)
  T="$(mktemp -d)"; _scaffold "$T"; printf '{"run":"r","intends_code":false,"baseline_sha":"x"}\n' > "$T/.runs/r/RUN"
  # (intends_code:false makes the marker check HARD-fail, which is correct — but recording must be skipped)
  "$0" "$T" >/dev/null 2>&1 || true
  if grep -q '"preflight"' "$T/.runs/r/RUN"; then echo "  FAIL recorded into a non-intends_code marker (should skip, AC-5)" >&2; fail=$((fail + 1)); else
    echo "  PASS AC-5 graceful skip — no record when not intends_code"; fi
  # marker integrity (review nb#1): a declared path whose captured value ends in a backslash must NOT
  # write an invalid \-escape into the recorded gaps — the marker stays valid JSON.
  T="$(mktemp -d)"; _scaffold "$T"
  printf '{"specs_dir":"a\\"b","constitution":"constitution.md","adr_dir":"docs/adr"}\n' > "$T/feature.json"
  "$0" "$T" >/dev/null 2>&1 || true
  if python3 -c 'import sys,json; json.load(open(sys.argv[1]))' "$T/.runs/r/RUN" >/dev/null 2>&1; then
    echo "  PASS marker stays valid JSON with backslash-bearing declared path"
  else
    echo "  FAIL marker corrupted (invalid JSON) by backslash in a gap message" >&2; fail=$((fail + 1)); fi
  # issue #124 — speckit-runner detection. Absent .specify/scripts/bash → WARN (names it), rc still 0
  # (WARN never fails); present+non-empty → no such WARN.
  T="$(mktemp -d)"; _scaffold "$T"
  out="$(env -u TEAM_BOOTSTRAP_RUN "$0" "$T" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'speckit runner absent'; then
    echo "  PASS #124 speckit runner absent → WARN (still ready, 0)"
  else
    echo "  FAIL #124 speckit-runner WARN not emitted (rc=$rc)" >&2; fail=$((fail + 1)); fi
  T="$(mktemp -d)"; _scaffold "$T"; mkdir -p "$T/.specify/scripts/bash"; printf '#!/bin/sh\n' > "$T/.specify/scripts/bash/setup.sh"
  out="$(env -u TEAM_BOOTSTRAP_RUN "$0" "$T" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -q 'speckit runner absent'; then
    echo "  PASS #124 speckit runner present → no WARN"
  else
    echo "  FAIL #124 speckit-runner WARN emitted despite present runner (rc=$rc)" >&2; fail=$((fail + 1)); fi
  # AC-9 — bare git dir names >=4 HARD gaps
  bt="$(mktemp -d)"; git -C "$bt" init -q
  out="$("$0" "$bt" 2>&1)"; rc=$?; gaps="$(printf '%s\n' "$out" | grep -c 'HARD')"
  if [ "$rc" -eq 1 ] && [ "$gaps" -ge 4 ]; then echo "  PASS bare git dir → fail-closed, $gaps HARD gaps"; else
    echo "  FAIL bare git dir (rc=$rc gaps=$gaps)" >&2; fail=$((fail + 1)); fi

  [ "$fail" -eq 0 ] && { echo "check-preflight --self-test: OK"; return 0; }
  echo "check-preflight --self-test: $fail failure(s)" >&2; return 1
}

case "${1:-}" in
  --self-test) _self_test; exit $? ;;
  -h|--help) grep '^# ' "$0" | sed 's/^# //'; exit 0 ;;
  "") _run "."; exit $? ;;
  -*) echo "check-preflight: unknown option '$1'" >&2; exit 64 ;;
  *)  _run "$1"; exit $? ;;
esac
