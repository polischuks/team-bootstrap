#!/usr/bin/env bash
# check-preconditions.sh — deliverability gate, run at the END of Phase A.
#
# Phase A can produce a perfect spec/plan/tasks against a delivery path that is a
# wall: a remote that isn't reachable, a branch the deploy source never sees, a
# publication step that needs an authorization nobody asked for. Finding that out
# AFTER the files are written is the ten-second `git ls-remote` skipped at the plan.
# This runs the cheap machine checks up front so Phase B doesn't march into the wall.
#
# Checks (all best-effort, non-mutating):
#   1. remote reachable      — git ls-remote on the push remote
#   2. branch state          — is the current branch on the remote / does it diverge
#   3. deploy source         — detect a build-from-git target (Railway/Render/Fly/
#                              Vercel/Netlify/Heroku/GH Actions deploy) and say so
#   4. publication needs auth— if a deploy source exists, flag push/deploy as
#                              irreversible (see references/irreversibility.md)
#
# Usage: bin/check-preconditions.sh [project-dir]   # default: current dir
# Exit:  0 clear / N/A · 1 hard blocker (STOP) · 2 advisory (surface + confirm) · 64 bad usage
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/delivery-lib.sh
. "$here/delivery-lib.sh"

root="${1:-.}"
cd "$root" 2>/dev/null || { echo "check-preconditions: bad dir '$root'" >&2; exit 64; }

hard=0
advisory=0
adv_items=""   # JSON-array elements describing each advisory, recorded to the marker
_adv() { advisory=$((advisory + 1)); adv_items="${adv_items:+$adv_items,}\"$1\""; }

# _stamp_repro_env — soft, AUDIT-ONLY build-env provenance (milestone repro-env-posture, ADR-0013). On an armed
# intends_code run it records a flat `repro_env` array (container / os / bash / git / dirty + the honest
# non-observables egress:unverified, sandbox:unknown) via the shipped record_marker_list. It is EXIT-PRESERVING:
# it never touches hard/advisory, never calls exit, never blocks — check-delivery/verify-batch do NOT read
# repro_env. Container signals take injectable path/env overrides so it is testable without root/Docker.
# Kill-switch: TEAM_BOOTSTRAP_REPRO_ENV=off.
_stamp_repro_env() {
  [ "${TEAM_BOOTSTRAP_REPRO_ENV:-on}" = "off" ] && return 0
  local mk; mk="$(resolve_marker)"
  [ -n "$mk" ] && [ -f "$mk" ] || return 0
  [ "$(field_bool "$(cat "$mk")" intends_code)" = "true" ] || return 0   # own guard (record_precond does not check this)
  local container osv bashv gitv dirty tags
  if   [ -f "${REPRO_DOCKERENV:-/.dockerenv}" ];              then container="docker"
  elif [ -f "${REPRO_CONTAINERENV:-/run/.containerenv}" ];    then container="podman"
  elif grep -q  'kubepods' "${REPRO_PROC1_CGROUP:-/proc/1/cgroup}" 2>/dev/null; then container="k8s"
  elif grep -Eq 'docker|containerd|lxc' "${REPRO_PROC1_CGROUP:-/proc/1/cgroup}" 2>/dev/null; then container="docker"
  elif [ -n "${CODESPACES:-}" ];                              then container="codespaces"
  elif [ -n "${REMOTE_CONTAINERS:-}" ] || [ -n "${DEVCONTAINER:-}" ]; then container="devcontainer"
  else container="none"
  fi
  osv="$(uname -s 2>/dev/null)-$(uname -m 2>/dev/null)"
  bashv="${BASH_VERSION%%[!0-9.]*}"; bashv="$(printf '%s' "$bashv" | cut -d. -f1-2)"
  gitv="$(git --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)"
  dirty="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  # sanitize dynamic values to the fixed tag vocabulary (no ] } " can enter the marker shared with precond)
  _san() {
    local v="$1"
    v="${v//\"/}"; v="${v//]/}"; v="${v//\}/}"
    printf '%s' "$v"
  }
  osv="$(_san "$osv")"; bashv="$(_san "$bashv")"; gitv="$(_san "$gitv")"; dirty="$(_san "$dirty")"
  tags="\"container:$container\",\"os:$osv\",\"bash:$bashv\",\"git:$gitv\",\"dirty:$dirty\",\"egress:unverified\",\"sandbox:unknown\""
  record_marker_list repro_env "[$tags]" 2>/dev/null || true
  return 0
}

git rev-parse --git-dir >/dev/null 2>&1 || {
  echo "check-preconditions: not a git repository — no remote delivery path to verify."
  exit 0
}

# 1) remote reachable ----------------------------------------------------------
remote="$(git remote | grep -x origin || git remote | head -1 || true)"
if [ -z "$remote" ]; then
  echo "check-preconditions: no git remote configured — local-only project, nothing to reach."
else
  if git ls-remote --exit-code "$remote" >/dev/null 2>&1; then
    echo "check-preconditions: remote '$remote' REACHABLE."
  else
    echo "check-preconditions: HARD — remote '$remote' is configured but UNREACHABLE (auth/network/URL). Delivery cannot land." >&2
    hard=$((hard + 1))
  fi

  # 2) branch state ------------------------------------------------------------
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [ -n "$branch" ] && [ "$branch" != "HEAD" ]; then
    if git ls-remote --exit-code "$remote" "refs/heads/$branch" >/dev/null 2>&1; then
      local_sha="$(git rev-parse HEAD 2>/dev/null || true)"
      remote_sha="$(git ls-remote "$remote" "refs/heads/$branch" 2>/dev/null | awk '{print $1}')"
      if [ -n "$remote_sha" ] && [ "$local_sha" != "$remote_sha" ]; then
        echo "check-preconditions: branch '$branch' exists on '$remote' but DIVERGES from local — a build-from-git target would build stale code until you push."
        _adv "branch '$branch' diverges from '$remote' (build-from-git would build stale code until pushed)"
      else
        echo "check-preconditions: branch '$branch' is on '$remote' and up to date."
      fi
    else
      echo "check-preconditions: branch '$branch' is NOT on '$remote' — a build-from-git target cannot see it until pushed."
      _adv "branch '$branch' not on '$remote' (deploy cannot see it until pushed)"
    fi
  fi
fi

# 3) deploy source detection ---------------------------------------------------
deploy=""
for f in railway.json railway.toml nixpacks.toml Procfile render.yaml render.yml \
         fly.toml vercel.json netlify.toml app.json Dockerfile; do
  [ -f "$f" ] && deploy="$deploy $f"
done
if ls .github/workflows/*deploy* .github/workflows/*release* >/dev/null 2>&1; then
  deploy="$deploy .github/workflows(deploy)"
fi
if [ -n "$deploy" ]; then
  echo "check-preconditions: deploy source detected —$deploy. Confirm which branch it builds from."
  # 4) publication needs auth ------------------------------------------------
  echo "check-preconditions: ADVISORY — a build-from-git deploy makes push/deploy IRREVERSIBLE; it needs explicit per-call authorization (constitution P5; references/irreversibility.md)."
  _adv "build-from-git deploy detected — push/deploy is irreversible, needs per-call authorization (P5)"
else
  echo "check-preconditions: no build-from-git deploy source detected."
fi

# soft, audit-only build-env provenance stamp (exit-preserving; never blocks; check-delivery ignores it) -------
_stamp_repro_env

# verdict ----------------------------------------------------------------------
if [ "$hard" -gt 0 ]; then
  echo "check-preconditions: $hard hard blocker(s) — STOP, do not enter Phase B until delivery can land." >&2
  exit 1
fi
# record_precond (stamps the deliverability advisory into the run marker) now lives in delivery-lib.sh
# — one shared marker-write surgery for both precond and preflight, unit-tested via tests/preflight-setup.test.sh.

if [ "$advisory" -gt 0 ]; then
  echo "check-preconditions: $advisory advisory item(s) — surface these and get acknowledgement before Phase B." >&2
  record_precond 2 "$adv_items"
  exit 2
fi
record_precond 0 ""
echo "check-preconditions: deliverability clear."
exit 0
