#!/usr/bin/env bash
# verdict-shape-delivery.test.sh — issue #96: #88 tried to surface each review role's required verdict
# fields UPFRONT, but its brief rides a SubagentStart hook (bin/subagent-brief.sh) which — like
# SubagentStop (#60, proven host limit) — does NOT fire for Agent-tool-dispatched review subagents. So
# the shape never reached the reviewer and the orchestrator learned it only by hitting a --record
# rejection (discover-by-rejection), which #88 set out to remove.
#
# The fix delivers the required shape through channels that DO reach the point of use, without depending
# on SubagentStart/SubagentStop firing:
#   A. each DEDICATED per-role review agent (agents/<slug>.md) states its own required verdict fields in
#      its own system prompt — always present, no hook needed;
#   B. commands/deliver.md makes consulting `check-role-verdict --fields <role>` a MANDATORY pre-record
#      contract step BEFORE recording, rather than a fallback "if you must record by hand", and no longer
#      presents the (dead) SubagentStart brief as the channel that delivers the shape.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
ROOT="$here/.."
BIN="$ROOT/bin"
AGENTS="$ROOT/agents"
DELIVER="$ROOT/commands/deliver.md"
fail=0
_pass() { echo "  PASS $1"; }
_fail() { echo "  FAIL $1" >&2; fail=$((fail + 1)); }

# --- channel A: each dedicated per-role review agent states its own required fields --------------------
# For every agents/<slug>.md whose slug is a DEDICATED review type (role_of_slug non-empty — a generic
# like independent-reviewer resolves to no single role and legitimately states no field set), every field
# check-role-verdict --fields reports must appear literally in the agent's own markdown body. That is the
# shape reaching the reviewer through its always-present system prompt, no lifecycle hook involved.
for f in "$AGENTS"/*.md; do
  slug="$(basename "$f" .md)"
  role="$(bash -c '. "'"$BIN"'/delivery-lib.sh"; role_of_slug "'"$slug"'" 2>/dev/null' || true)"
  [ -n "$role" ] || continue    # generic slug (no role column) → skip
  fields="$(bash "$BIN/check-role-verdict.sh" --fields "$slug" 2>/dev/null || true)"
  [ -n "$fields" ] || { _fail "$slug: schema declares no required fields (unexpected for a dedicated role)"; continue; }
  missing=""
  for fld in $fields; do
    grep -qF "$fld" "$f" || missing="${missing:+$missing }$fld"
  done
  if [ -z "$missing" ]; then _pass "agents/$slug.md states its required verdict field(s): $fields"
  else _fail "agents/$slug.md does NOT state required field(s) [$missing] (role $role) — reviewer cannot emit the shape from its own prompt"; fi
done

# --- channel B: deliver.md carries the mandatory pre-record shape contract ----------------------------
# B1: the pre-record `--fields` lookup is present (the orchestrator-facing shape channel).
if grep -qF 'check-role-verdict.sh --fields <role>' "$DELIVER"; then
  _pass "deliver.md instructs the pre-record --fields <role> lookup"
else
  _fail "deliver.md does not instruct check-role-verdict.sh --fields <role>"
fi

# B2: deliver.md must NOT present the SubagentStart brief as the channel that delivers the shape to the
# reviewer — that channel is dead for Agent-tool review subagents (#96), and telling the orchestrator to
# trust it ("a verdict that comes back should already fit") is exactly what let discover-by-rejection
# persist. The shape delivery must not depend on SubagentStart/SubagentStop firing.
if grep -qiF 'required shape in its dispatch brief (SubagentStart)' "$DELIVER"; then
  _fail "deliver.md still claims the reviewer receives its shape via the SubagentStart brief (dead channel #96)"
else
  _pass "deliver.md does not rely on the dead SubagentStart brief to deliver the verdict shape"
fi

# B3: the contract is stated as a step to do BEFORE recording, not merely a hand-record fallback.
if grep -qF 'Pre-record shape contract (#96)' "$DELIVER"; then
  _pass "deliver.md carries an explicit mandatory pre-record shape contract"
else
  _fail "deliver.md lacks the explicit 'Pre-record shape contract (#96)' step"
fi

if [ "$fail" -eq 0 ]; then echo "verdict-shape-delivery.test.sh: OK"; exit 0; fi
echo "verdict-shape-delivery.test.sh: $fail case(s) FAILED" >&2; exit 1
