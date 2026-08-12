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

# verdict ----------------------------------------------------------------------
if [ "$hard" -gt 0 ]; then
  echo "check-preconditions: $hard hard blocker(s) — STOP, do not enter Phase B until delivery can land." >&2
  exit 1
fi
# record_precond EXIT ITEMS_JSON — stamp the run marker's precond so the advisory is a
# BLOCKING, machine-readable fact (check-delivery.sh refuses to let Phase B proceed while
# precond.exit==2 and precond.ack!=true). Preserves an already-recorded ack. No marker => no-op.
record_precond() {
  local ex="$1" items="$2" marker mk ack newp prefix newmk
  marker="$(resolve_marker)"
  [ -n "$marker" ] && [ -f "$marker" ] || return 0
  mk="$(cat "$marker" 2>/dev/null || true)"
  [ -n "$mk" ] || return 0
  ack="$(field_bool "$mk" ack)"; [ "$ack" = "true" ] || ack="false"
  newp="\"precond\":{\"exit\":$ex,\"items\":[$items],\"ack\":$ack}"
  # Pure-bash rewrite — NO sed: the items text can contain '/' (e.g. "push/deploy"),
  # which would collide with a sed s/// delimiter, silently fail, and clobber the marker.
  prefix="${mk%,\"precond\":*}"                 # strip an existing trailing precond object
  if [ "$prefix" != "$mk" ]; then
    newmk="${prefix},${newp}}"
  else
    newmk="${mk%?},${newp}}"                    # no precond yet: insert before final brace
  fi
  case "$newmk" in
    \{*\})
      printf '%s\n' "$newmk" > "$marker" 2>/dev/null || true
      echo "check-preconditions: recorded precond(exit=$ex) to $marker — Phase B is blocked until acknowledged (ack:true)." >&2 ;;
    *)
      echo "check-preconditions: WARN — could not update precond in $marker; left unchanged." >&2 ;;
  esac
}

if [ "$advisory" -gt 0 ]; then
  echo "check-preconditions: $advisory advisory item(s) — surface these and get acknowledgement before Phase B." >&2
  record_precond 2 "$adv_items"
  exit 2
fi
record_precond 0 ""
echo "check-preconditions: deliverability clear."
exit 0
