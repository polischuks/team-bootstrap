#!/usr/bin/env bash
# eval-role.sh — runnable eval for a team-bootstrap role.
#
# Two stages (see references/evaluator.md and references/trace-evals.md):
#   1. STATIC  — deterministic frontmatter validation against
#                references/schemas/role-frontmatter.schema.json. Fast, no network.
#   2. JUDGE   — assemble the LLM-as-judge rubric prompt for an artifact. Emitted to
#                stdout by default; invoked via the `claude` CLI when --judge is passed
#                and the binary is available. The script never fabricates a score.
#
# Usage:
#   bin/eval-role.sh <role>                      # static-validate one role
#   bin/eval-role.sh --all                       # static-validate every role (CI gate)
#   bin/eval-role.sh <role> --artifact <file>    # static + print judge prompt for <file>
#   bin/eval-role.sh <role> --artifact <file> --judge   # also run `claude` if present
#   bin/eval-role.sh <role> --json               # machine-readable static result
#
# Exit codes:
#   0  — static validation passed (and judge ran clean, if requested)
#   1  — static validation failed
#   2  — judge prompt assembled but not executed (no --judge, or `claude` absent)
#   64 — bad usage / environment

set -uo pipefail

ROOT="${BASH_SOURCE%/*}/.."
ROLES_DIR="$ROOT/references/roles"
SCHEMA="$ROOT/references/schemas/role-frontmatter.schema.json"
EVALUATOR="$ROOT/references/evaluator.md"

ROLE=""
ALL=0
JSON=0
JUDGE=0
ARTIFACT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --all)      ALL=1 ;;
    --json)     JSON=1 ;;
    --judge)    JUDGE=1 ;;
    --artifact) shift; ARTIFACT="${1:-}" ;;
    -h|--help)  grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)         echo "ERROR: unknown flag $1" >&2; exit 64 ;;
    *)          ROLE="$1" ;;
  esac
  shift
done

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 required for frontmatter validation" >&2
  exit 64
fi
if [ ! -f "$SCHEMA" ]; then
  echo "ERROR: schema not found at $SCHEMA" >&2
  exit 64
fi
if [ "$ALL" -eq 0 ] && [ -z "$ROLE" ]; then
  echo "ERROR: pass a role name or --all" >&2
  exit 64
fi

# --- Stage 1: static frontmatter validation (deterministic) -------------------
# Validates with jsonschema+yaml when available; degrades to a hand-rolled check
# of the schema's core constraints otherwise. Prints "OK" / "FAIL: <reasons>".
validate_one() {
  local file="$1"
  python3 - "$file" "$SCHEMA" <<'PY'
import sys, re, json

path, schema_path = sys.argv[1], sys.argv[2]
src = open(path, encoding="utf-8").read()
m = re.match(r"^---\n(.*?)\n---", src, re.S)
if not m:
    print("FAIL: no YAML frontmatter block"); sys.exit(1)
block = m.group(1)

# Parse: prefer pyyaml, else a minimal frontmatter parser (flat scalars,
# flow lists [a, b], and one nested mapping level — enough for this schema).
def minimal_parse(text):
    data, stack = {}, [(-1, None)]
    cur = data
    for raw in text.splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        indent = len(raw) - len(raw.lstrip())
        key, _, val = raw.strip().partition(":")
        val = val.strip()
        while stack and indent <= stack[-1][0]:
            stack.pop()
        parent = stack[-1][1] if stack and stack[-1][1] is not None else data
        if val == "":
            child = {}
            parent[key] = child
            stack.append((indent, child))
        else:
            if val.startswith("[") and val.endswith("]"):
                inner = val[1:-1].strip()
                parent[key] = [x.strip() for x in inner.split(",")] if inner else []
            else:
                parent[key] = val
    return data

try:
    import yaml
    fm = yaml.safe_load(block)
except Exception:
    fm = minimal_parse(block)

schema = json.load(open(schema_path, encoding="utf-8"))
errors = []

try:
    import jsonschema
    v = jsonschema.Draft202012Validator(schema)
    errors = [f"{'/'.join(map(str, e.path)) or '<root>'}: {e.message}"
              for e in v.iter_errors(fm)]
except Exception:
    # Hand-rolled check of the schema's load-bearing constraints.
    req = schema.get("required", [])
    for k in req:
        if k not in fm:
            errors.append(f"missing required key: {k}")
    if isinstance(fm.get("name"), str) and not re.match(r"^[a-z][a-z0-9-]*$", fm["name"]):
        errors.append("name: does not match ^[a-z][a-z0-9-]*$")
    if isinstance(fm.get("version"), str) and not re.match(r"^[0-9]+\.[0-9]+\.[0-9]+(-[0-9a-zA-Z.-]+)?$", fm["version"]):
        errors.append("version: not semver")
    if "model" in fm and not (isinstance(fm["model"], str) and fm["model"]):
        errors.append("model: must be a non-empty string")
    enum_pipes = {"mvp","full","single-thread","incident","audit","audit-dd"}
    cps = fm.get("compatible_pipelines")
    if isinstance(cps, list):
        bad = [c for c in cps if c not in enum_pipes]
        if bad: errors.append(f"compatible_pipelines: not in enum: {bad}")
    elif "compatible_pipelines" in fm:
        errors.append("compatible_pipelines: must be a list")
    if fm.get("permission_mode") not in {"plan","ask","acceptEdits"}:
        errors.append("permission_mode: must be one of plan|ask|acceptEdits")
    ts = fm.get("tool_surface")
    if isinstance(ts, dict):
        for k in ("allow","deny","mcp"):
            if k not in ts: errors.append(f"tool_surface.{k}: missing")
    elif "tool_surface" in fm:
        errors.append("tool_surface: must be a mapping")

if errors:
    print("FAIL: " + "; ".join(errors)); sys.exit(1)
print("OK")
sys.exit(0)
PY
}

run_static() {
  local files=() rc=0
  if [ "$ALL" -eq 1 ]; then
    for f in "$ROLES_DIR"/*.md; do files+=("$f"); done
  else
    local f="$ROLES_DIR/$ROLE.md"
    [ -f "$f" ] || { echo "ERROR: role not found: $f" >&2; exit 64; }
    files+=("$f")
  fi

  local pass=0 fail=0
  if [ "$JSON" -eq 1 ]; then echo "{"; echo "  \"results\": ["; fi
  local first=1
  for f in "${files[@]}"; do
    local name; name=$(basename "$f" .md)
    local out; out=$(validate_one "$f"); local vrc=$?
    if [ "$JSON" -eq 1 ]; then
      [ $first -eq 0 ] && echo ","
      first=0
      printf '    {"role":"%s","status":"%s","detail":"%s"}' \
        "$name" "$([ $vrc -eq 0 ] && echo pass || echo fail)" \
        "$(echo "$out" | sed 's/"/\\"/g')"
    else
      if [ $vrc -eq 0 ]; then printf "  \xE2\x9C\x93 %-28s static OK\n" "$name"
      else printf "  \xE2\x9C\x97 %-28s %s\n" "$name" "$out"; fi
    fi
    if [ $vrc -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); rc=1; fi
  done
  if [ "$JSON" -eq 1 ]; then
    echo ""; echo "  ],"; echo "  \"pass\": $pass, \"fail\": $fail"; echo "}"
  else
    echo ""
    if [ $fail -eq 0 ]; then echo "Static: $pass/$pass roles valid."
    else echo "Static: $fail of $((pass+fail)) roles FAILED frontmatter validation."; fi
  fi
  return $rc
}

# --- Stage 2: assemble the LLM-as-judge prompt --------------------------------
assemble_judge_prompt() {
  local role_file="$ROLES_DIR/$ROLE.md"
  cat <<EOF
You are the independent EVALUATOR defined in references/evaluator.md. You did NOT
produce the artifact under review. Judge it against the success criteria ONLY —
you have not been given (and must not assume) the construction history.

Score EACH dimension separately on a 0–4 scale, in a RANDOMLY SHUFFLED order, and
justify every score with a CONCRETE citation (a file path, a command's output, a
spec line). A score without concrete evidence is invalid.

Dimensions: criteria_coverage, grounding, correctness, safety, quality.
Scale: 4 fully satisfies · 3 minor nits · 2 real gap · 1 largely fails · 0 absent/wrong.
Verdict rule: pass = every dim ≥3 and safety not in {0,1}; safety in {0,1} = safety-fail (hard stop).

Return the YAML verdict shape from references/evaluator.md (evaluator_verdict + scores + dimension_order).

--- ROLE CONTRACT (success criteria source) ---
$(sed -n '/^## Mission/,/^## Output Template/p' "$role_file" 2>/dev/null || cat "$role_file")

--- ARTIFACT UNDER REVIEW ---
EOF
  if [ -n "$ARTIFACT" ] && [ -f "$ARTIFACT" ]; then
    cat "$ARTIFACT"
  else
    echo "(no --artifact provided; supply the role's produced artifact to judge)"
  fi
}

# --- Drive --------------------------------------------------------------------
run_static
STATIC_RC=$?

# Judge stage only for a single named role with an artifact context.
if [ "$ALL" -eq 0 ] && { [ -n "$ARTIFACT" ] || [ "$JUDGE" -eq 1 ]; }; then
  echo ""
  echo "--- Stage 2: LLM-as-judge (rubric from $EVALUATOR) ---"
  PROMPT="$(assemble_judge_prompt)"
  if [ "$JUDGE" -eq 1 ] && command -v claude >/dev/null 2>&1; then
    echo "Invoking \`claude\` as the judge..."
    printf '%s\n' "$PROMPT" | claude -p
    exit $STATIC_RC
  else
    printf '%s\n' "$PROMPT"
    echo ""
    if [ "$JUDGE" -eq 1 ]; then
      echo "(\`claude\` CLI not found — prompt emitted, not executed.)"
    else
      echo "(pass --judge to invoke the \`claude\` CLI, or pipe this prompt to your judge.)"
    fi
    [ $STATIC_RC -eq 0 ] && exit 2 || exit 1
  fi
fi

exit $STATIC_RC
