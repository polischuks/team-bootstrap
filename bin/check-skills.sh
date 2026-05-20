#!/usr/bin/env bash
# check-skills.sh — verify that skills referenced by a given team-bootstrap
# pipeline are present in ~/.claude/skills/. Read-only, no fetches.
#
# Usage:
#   bin/check-skills.sh                 # check audit-dd (the only skill-heavy pipeline today)
#   bin/check-skills.sh <pipeline>      # check a specific pipeline
#   bin/check-skills.sh --json          # machine-readable output
#
# Exit codes:
#   0 — all required skills present
#   1 — required skill missing
#   2 — recommended skill missing (still 0 from required, but warn)
#   64 — manifest unreadable

set -uo pipefail

MANIFEST="${BASH_SOURCE%/*}/../skills-manifest.json"
SKILL_ROOT="${HOME}/.claude/skills"
PIPELINE="${1:-audit-dd}"
JSON_MODE=0

# Handle --json flag in any position
for arg in "$@"; do
  [ "$arg" = "--json" ] && JSON_MODE=1
done
# Re-resolve PIPELINE if first arg was --json
[ "$PIPELINE" = "--json" ] && PIPELINE="${2:-audit-dd}"

if [ ! -f "$MANIFEST" ]; then
  echo "ERROR: skills-manifest.json not found at $MANIFEST" >&2
  exit 64
fi

# Require jq (or fall back to python)
if command -v jq >/dev/null 2>&1; then
  PARSER="jq"
elif command -v python3 >/dev/null 2>&1; then
  PARSER="python3"
else
  echo "ERROR: need jq or python3 to read manifest" >&2
  exit 64
fi

# Extract skill lists for the pipeline. Output one line per skill:
#   <tier>\t<name>\t<fallback>
# where tier is "required" | "recommended" | "optional".
extract_skills() {
  if [ "$PARSER" = "jq" ]; then
    jq -r --arg p "$PIPELINE" '
      .pipelines[$p] // {} |
      . as $pl |
      (["required","recommended","optional"][]) as $tier |
      ($pl[$tier] // [])[] |
      [$tier, .name, (.fallback // "")] |
      @tsv
    ' "$MANIFEST"
  else
    python3 - "$MANIFEST" "$PIPELINE" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
pl = data.get("pipelines", {}).get(sys.argv[2], {})
for tier in ("required", "recommended", "optional"):
    for s in pl.get(tier, []):
        print(f"{tier}\t{s['name']}\t{s.get('fallback','')}")
PY
  fi
}

# Resolve a skill name to its install path. Handles:
#   - "name"                  → ~/.claude/skills/name/SKILL.md
#   - "namespace:name"        → ~/.claude/skills/namespace/<name>/SKILL.md
#                               or anthropic-bundled skill lookup
skill_path() {
  local name="$1"
  if [[ "$name" == *:* ]]; then
    # Namespaced skill (e.g. anthropic-skills:xlsx) — search common locations
    local ns="${name%%:*}" sk="${name##*:}"
    for candidate in \
      "$SKILL_ROOT/$sk" \
      "$HOME/.claude/external/$ns/skills/$sk" \
      "$HOME/.claude/plugins/$ns/skills/$sk"
    do
      [ -f "$candidate/SKILL.md" ] && { echo "$candidate"; return; }
    done
    echo ""
    return
  fi
  if [ -f "$SKILL_ROOT/$name/SKILL.md" ]; then
    echo "$SKILL_ROOT/$name"
  else
    echo ""
  fi
}

required_missing=0
recommended_missing=0
results=()

while IFS=$'\t' read -r tier name fallback; do
  [ -z "$name" ] && continue
  path=$(skill_path "$name")
  if [ -n "$path" ]; then
    status="installed"
  else
    status="missing"
    case "$tier" in
      required)    required_missing=$((required_missing + 1)) ;;
      recommended) recommended_missing=$((recommended_missing + 1)) ;;
    esac
  fi
  results+=("$tier|$name|$status|$path|$fallback")
done < <(extract_skills)

# Output
if [ $JSON_MODE -eq 1 ]; then
  echo "{"
  echo "  \"pipeline\": \"$PIPELINE\","
  echo "  \"required_missing\": $required_missing,"
  echo "  \"recommended_missing\": $recommended_missing,"
  echo "  \"skills\": ["
  first=1
  for r in "${results[@]}"; do
    IFS='|' read -r tier name status path fallback <<< "$r"
    [ $first -eq 0 ] && echo ","
    first=0
    printf '    {"tier":"%s","name":"%s","status":"%s","path":"%s"}' \
      "$tier" "$name" "$status" "$path"
  done
  echo ""
  echo "  ]"
  echo "}"
else
  echo "Pipeline: $PIPELINE"
  echo "Skill root: $SKILL_ROOT"
  echo ""
  for r in "${results[@]}"; do
    IFS='|' read -r tier name status path fallback <<< "$r"
    case "$status" in
      installed) icon="✓" ;;
      missing)
        case "$tier" in
          required)    icon="✗" ;;
          recommended) icon="⚠" ;;
          optional)    icon="○" ;;
        esac
        ;;
    esac
    printf "  %s %-12s %-30s %s\n" "$icon" "[$tier]" "$name" "$status"
    if [ "$status" = "missing" ] && [ -n "$fallback" ]; then
      printf "      └─ fallback: %s\n" "$fallback"
    fi
  done
  echo ""
  if [ $required_missing -eq 0 ] && [ $recommended_missing -eq 0 ]; then
    echo "✓ All recommended skills installed. Pipeline ready."
  elif [ $required_missing -eq 0 ]; then
    echo "⚠ $recommended_missing recommended skill(s) missing — pipeline runs with fallbacks (slower / less precise)."
  else
    echo "✗ $required_missing required skill(s) missing — pipeline cannot run cleanly."
  fi
fi

[ $required_missing -gt 0 ] && exit 1
[ $recommended_missing -gt 0 ] && exit 2
exit 0
