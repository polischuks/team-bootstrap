#!/usr/bin/env bash
# repro-env-posture.test.sh — black-box spec for the soft, audit-only `repro_env` provenance stamp folded into
# bin/check-preconditions.sh (milestone repro-env-posture, v2.27.0). Drives check-preconditions with injectable
# REPRO_* overrides + a temp marker; asserts the stamp records provenance WITHOUT changing any exit code and
# WITHOUT clobbering the sibling precond object. Written BEFORE the stamp exists → fails red, then green.
#
# Round-1/2: NOT a standalone bin/check-repro-env.sh (unconsumed) and NOT a check-preconditions --self-test
# (that gate has none). The stamp is exit-preserving; check-delivery/verify-batch never read repro_env.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
PRE="$here/../bin/check-preconditions.sh"

fail=0
_chk() { if [ "$1" = "$2" ]; then echo "  PASS $3"; else echo "  FAIL $3 (got '$1' want '$2')" >&2; fail=$((fail + 1)); fi; }

# temp git repo with NO remote (⇒ check-preconditions is deterministic + offline) and an armed intends_code marker
T="$(mktemp -d)"
(
  cd "$T" || exit 1
  git init -q; git symbolic-ref HEAD refs/heads/main 2>/dev/null || true
  git config user.email t@t && git config user.name t
  echo base > f && git add . && git commit -qm base
  mkdir -p .runs/r
) >/dev/null 2>&1
MK="$T/.runs/r/RUN"
DOCK="$T/_dockerenv"; : > "$DOCK"
CG="$T/_cgroup"; printf '12:pids:/kubepods/podX\n' > "$CG"
CGD="$T/_cgroup_d"; printf '1:name=systemd:/docker/abc\n' > "$CGD"

_reset() { printf '{"run":"r","pipeline":"full","intends_code":true,"source":"harness","baseline_sha":"x"}\n' > "$MK"; }
# _run 'VAR=val ...'  → run check-preconditions in the repo under run 'r' with extra env; echo exit code
# shellcheck disable=SC2086
_run() { ( cd "$T" && env $1 TEAM_BOOTSTRAP_RUN=r bash "$PRE" >/dev/null 2>&1 ); echo $?; }
_repro() { grep -o '"repro_env":\[[^]]*\]' "$MK" 2>/dev/null; }
_has() { _repro | grep -q "\"$1\"" && echo yes || echo no; }
_has_re() { _repro | grep -Eq "$1" && echo yes || echo no; }

echo "AC-1 — container detection (injectable, jq-free, no root):"
_reset; _run "REPRO_DOCKERENV=$DOCK REPRO_PROC1_CGROUP=/nope" >/dev/null; _chk "$(_has container:docker)" yes "REPRO_DOCKERENV present → container:docker"
_reset; _run "REPRO_DOCKERENV=/nope REPRO_PROC1_CGROUP=$CG"   >/dev/null; _chk "$(_has container:k8s)"    yes "cgroup kubepods → container:k8s"
_reset; _run "REPRO_DOCKERENV=/nope REPRO_PROC1_CGROUP=$CGD"  >/dev/null; _chk "$(_has container:docker)" yes "cgroup docker → container:docker"
_reset; _run "REPRO_DOCKERENV=/nope REPRO_CONTAINERENV=/nope REPRO_PROC1_CGROUP=/nope CODESPACES=true" >/dev/null; _chk "$(_has container:codespaces)" yes "CODESPACES=true → container:codespaces"
_reset; _run "REPRO_DOCKERENV=/nope REPRO_CONTAINERENV=/nope REPRO_PROC1_CGROUP=/nope" >/dev/null; _chk "$(_has container:none)" yes "no signal → container:none (no false positive)"

echo "AC-2 — toolchain/OS + dirty provenance:"
_reset; _run "REPRO_DOCKERENV=/nope REPRO_PROC1_CGROUP=/nope" >/dev/null
_chk "$(_has_re 'os:[A-Za-z]+-[A-Za-z0-9_]+')" yes "os:<uname-s>-<uname-m> present"
_chk "$(_has_re 'bash:[0-9]+\.[0-9]+')"        yes "bash:<major.minor> present"
_chk "$(_has_re 'git:[0-9]+\.[0-9]+')"         yes "git:<major.minor> present"
# the recorded dirty:N must equal `git status --porcelain | wc -l`, as a bare int (no macOS wc left-pad)
( cd "$T" && : > untracked_x ) ; _reset; _run "REPRO_DOCKERENV=/nope REPRO_PROC1_CGROUP=/nope" >/dev/null
want_dirty="dirty:$( ( cd "$T" && git status --porcelain 2>/dev/null | wc -l | tr -d ' ' ) )"
_chk "$(_has "$want_dirty")" yes "$want_dirty matches git status (bare int, no wc left-pad)"
( cd "$T" && rm -f untracked_x )

echo "AC-3 — exit-preserving (the stamp changes NO exit code):"
_reset; ec0="$(_run "REPRO_DOCKERENV=/nope REPRO_PROC1_CGROUP=/nope")"
_chk "$ec0" 0 "no-remote/no-deploy repo → exit 0 (unchanged by the stamp)"
_chk "$(_has_re 'container:')" yes "  …and repro_env WAS recorded on the exit-0 path"
_chk "$(grep -q '"precond":{' "$MK" && echo yes || echo no)" yes "  …and precond still recorded (sibling intact)"
( cd "$T" && : > Dockerfile )   # a deploy source → advisory → exit 2
_reset; ec2="$(_run "REPRO_DOCKERENV=/nope REPRO_PROC1_CGROUP=/nope")"
_chk "$ec2" 2 "deploy-source repo → exit 2 (advisory path unchanged by the stamp)"
_chk "$(_has_re 'container:')" yes "  …and repro_env recorded on the exit-2 path too"
( cd "$T" && rm -f Dockerfile )

echo "AC-4 — off-delivery no-op + kill-switch:"
rm -f "$T/.runs/absent/RUN" 2>/dev/null
ecx="$( ( cd "$T" && env REPRO_DOCKERENV=/nope TEAM_BOOTSTRAP_RUN=absent bash "$PRE" >/dev/null 2>&1 ); echo $? )"
_chk "$([ -f "$T/.runs/absent/RUN" ] && echo yes || echo no)" no "no active marker → nothing recorded"
# Audit 2026-08: $ecx was captured but never asserted — a dead variable shellcheck could not see, because
# a misplaced `# shellcheck disable` directive above stopped its parse at line 32. AC-4's claim is a NO-OP,
# and a no-op is an exit code as much as an absent marker, so assert it.
_chk "$ecx" 0 "no active marker → exit code unchanged (no-op, not a failure)"
_reset; _run "REPRO_DOCKERENV=$DOCK REPRO_PROC1_CGROUP=/nope TEAM_BOOTSTRAP_REPRO_ENV=off" >/dev/null
_chk "$(_has_re 'container:')" no  "TEAM_BOOTSTRAP_REPRO_ENV=off → no repro_env stamp"
_chk "$(grep -q '"precond":{' "$MK" && echo yes || echo no)" yes "  …but precond behaviour intact (still recorded)"

echo "AC-5 — honest non-observables pinned (P11):"
_reset; _run "REPRO_DOCKERENV=/nope REPRO_PROC1_CGROUP=/nope" >/dev/null
_chk "$(_has egress:unverified)" yes "egress:unverified always"
_chk "$(_has sandbox:unknown)"   yes "sandbox:unknown always"
_chk "$(_has_re 'egress:(restricted|open)')" no "never a guessed egress state"

echo "AC-6 — flat-array marker discipline + idempotence + no sibling clobber:"
_reset; _run "REPRO_DOCKERENV=$DOCK REPRO_PROC1_CGROUP=/nope" >/dev/null
_chk "$(_repro | grep -Eq '^"repro_env":\[[A-Za-z0-9:._,"/ -]*\]$' && echo ok || echo bad)" ok "flat tag vocab — no stray ] } inside items"
n1="$(_repro | grep -o 'container:' | wc -l | tr -d ' ')"
_run "REPRO_DOCKERENV=$DOCK REPRO_PROC1_CGROUP=/nope" >/dev/null   # re-probe
n2="$(_repro | grep -o 'container:' | wc -l | tr -d ' ')"
_chk "$n2" "$n1" "re-probe OVERWRITES (not append) — single repro_env"
_chk "$(grep -q '"precond":{' "$MK" && echo yes || echo no)" yes "writing repro_env did NOT clobber precond"

echo "AC-7 — no timeout dependency (holds on ANY host):"
# Audit 2026-08: the old assert was `command -v timeout` → `absent`, which tested the AUTHOR'S machine, not
# the code — red on any host that ships GNU coreutils. What AC-7 actually claims is that the stamp never
# wraps a timeout, so assert THAT against the source, keep the behavioural check, and demote the host's
# timeout to a printed note. Pattern catches both the wrap (`timeout 5 …`, `to="gtimeout 5"`) and the probe.
_chk "$(grep -cE 'g?timeout[[:space:]]+[0-9]|command -v[[:space:]]+g?timeout' "$PRE" | tr -d ' ')" 0 \
  "check-preconditions.sh never invokes or probes timeout/gtimeout — nothing to depend on"
echo "  note: this host has $(command -v timeout >/dev/null 2>&1 && echo 'timeout' || echo 'no timeout') on PATH"
_reset; ecb="$(_run "REPRO_DOCKERENV=$DOCK REPRO_PROC1_CGROUP=/nope")"
_chk "$ecb" 0 "records fine either way — with or without timeout on PATH"

rm -rf "$T"
if [ "$fail" -eq 0 ]; then echo "repro-env-posture.test.sh: OK"; exit 0; fi
echo "repro-env-posture.test.sh: $fail case(s) FAILED" >&2; exit 1
