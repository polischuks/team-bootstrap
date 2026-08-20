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
    # WS-B AC-B3a — baseline-unreachable is now HARD (ackable), not WARN: a run whose batch-window base
    # does not resolve cannot be diff-gated at all (an unenforceable window, not a cosmetic warning).
    if [ -n "$bs" ] && ! git -C "$dir" rev-parse --verify -q "${bs}^{commit}" >/dev/null 2>&1; then
      echo "HARD baseline_sha '$bs' does not resolve to a commit — the batch-window diff has no anchor (unenforceable)"
    fi
    # WS-B AC-B3b — operating-tree coherence: guard a SPLIT-BRAIN tree — the run's feature dir EXISTS here
    # but is INCOMPLETE (a partial checkout / the docs-contract exists in the specs/ parent but not fully in
    # THIS worktree). A wholly-ABSENT feature dir is NOT flagged: at Phase 0 (before Phase A) a greenfield
    # feature's spec.md/plan.md/tasks.md have not been generated yet — Phase A's specify/plan/tasks create
    # them — so firing on an absent dir would HARD-fail every greenfield delivery (review HIGH-1). Only a
    # present-but-partial dir is a coherence failure.
    feat="$(field_str "$mk" feature)"
    case "$feat" in
      ""|unknown) : ;;                          # no spec declared → nothing to check (direct/non-spec run)
      *)
        case "$feat" in *.md) fslug="$(dirname "$feat")" ;; *) fslug="${feat%/}" ;; esac
        if [ -d "$dir/$fslug" ]; then
          for _d in spec.md plan.md tasks.md; do
            [ -f "$dir/$fslug/$_d" ] || echo "HARD run's docs-contract '$fslug/$_d' absent though its dir '$fslug' exists — split-brain/partial operating tree (the feature is present but incomplete here)"
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
  ( cd "$dir" 2>/dev/null || exit 0
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
