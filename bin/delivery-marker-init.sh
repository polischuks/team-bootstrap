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
# Exit: always 0 (non-blocking). Stdout is intentionally empty (UserPromptSubmit
# stdout is injected as context; we add none).
set -uo pipefail

[ "${TEAM_BOOTSTRAP_DELIVERY_GATE:-on}" = "off" ] && exit 0

payload="$(cat 2>/dev/null || true)"
[ -n "$payload" ] || exit 0

# Detect a /deliver invocation. The bundled command is /team-bootstrap:commands:deliver
# (so "commands:deliver" is the reliable signature); also accept a bare "/deliver".
printf '%s' "$payload" | grep -qE 'commands:deliver|(^|[^A-Za-z])/deliver([^A-Za-z]|$)|:deliver' || exit 0

# Require an explicit pipeline token, so an incidental mention of the word "deliver"
# in some other prompt does not spuriously arm a delivery run.
pipeline=""
printf '%s' "$payload" | grep -qE '(^|[^A-Za-z])full([^A-Za-z]|$)' && pipeline="full"
printf '%s' "$payload" | grep -qE '(^|[^A-Za-z])mvp([^A-Za-z]|$)'  && pipeline="${pipeline:-mvp}"
[ -n "$pipeline" ] || exit 0

# Derive the run name from a specs/<slug>/… path in the prompt; else a stable fallback.
spec="$(printf '%s' "$payload" | grep -oE 'specs/[A-Za-z0-9._-]+/[A-Za-z0-9._/-]*' | head -1)"
run="$(printf '%s' "$spec" | sed -E 's#specs/([^/]+)/.*#\1#')"
[ -n "$run" ] || run="deliver-run"

marker=".runs/$run/RUN"
[ -f "$marker" ] && exit 0                      # idempotent: never clobber baseline_sha
mkdir -p ".runs/$run" 2>/dev/null || exit 0
base="$(git rev-parse --short HEAD 2>/dev/null || printf 'unknown')"
feat="${spec:-unknown}"
printf '{"run":"%s","pipeline":"%s","source":"harness","feature":"%s","intends_code":true,"baseline_sha":"%s","precond":{"exit":0,"items":[],"ack":false}}\n' \
  "$run" "$pipeline" "$feat" "$base" > "$marker" 2>/dev/null || true
printf 'delivery-marker-init: wrote harness RUN marker %s (run=%s pipeline=%s)\n' "$marker" "$run" "$pipeline" >&2
exit 0
