#!/usr/bin/env bash
# pipeline-risk-sizing.test.sh — the tier/category signals must track load-bearing RISK, not surface.
#
# Three live retros, one theme ("count blast-radius, not surface"):
#   #108 — the layer count counts PATH DIVERSITY. docs/ + specs/ + config + tests/ each register as a
#          "layer", so a doc-heavy milestone with a thin code surface trips layers>=3 → full and pays a
#          four-role review panel to confirm a version bump. Only CODE layers should escalate the tier.
#   #125 — the `deps` risk category fires on the package.json FILENAME, so a +1-line `scripts` alias
#          pulls security + overengineering + ip-contracts reviewers for "no new dependency". It must
#          fire only when the manifest's dependency SECTIONS changed (a lockfile change always counts).
#   #122 — required roles are computed only at CLOSURE from the real diff, so a UI diff's
#          accessibility-reviewer surfaces as a post-commit failure and review opens twice. The set must
#          be PREDICTABLE at announce from the batch's DECLARED files.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
SP="$here/bin/select-pipeline.sh"
FAILF="$(mktemp)"; printf '0' > "$FAILF"
_chk() { if [ "$1" = "$2" ]; then printf '  PASS %s\n' "$3"
  else printf '  FAIL %s (got [%s] want [%s])\n' "$3" "$1" "$2"
       printf '%s' "$(( $(cat "$FAILF") + 1 ))" > "$FAILF"; fi; }

_rec()   { printf '%s\n' "$1" | "$SP" --from-stdin 2>&1 | sed -nE 's/.*RECOMMENDED pipeline: ([a-z-]+).*/\1/p' | tail -1; }
_reasons() { printf '%s\n' "$1" | "$SP" --from-stdin 2>&1 | sed -nE 's/.*\(reasons: (.*)\)$/\1/p' | tail -1; }

echo "#108 — the layer count tracks CODE layers, not path diversity:"

# A thin code surface (ONE code file) alongside docs + specs + config + tests must NOT size to full on
# the layer count alone. Under the old rule these five directories = 5 "layers" → full.
DIVERSE="$(printf '0\t0\tdocs/guide.md\n0\t0\tspecs/x/spec.md\n0\t0\tconfig/app.yaml\n0\t0\ttests/a.test.ts\n0\t0\tsrc/main.ts\n')"
_chk "$(_rec "$DIVERSE" | grep -c full)" "0" "#108 docs+specs+config+tests+1 code file does NOT size to full"
_chk "$(_reasons "$DIVERSE" | grep -c 'layers>=3')" "0" "#108 …and the layers>=3 trigger does not fire on path diversity"

# A GENUINE multi-layer CODE change (three code directories, no risk touch) still sizes up on layers.
CODE3="$(printf '0\t0\tsrc/a.ts\n0\t0\tlib/b.ts\n0\t0\tpkg/c.ts\n')"
_chk "$(_rec "$CODE3")" "full" "#108 three real code layers still recommend full"
_chk "$(_reasons "$CODE3" | grep -c 'layers>=3')" "1" "#108 …because CODE layers still count"

# A single risk touch escalates regardless of how many layers were discounted.
RISK="$(printf '0\t0\tdocs/guide.md\n0\t0\ttests/a.test.ts\n0\t0\tdb/migrations/001.sql\n')"
_chk "$(_rec "$RISK")" "full" "#108 a data/schema risk touch still forces full even amid docs+tests"

echo "#125 — deps fires on a real dependency-section change, not the package.json filename:"

_mkpkg() { # $1=deps-json  $2=scripts-json  → a pretty-printed package.json
  printf '{\n  "name": "widget",\n  "version": "1.0.0",\n  "scripts": {\n%b\n  },\n  "dependencies": {\n%b\n  }\n}\n' "$2" "$1"
}

# scripts-only edit → deps NOT tripped (working-tree mode).
T="$(mktemp -d)"; ( cd "$T" || exit 1; git init -q; git config user.email a@b.c; git config user.name t
  _mkpkg '    "left-pad": "^1.0.0"' '    "build": "tsc"' > package.json
  git add -A; git commit -q -m base
  _mkpkg '    "left-pad": "^1.0.0"' '    "build": "tsc",\n    "dev": "tsc -w"' > package.json   # scripts-only
  out="$("$SP" 2>&1)"
  _chk "$(printf '%s' "$out" | sed -nE 's/.*\(reasons: (.*)\)$/\1/p' | grep -c deps)" "0" \
    "#125 a scripts-only package.json edit does NOT trip deps"
) ; rm -rf "$T"

# dependency-section edit → deps tripped.
T="$(mktemp -d)"; ( cd "$T" || exit 1; git init -q; git config user.email a@b.c; git config user.name t
  _mkpkg '    "left-pad": "^1.0.0"' '    "build": "tsc"' > package.json
  git add -A; git commit -q -m base
  _mkpkg '    "left-pad": "^2.0.0"' '    "build": "tsc"' > package.json   # bumped a dependency
  out="$("$SP" 2>&1)"
  _chk "$(printf '%s' "$out" | sed -nE 's/.*\(reasons: (.*)\)$/\1/p' | grep -c deps)" "1" \
    "#125 a dependency-version bump DOES trip deps"
) ; rm -rf "$T"

# a NEW dependency added → deps tripped.
T="$(mktemp -d)"; ( cd "$T" || exit 1; git init -q; git config user.email a@b.c; git config user.name t
  _mkpkg '    "left-pad": "^1.0.0"' '    "build": "tsc"' > package.json
  git add -A; git commit -q -m base
  _mkpkg '    "left-pad": "^1.0.0",\n    "chalk": "^5.0.0"' '    "build": "tsc"' > package.json
  out="$("$SP" 2>&1)"
  _chk "$(printf '%s' "$out" | sed -nE 's/.*\(reasons: (.*)\)$/\1/p' | grep -c deps)" "1" \
    "#125 adding a dependency DOES trip deps"
) ; rm -rf "$T"

# a devDependencies-section change also trips deps (all four dependency sections count).
T="$(mktemp -d)"; ( cd "$T" || exit 1; git init -q; git config user.email a@b.c; git config user.name t
  printf '{\n  "name": "widget",\n  "scripts": {\n    "build": "tsc"\n  },\n  "devDependencies": {\n    "jest": "^29.0.0"\n  }\n}\n' > package.json
  git add -A; git commit -q -m base
  printf '{\n  "name": "widget",\n  "scripts": {\n    "build": "tsc"\n  },\n  "devDependencies": {\n    "jest": "^30.0.0"\n  }\n}\n' > package.json
  out="$("$SP" 2>&1)"
  _chk "$(printf '%s' "$out" | sed -nE 's/.*\(reasons: (.*)\)$/\1/p' | grep -c deps)" "1" \
    "#125 a devDependencies bump DOES trip deps"
) ; rm -rf "$T"

# a lockfile change is ALWAYS a real dependency event and still trips deps.
T="$(mktemp -d)"; ( cd "$T" || exit 1; git init -q; git config user.email a@b.c; git config user.name t
  printf '{"name":"widget","lockfileVersion":3,"packages":{}}\n' > package-lock.json
  git add -A; git commit -q -m base
  printf '{"name":"widget","lockfileVersion":3,"packages":{"node_modules/x":{}}}\n' > package-lock.json
  out="$("$SP" 2>&1)"
  _chk "$(printf '%s' "$out" | sed -nE 's/.*\(reasons: (.*)\)$/\1/p' | grep -c deps)" "1" \
    "#125 a lockfile change still trips deps"
) ; rm -rf "$T"

# BATCH mode is the live path (profile_roles_for_batch sizes via --batch). A scripts-only commit in a
# batch must not pull the deps reviewers.
T="$(mktemp -d)"; ( cd "$T" || exit 1; git init -q; git config user.email a@b.c; git config user.name t
  _mkpkg '    "left-pad": "^1.0.0"' '    "build": "tsc"' > package.json
  git add -A; git commit -q -m base; BASE="$(git rev-parse --short HEAD)"
  _mkpkg '    "left-pad": "^1.0.0"' '    "build": "tsc",\n    "dev": "tsc -w"' > package.json
  git add -A; git commit -q -m scripts; S="$(git rev-parse --short HEAD)"
  mkdir -p .runs/r
  printf '{"run":"r","pipeline":"full","intends_code":true,"baseline_sha":"%s"}\n' "$BASE" > .runs/r/RUN
  printf '{"id":"B1","kind":"code","risk_rank":"feature","status":"announced","commit_shas":["%s"]}\n' "$S" > .runs/r/batches.jsonl
  out="$(TEAM_BOOTSTRAP_RUN=r "$SP" --batch B1 2>&1)"
  _chk "$(printf '%s' "$out" | sed -nE 's/.*\(reasons: (.*)\)$/\1/p' | grep -c deps)" "0" \
    "#125 a scripts-only batch commit does NOT trip deps in --batch mode"
) ; rm -rf "$T"

echo "#122 — the required-role set is PREDICTABLE at announce from declared files:"

_pred() { ( . "$here/bin/delivery-lib.sh"; TEAM_BOOTSTRAP_RUN=r predicted_roles_for_batch "$1" ); }
_mkann() { # $1=dir  $2=ledger line for B1
  cd "$1" || return 1; mkdir -p .runs/r
  printf '{"run":"r","pipeline":"full","intends_code":true,"baseline_sha":"x"}\n' > .runs/r/RUN
  printf '%s\n' "$2" > .runs/r/batches.jsonl
}

# A batch DECLARING a UI file predicts accessibility-reviewer at announce — before any code is written.
T="$(mktemp -d)"; ( _mkann "$T" '{"id":"B1","kind":"code","risk_rank":"feature","status":"announced","files":["src/components/Button.tsx"]}'
  got="$(_pred B1)"
  _chk "$(printf '%s' "$got" | grep -cw accessibility-reviewer)" "1" \
    "#122 a declared UI file predicts accessibility-reviewer at announce"
  _chk "$(printf '%s' "$got" | grep -cw code-reviewer)" "1" "#122 …and always the >=1 reviewer floor"
) ; rm -rf "$T"

# A plain single non-UI file predicts only the floor — no accessibility fan-out.
T="$(mktemp -d)"; ( _mkann "$T" '{"id":"B1","kind":"code","risk_rank":"feature","status":"announced","files":["src/util.ts"]}'
  got="$(_pred B1)"
  _chk "$(printf '%s' "$got" | grep -cw accessibility-reviewer)" "0" \
    "#122 a non-UI batch predicts NO accessibility-reviewer"
  _chk "$(printf '%s' "$got" | grep -cw code-reviewer)" "1" "#122 …but still the reviewer floor"
) ; rm -rf "$T"

# A doc batch predicts no review roles at all.
T="$(mktemp -d)"; ( _mkann "$T" '{"id":"D1","kind":"doc","risk_rank":"doc","status":"announced","files":["docs/x.md"]}'
  _chk "$(printf '%s' "$(_pred D1)" | grep -c .)" "0" "#122 a doc batch predicts no review roles"
) ; rm -rf "$T"

fail="$(cat "$FAILF")"; rm -f "$FAILF"
[ "$fail" -eq 0 ] && { echo "pipeline-risk-sizing.test.sh: OK"; exit 0; }
echo "pipeline-risk-sizing.test.sh: $fail failure(s)"; exit 1
