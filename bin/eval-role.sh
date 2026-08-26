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
#   bin/eval-role.sh --liveness                  # MUTATION eval: is each assignable role load-bearing?
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
LIVENESS=0
JSON=0
JUDGE=0
ARTIFACT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --all)      ALL=1 ;;
    --liveness) LIVENESS=1 ;;
    --json)     JSON=1 ;;
    --judge)    JUDGE=1 ;;
    --artifact) shift; ARTIFACT="${1:-}" ;;
    -h|--help)  grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)         echo "ERROR: unknown flag $1" >&2; exit 64 ;;
    *)          ROLE="$1" ;;
  esac
  shift
done

# --- --liveness: the only honest metric of "how many roles are alive" --------------------------------
#
# A role is ALIVE iff an eval exists that goes RED when the role is removed from the set. That is
# check-gate-integrity.sh's philosophy — a gate that cannot fail is not a gate — applied to roles: a
# role whose removal changes nothing is a playbook, not a role, and counting it is self-deception.
#
# This is a MUTATION eval. For every role the active profile can assign, it builds a throwaway repo whose
# diff trips that role's category and asserts BOTH directions:
#   present ⇒ required_roles_for_batch names the role
#   removed ⇒ it does not
# One-directional would pass on a set that names every role unconditionally. It also asserts the role is
# dispatchable, attributable and typed, because a role that is "required" but cannot be dispatched,
# attributed or confirmed reddens nothing downstream.
if [ "${LIVENESS:-0}" -eq 1 ]; then
  ROOT="$(cd "$(dirname "$0")/.." && pwd)"
  MAPF="${TEAM_BOOTSTRAP_PROFILE:-$ROOT/profiles/default.map}"
  [ -f "$MAPF" ] || { echo "eval-role --liveness: no profile map at $MAPF" >&2; exit 1; }
  # The probe paths per category — the same paths select-pipeline.sh classifies. A probe may name MORE
  # THAN ONE path (space-separated), because not every category can be tripped by a single file: an
  # all-doc diff short-circuits to `docs-only` before any category is emitted, so a LICENSE-only change
  # is a doc batch and earns no review fan-out by design. The realistic licence event is a MIXED diff —
  # a vendored dependency arriving with its licence — and the probe has to be able to say so. A
  # one-path-only probe would have reported that binding DEAD and invited someone to "fix" a binding
  # that was never broken.
  _probe_for() {
    case "$1" in
      security/auth) printf 'src/auth/login.ts' ;;
      data/schema)   printf 'db/schema.sql' ;;
      api/contract)  printf 'src/api/openapi.yaml' ;;
      infra/deploy)  printf 'infra/Dockerfile' ;;
      deps)          printf 'package.json' ;;
      ui)            printf 'src/components/Button.tsx' ;;
      perf)          printf 'bench/throughput.bench.ts' ;;
      licence)       printf 'LICENSE src/vendored.ts' ;;
      # `no-tests` is a property of the whole diff, not of a path: the probe is any non-doc file that is
      # not itself a test. Every other probe here trips it too, which is correct and harmless — the
      # liveness check compares PER ROLE, so test-designer being present in a security/auth probe's set
      # does not affect whether security-reviewer is load-bearing.
      no-tests)      printf 'src/untested.ts' ;;
      *)             printf '' ;;
    esac
  }
  _required_with() { # $1=profile-map path  $2=space-separated touch paths → the sized role set
    local D _p; D="$(mktemp -d)"
    ( cd "$D" || exit 1
      git init -q; git config user.email a@b.c; git config user.name t
      printf 'x\n' > seed.txt; git add -A; git commit -q -m base
      B="$(git rev-parse --short HEAD)"
      mkdir -p .runs/r
      for _p in $2; do mkdir -p "$(dirname "$_p")"; printf 'z\n' > "$_p"; done
      git add -A; git commit -q -m work
      printf '{"run":"r","pipeline":"full","intends_code":true,"baseline_sha":"%s"}\n' "$B" > .runs/r/RUN
      printf '{"id":"B1","kind":"code","status":"announced"}\n' > .runs/r/batches.jsonl
      . "$ROOT/bin/delivery-lib.sh"
      TEAM_BOOTSTRAP_PROFILE="$1" TEAM_BOOTSTRAP_RUN=r required_roles_for_batch B1 ) 2>/dev/null
    rm -rf "$D"
  }
  lfail=0; alive=0; total=0
  echo "eval-role --liveness — a role is alive iff removing it turns something red:"
  while read -r cat roles; do
    case "$cat" in ''|'#'*) continue ;; esac
    probe="$(_probe_for "$cat")"
    if [ -z "$probe" ]; then
      echo "  FAIL $cat — no probe path; the category cannot be exercised, so no role under it can be proven alive" >&2
      lfail=$((lfail + 1)); continue
    fi
    for r in $roles; do
      total=$((total + 1))
      with="$(_required_with "$MAPF" "$probe")"
      tmpmap="$(mktemp)"; grep -v "^${cat}[[:space:]]" "$MAPF" > "$tmpmap"
      without="$(_required_with "$tmpmap" "$probe")"; rm -f "$tmpmap"
      # the role may still be earned by the TIER (integration-verifier is in the full base set); what
      # must differ is only the roles the CATEGORY contributes, so compare per-role, not set-equality.
      inw=no; case " $with " in *" $r "*) inw=yes ;; esac
      ino=no; case " $without " in *" $r "*) ino=yes ;; esac
      disp=no;  [ -f "$ROOT/agents/$r.md" ] && disp=yes
      attr=no;  awk -F'\t' -v s="$r" '$1==s && $2!="" {found=1} END{exit !found}' "$ROOT/references/review-types.txt" && attr=yes
      typed=no; [ -n "$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))["$defs"].get(sys.argv[2],{})
print(" ".join(f for b in d.get("allOf",[]) for f in b.get("required",[])))' "$ROOT/references/schemas/role-output.schema.json" "$r" 2>/dev/null)" ] && typed=yes
      if [ "$inw" = yes ] && [ "$ino" = no ] && [ "$disp" = yes ] && [ "$attr" = yes ] && [ "$typed" = yes ]; then
        echo "  ALIVE $r  (category $cat: required when present, absent when removed; dispatchable, attributable, typed)"
        alive=$((alive + 1))
      elif [ "$inw" = yes ] && [ "$ino" = yes ]; then
        echo "  DEAD  $r  (category $cat: required even with the mapping REMOVED — the map is not load-bearing for it)" >&2
        lfail=$((lfail + 1))
      else
        echo "  DEAD  $r  (category $cat: required=$inw removed=$ino dispatchable=$disp attributable=$attr typed=$typed)" >&2
        lfail=$((lfail + 1))
      fi
    done
  done < "$MAPF"
  echo "eval-role --liveness: $alive/$total assignable role bindings are alive."
  [ "$lfail" -eq 0 ] && exit 0
  echo "eval-role --liveness: $lfail binding(s) not alive." >&2; exit 1
fi

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
