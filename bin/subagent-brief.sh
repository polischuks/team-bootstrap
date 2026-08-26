#!/usr/bin/env bash
# subagent-brief.sh — SubagentStart hook: hand a dispatched review role its brief, in ITS OWN context.
#
# The gap this closes (harness research §5 step 3, audit row 5): the harness knows the sized role set
# for the in-flight batch and had no pre-dispatch channel to tell the role about it. What existed was
# prose in commands/deliver.md — which lands ~70% of the time against a hook's ~100%
# (references/enforcement.md) — plus .runs/<id>/RUN, a format built for scripts that the role has to
# VOLUNTEER to read (the SWE-agent agent-computer-interface failure).
#
# WHY THIS EVENT AND NOT PreToolUse[Agent|Task]. A blocking pre-dispatch gate was considered and
# rejected on its own merits: refusing an off-plan dispatch pushes the orchestrator to review INLINE,
# which is the spec-169 collapse the review pipeline exists to prevent. SubagentStart CANNOT block, so
# that failure mode is excluded by construction rather than by discipline. Its additionalContext is
# addressed to the SUBAGENT, not to the parent conversation — which is exactly the delivery this needs.
#
# HANDLER TYPE. Registered as `command`. A `prompt`/`agent` handler would be a judgement call this hook
# does not need, and support for those types on SubagentStart is not something we could confirm.
#
# Safety: this hook must never disrupt a dispatch. It exits 0 on ANY unexpected input, emits nothing
# outside an armed intends_code run with an in-flight code batch, and never writes.
# Disable with TEAM_BOOTSTRAP_DELIVERY_GATE=off.
#
# Exit: always 0 (SubagentStart cannot block in any case).
set -uo pipefail

[ "${TEAM_BOOTSTRAP_DELIVERY_GATE:-on}" = "off" ] && exit 0

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/delivery-lib.sh
. "$here/delivery-lib.sh" 2>/dev/null || exit 0

# Drain stdin unconditionally — a hook that leaves its payload unread can wedge the writer. The agent
# type is read best-effort under several plausible key spellings and is used only to ADDRESS the brief;
# nothing is gated on it, and the hooks.json matcher has already filtered the event.
payload="$(cat 2>/dev/null || true)"
# `\|` alternation inside sed BRE is a GNU extension and silently matches nothing on BSD sed, so the
# extraction goes through grep -oE — the portable idiom this repo already uses elsewhere.
role="$(printf '%s' "$payload" \
  | grep -oE '"(agent_type|subagent_type|agentType|subagentType)"[[:space:]]*:[[:space:]]*"[^"]*"' \
  | head -1 | sed -E 's/.*"([^"]*)"[[:space:]]*$/\1/')"
[ -n "$role" ] || role="the dispatched role"

marker="$(resolve_marker 2>/dev/null || true)"
[ -n "$marker" ] && [ -f "$marker" ] || exit 0
mk="$(cat "$marker" 2>/dev/null || true)"
[ "$(field_bool "$mk" intends_code)" = "true" ] || exit 0

bline="$(inflight_batch 2>/dev/null || true)"
[ -n "$bline" ] || exit 0
bid="$(field_str "$bline" id)"
[ "$(field_str "$bline" kind)" = "code" ] || exit 0
[ -n "$bid" ] || exit 0

# Prefer the set RECORDED on the entry (verify-batch fixes it against the real diff); fall back to
# computing it, so a brief is available before the first close as well.
sized="$(required_roles_recorded "$bid" 2>/dev/null || true)"
[ -n "$sized" ] || sized="$(required_roles_for_batch "$bid" 2>/dev/null || true)"
covered="$(roles_covered "$bid" 2>/dev/null || true)"
pipeline="$(field_str "$mk" pipeline)"

# FACT STATEMENTS, never imperatives: additionalContext phrased as out-of-band instructions trips the
# prompt-injection defence, after which the text is shown to the user instead of accepted as context.
ctx="team-bootstrap brief for $role on batch $bid (pipeline=$pipeline)."
ctx="$ctx Review roles sized for this batch: ${sized:-unsized}."
ctx="$ctx Reviewer dispatches recorded so far: ${covered:-none}."
ctx="$ctx Review depth for this tier: $(review_depth_for_tier "$pipeline") on the /code-review low-medium-high scale."
ctx="$ctx This batch's diff is the review window; check-role-dispatch reads the recorded set at close."

# json_esc / emit_hook_context live in delivery-lib.sh. delivery-marker-init.sh keeps private copies on
# purpose: it runs on EVERY UserPromptSubmit and stays dependency-free, so a defect in the library
# cannot reach prompt submission. That duplication is declared rather than hidden.
emit_hook_context SubagentStart "$(json_esc "$ctx")"
exit 0
