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

# Derive the run name + feature from a specs/<slug>[/…] path in the prompt; else a stable fallback.
# The trailing path is OPTIONAL: `/deliver full specs/<slug>` (a bare directory, no /spec.md) must still
# be captured — else `feature` falls to "unknown" and the completeness gate can only skip (green-by-skip;
# see check-completeness.sh). Both `specs/<slug>` and `specs/<slug>/spec.md` derive run=<slug>.
# Moved AHEAD of tier selection (ADR-0018): the spec path must be excised from the payload before the
# tier is grepped, and — when it resolves on disk — it IS the sizing input.
spec="$(printf '%s' "$payload" | grep -oE 'specs/[A-Za-z0-9._-]+(/[A-Za-z0-9._/-]*)?' | head -1)"

# Require an explicit CODE-pipeline token (single-thread|mvp|full). This confirms a real delivery
# run and excludes analysis pipelines (audit/audit-dd/l2p) that ship no code — arming those with
# intends_code:true would falsely demand a code closure.
#
# ADR-0018, two fixes here:
#  1. The tier is grepped from the payload with the specs/ path REMOVED. It used to be grepped from the
#     whole blob, so a slug that merely CONTAINS a tier word decided the tier: `/deliver
#     specs/full-text-search/spec.md` silently selected the 20-role pipeline. A slug is not a request.
#  2. No token no longer means `full`. It means `auto` — the harness sizes from the spec on disk. The
#     old default contradicted this plugin's own architecture doc, which calls single-thread "The
#     recommended default" (references/pipelines/single-thread.md), and it was unreachable-by-design
#     for anyone passing a spec path, since a path is never the literal token `mvp` or `full`.
tier_search="$payload"
[ -n "$spec" ] && tier_search="$(printf '%s' "$payload" | sed "s#${spec}##g")"
pipeline=""
printf '%s' "$tier_search" | grep -qE '(^|[^A-Za-z])single-thread([^A-Za-z]|$)' && pipeline="single-thread"
printf '%s' "$tier_search" | grep -qE '(^|[^A-Za-z])full([^A-Za-z]|$)'          && pipeline="${pipeline:-full}"
printf '%s' "$tier_search" | grep -qE '(^|[^A-Za-z])mvp([^A-Za-z]|$)'           && pipeline="${pipeline:-mvp}"
tier_source="operator"
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
[ -f "$marker" ] && exit 0                      # idempotent: never clobber baseline_sha
base="$(git rev-parse --short HEAD 2>/dev/null || true)"
# Normalize the feature to the spec.md PATH check-completeness expects: a bare dir/slug gets /spec.md
# appended (a value already ending in .md is left as-is; no specs path ⇒ "unknown", the no-spec sentinel).
feat="${spec:-unknown}"
case "$feat" in unknown|*.md) : ;; *) feat="${feat%/}/spec.md" ;; esac

# --- ADR-0018: is the milestone already ON DISK? -----------------------------
# When it is, the sizing input exists NOW — before the first dispatch — and Phase A's producing steps
# have nothing left to produce. Both facts are recorded as machine facts here rather than left to
# deliver.md prose, because prose lands ~70% of the time against a hook's ~100%
# (references/enforcement.md). `spec_present` is the on-disk truth, never the operator's claim: a path
# that does not resolve is a description, and Phase A must run in full for it.
spec_present=false; spec_path=""; artifacts=""; sizing=""
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
fi

# --- ADR-0018: resolve the tier the harness owns -----------------------------
# `auto` is deliberately NOT a recognized tier downstream, and that is safe by construction: every
# reader (check-review-ack:131, check-role-dispatch:47, delivery-stop-hook:105) exempts ONLY
# single-thread and fails CLOSED on anything else. So an unresolved tier enforces the strictest
# posture rather than opening a bypass — enforce until we know, which is the correct default. It
# persists only on the description form, where Phase A resolves it at the A->B boundary.
if [ "$tier_source" = "harness" ]; then
  pipeline="auto"
  if [ "$spec_present" = "true" ]; then
    _out="$("$(dirname "$0")/size-from-spec.sh" "$spec_path" 2>/dev/null || true)"
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
_base_f=""; [ -n "$base" ] && _base_f="\"baseline_sha\":\"$base\","
_spec_f="\"spec_present\":$spec_present,\"tier_source\":\"$tier_source\","
[ -n "$spec_path" ] && _spec_f="$_spec_f\"spec_path\":\"$spec_path\","
[ -n "$artifacts" ] && _spec_f="$_spec_f\"spec_artifacts\":[$artifacts],"
[ -n "$sizing" ]    && _spec_f="$_spec_f\"sizing\":\"$sizing\","
printf '{"run":"%s","pipeline":"%s","source":"harness","feature":"%s","intends_code":true,%s%s"precond":{"exit":0,"items":[],"ack":false}}\n' \
  "$run" "$pipeline" "$feat" "$_base_f" "$_spec_f" > "$marker" 2>/dev/null || true
printf 'delivery-marker-init: wrote harness RUN marker %s (run=%s pipeline=%s tier_source=%s spec_present=%s)\n' \
  "$marker" "$run" "$pipeline" "$tier_source" "$spec_present" >&2
exit 0
