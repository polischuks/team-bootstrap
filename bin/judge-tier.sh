#!/usr/bin/env bash
# judge-tier.sh — model judgement where the path classifier is blind (UserPromptExpansion hook).
#
# THE BLIND SPOT, admitted in size-from-spec.sh's own comment: a spec about exactly-once distributed
# settlement sized to single-thread because it touched two files in one directory. Paths and keywords
# cannot see what a milestone DOES. Anthropic's Routing pattern names the missing half — classification
# by a model rather than by an algorithm — and it was the half this project never used.
#
# DISCIPLINE: the judgement is a FLOOR the diff may raise and the judgement may never lower (ADR-0018,
# with a new signal source). One-directional on purpose: a wrong judgement can then only cost review,
# never skip it. size-from-spec.sh stays the fast deterministic path and is not replaced.
#
# WHY A `command` HANDLER AND NOT `type: "agent"`. The research doc specifies an agent handler here, and
# the event does support one. Two reasons it is the wrong instrument for THIS job, in order of weight:
#
#   1. An agent hook returns a DECISION into the conversation. It cannot persist anything. The judgement
#      has to be readable later by required_roles_for_batch, at batch time, in a different process — so
#      an agent handler could inform the model and could never be load-bearing. A gate that cannot read
#      the judgement is back to asking the model nicely, which is the defect this whole line of work
#      exists to remove.
#   2. Agent handlers are experimental, and the vendor's own guidance prefers command handlers for stable
#      enforcement.
#
# So the launch stays deterministic — a hook, not the orchestrator's goodwill — and the JUDGEMENT is a
# model's, obtained through `claude -p` under a strict JSON contract. That is the Routing pattern
# satisfied in substance: deterministically launched, model-classified, persisted where the gate reads.
#
# EVERY failure path is inert. No `claude` CLI, no spec, a timeout, an unparseable answer, a tier that is
# not one of the three known words — nothing is written and behaviour is exactly what it is today.
# Disable with TEAM_BOOTSTRAP_DELIVERY_GATE=off; force-skip the model call with TEAM_BOOTSTRAP_TIER_JUDGE=off.
#
# Exit: always 0 (advisory; it must never block a prompt from expanding).
set -uo pipefail

[ "${TEAM_BOOTSTRAP_DELIVERY_GATE:-on}" = "off" ] && exit 0
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/delivery-lib.sh
. "$here/delivery-lib.sh" 2>/dev/null || exit 0

TIMEOUT_S="${TEAM_BOOTSTRAP_TIER_JUDGE_TIMEOUT:-60}"

# _judge_prompt SPEC_DIR → the strict-contract prompt, or empty when there is nothing to read.
_judge_prompt() {
  local d="$1" body
  body="$( { cat "$d/spec.md" "$d/plan.md"; } 2>/dev/null | head -c 24000 )"
  [ -n "$body" ] || return 0
  cat <<PROMPT
You are sizing a software milestone for review depth. Read the specification below and answer with a
single JSON object and nothing else.

Answer shape: {"tier":"single-thread"|"mvp"|"full","reason":"<12 words or fewer>"}

Choose "full" when the milestone involves any of: distributed correctness (consensus, exactly-once,
idempotency, split-brain), irreversible data or money movement, authentication or authorisation
changes, schema migration or backfill, or a public contract other systems depend on. Choose "mvp" for
ordinary multi-part feature work. Choose "single-thread" only for a narrow, local, reversible change.

Judge what the milestone DOES, not how many files it touches — the file-count signal is computed
separately and does not need your help.

--- SPECIFICATION ---
$body
PROMPT
}

# _ask PROMPT → the model's raw answer (empty on any failure). Portable timeout: `timeout`, else
# `gtimeout`, else no wrapper at all — the same best-effort idiom guard-git.sh uses, because a host
# without coreutils must degrade to "no judgement", never to a hang that looks like a gate.
_ask() {
  local to=""
  command -v claude >/dev/null 2>&1 || return 0
  if   command -v timeout  >/dev/null 2>&1; then to="timeout $TIMEOUT_S"
  elif command -v gtimeout >/dev/null 2>&1; then to="gtimeout $TIMEOUT_S"
  fi
  # shellcheck disable=SC2086
  printf '%s\n' "$1" | $to claude -p 2>/dev/null || true
}

# _tier_of ANSWER → single-thread|mvp|full, or empty. Anything unrecognised is empty: an unknown word
# must produce NO judgement rather than a guess, because a guess here silently changes review depth.
_tier_of() {
  printf '%s' "$1" | grep -oE '"tier"[[:space:]]*:[[:space:]]*"(single-thread|mvp|full)"' \
    | head -1 | sed -E 's/.*"([a-z-]+)"$/\1/'
}
_reason_of() {
  printf '%s' "$1" | grep -oE '"reason"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 \
    | sed -E 's/.*"([^"]*)"$/\1/' | tr -d '\n' | cut -c1-120
}

if [ "${1:-}" = "--self-test" ]; then
  fail=0
  _c() { if [ "$1" = "$2" ]; then echo "  PASS $3"; else echo "  FAIL $3 (got [$1] want [$2])" >&2; fail=$((fail + 1)); fi; }
  _c "$(_tier_of '{"tier":"full","reason":"exactly-once money"}')" "full" "a known tier is read"
  _c "$(_tier_of '{"tier":"enormous"}')" "" "an UNKNOWN tier yields no judgement (never a guess)"
  _c "$(_tier_of 'the tier should be full')" "" "prose is not a verdict"
  _c "$(_reason_of '{"tier":"full","reason":"irreversible settlement"}')" "irreversible settlement" "the reason is read"
  T="$(mktemp -d)"; printf '# S\n\nexactly-once settlement\n' > "$T/spec.md"
  _c "$([ -n "$(_judge_prompt "$T")" ] && echo yes || echo no)" yes "a prompt is assembled from the spec"
  _c "$(_judge_prompt "$(mktemp -d)")" "" "no spec ⇒ no prompt (nothing to judge)"
  rm -rf "$T"
  [ "$fail" -eq 0 ] && { echo "judge-tier --self-test: OK"; exit 0; }
  echo "judge-tier --self-test: $fail FAILED" >&2; exit 1
fi

payload="$(cat 2>/dev/null || true)"
[ -n "$payload" ] || exit 0
[ "${TEAM_BOOTSTRAP_TIER_JUDGE:-on}" = "off" ] && exit 0

spec="$(printf '%s' "$payload" | grep -oE 'specs/[A-Za-z0-9._-]+' | head -1)"
[ -n "$spec" ] || exit 0
[ -f "$spec/spec.md" ] || exit 0

# Idempotence, the same discipline delivery-marker-init.sh applies to the marker. UserPromptExpansion
# fires on EVERY matching prompt, and a run spans many — without this the model is asked again on each
# one, at up to the full timeout, to re-derive a judgement that has not changed. Re-judge only when the
# SPECIFICATION has changed since the judgement was written; otherwise the existing verdict stands.
run="${spec#specs/}"; run="${run%/}"
_j=".runs/$run/tier-judgment"
if [ -f "$_j" ] && [ -z "${TEAM_BOOTSTRAP_TIER_JUDGE_FORCE:-}" ]; then
  _stale=""
  for _f in "$spec/spec.md" "$spec/plan.md"; do
    [ -f "$_f" ] && [ "$_f" -nt "$_j" ] && _stale=1
  done
  [ -n "$_stale" ] || exit 0
fi

prompt="$(_judge_prompt "$spec")"
[ -n "$prompt" ] || exit 0
answer="$(_ask "$prompt")"
tier="$(_tier_of "$answer")"
[ -n "$tier" ] || exit 0                       # no answer / timeout / unrecognised ⇒ no judgement at all
reason="$(_reason_of "$answer")"

mkdir -p ".runs/$run" 2>/dev/null || exit 0
printf 'tier=%s\nreason=%s\n' "$tier" "${reason:-unstated}" > ".runs/$run/tier-judgment" 2>/dev/null || exit 0

# UserPromptExpansion injects stdout as context. Fact statement, not an instruction — imperative phrasing
# trips the prompt-injection defence and the text is shown to the user instead of accepted as context.
printf '{"hookSpecificOutput":{"hookEventName":"UserPromptExpansion","additionalContext":"team-bootstrap tier judgement for run %s: tier=%s (%s). This is a FLOOR — the batch diff may raise the tier above it and never below it."}}\n' \
  "$run" "$tier" "$(printf '%s' "${reason:-unstated}" | tr -d '"\\')"
exit 0
