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

# Require an explicit CODE-pipeline token (single-thread|mvp|full). This confirms a real delivery
# run and excludes analysis pipelines (audit/audit-dd/l2p) that ship no code — arming those with
# intends_code:true would falsely demand a code closure. /deliver with no token defaults to full.
pipeline=""
printf '%s' "$payload" | grep -qE '(^|[^A-Za-z])single-thread([^A-Za-z]|$)' && pipeline="single-thread"
printf '%s' "$payload" | grep -qE '(^|[^A-Za-z])full([^A-Za-z]|$)'          && pipeline="${pipeline:-full}"
printf '%s' "$payload" | grep -qE '(^|[^A-Za-z])mvp([^A-Za-z]|$)'           && pipeline="${pipeline:-mvp}"
if [ -z "$pipeline" ]; then
  [ "$is_deliver" -eq 1 ] && pipeline="full" || exit 0   # /deliver defaults to full; bare skill needs a token
fi

# Derive the run name + feature from a specs/<slug>[/…] path in the prompt; else a stable fallback.
# The trailing path is OPTIONAL: `/deliver full specs/<slug>` (a bare directory, no /spec.md) must still
# be captured — else `feature` falls to "unknown" and the completeness gate can only skip (green-by-skip;
# see check-completeness.sh). Both `specs/<slug>` and `specs/<slug>/spec.md` derive run=<slug>.
spec="$(printf '%s' "$payload" | grep -oE 'specs/[A-Za-z0-9._-]+(/[A-Za-z0-9._/-]*)?' | head -1)"
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
[ -f "$marker" ] && exit 0                      # idempotent: never clobber baseline_sha
base="$(git rev-parse --short HEAD 2>/dev/null || true)"
# Normalize the feature to the spec.md PATH check-completeness expects: a bare dir/slug gets /spec.md
# appended (a value already ending in .md is left as-is; no specs path ⇒ "unknown", the no-spec sentinel).
feat="${spec:-unknown}"
case "$feat" in unknown|*.md) : ;; *) feat="${feat%/}/spec.md" ;; esac
# Write baseline_sha only when HEAD resolves. A bogus "unknown" would silently disarm the
# predate check (R-3); omitting it is honest — reachable-from-HEAD (R-2) still anchors closure.
if [ -n "$base" ]; then
  printf '{"run":"%s","pipeline":"%s","source":"harness","feature":"%s","intends_code":true,"baseline_sha":"%s","precond":{"exit":0,"items":[],"ack":false}}\n' \
    "$run" "$pipeline" "$feat" "$base" > "$marker" 2>/dev/null || true
else
  printf '{"run":"%s","pipeline":"%s","source":"harness","feature":"%s","intends_code":true,"precond":{"exit":0,"items":[],"ack":false}}\n' \
    "$run" "$pipeline" "$feat" > "$marker" 2>/dev/null || true
fi
printf 'delivery-marker-init: wrote harness RUN marker %s (run=%s pipeline=%s)\n' "$marker" "$run" "$pipeline" >&2
exit 0
