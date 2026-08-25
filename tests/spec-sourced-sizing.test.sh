#!/usr/bin/env bash
# spec-sourced-sizing.test.sh — the harness must READ the spec and decide from it (ADR-0018).
#
# Today `/deliver specs/<slug>/spec.md` is parsed as "first token is not mvp|full" and falls through
# to the HEAVIEST tier (commands/deliver.md:9-11, bin/delivery-marker-init.sh:50). The spec on disk is
# never evaluated. These tests pin the target: the path is recognised as a machine fact, the artifacts
# are the sizing input, and `full` stops being the fallback.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
FAILF="$(mktemp)"; printf '0' > "$FAILF"
_chk() { if [ "$1" = "$2" ]; then printf '  PASS %s\n' "$3"
  else printf '  FAIL %s (got [%s] want [%s])\n' "$3" "$1" "$2"
       printf '%s' "$(( $(cat "$FAILF") + 1 ))" > "$FAILF"; fi; }
# _field KEY FILE — read a flat scalar out of the single-line marker JSON.
_field() { python3 -c "
import json,sys
try: d=json.load(open(sys.argv[2]))
except Exception: print('<unreadable>'); sys.exit()
v=d.get(sys.argv[1],'<absent>')
print(json.dumps(v) if isinstance(v,(dict,list)) else ('true' if v is True else 'false' if v is False else v))
" "$1" "$2" 2>/dev/null || echo '<err>'; }

# _mkspec DIR TASKS_BODY — a minimal but realistic milestone on disk.
_mkspec() {
  mkdir -p "$1"
  printf '# Spec — fixture\n\n## Acceptance criteria\n- **AC-1** — a thing.\n' > "$1/spec.md"
  printf '# Plan — fixture\n\n## Architecture\nSomething.\n' > "$1/plan.md"
  printf '# Tasks — fixture\n\n- Total tasks: 3\n\n%s\n' "$2" > "$1/tasks.md"
}

# _arm PROMPT — run the UserPromptSubmit hook against a prompt, echo the marker path.
_arm() { printf '%s' "$1" | "$here/bin/delivery-marker-init.sh" >/dev/null 2>&1 || true
         printf '.runs/%s/RUN' "$(cat .runs/current 2>/dev/null || echo deliver-run)"; }

echo "WS-1 — the harness sees the spec on disk (AC-1):"

# AC-1a — file form. The marker must carry the resolved path AND the machine fact that it EXISTS.
T="$(mktemp -d)"; ( cd "$T"; git init -q; git config user.email a@b.c; git config user.name t
  git commit -q --allow-empty -m base
  _mkspec specs/widget-cache '- [ ] T010 Do it.
  - file: bin/widget.sh · (feat · P10) — AC-1'
  m="$(_arm '/deliver specs/widget-cache/spec.md')"
  _chk "$(_field spec_present "$m")" "true"                        "AC-1a file form → spec_present:true"
  _chk "$(_field spec_path    "$m")" "specs/widget-cache/spec.md"  "AC-1a …and spec_path is the resolved artifact" )
rm -rf "$T"

# AC-1b — dir form must normalise to spec.md (the dir-form silent-skip class, 823a19f).
T="$(mktemp -d)"; ( cd "$T"; git init -q; git config user.email a@b.c; git config user.name t
  git commit -q --allow-empty -m base
  _mkspec specs/widget-cache '- [ ] T010 Do it.
  - file: bin/widget.sh · (feat · P10) — AC-1'
  m="$(_arm '/deliver specs/widget-cache')"
  _chk "$(_field spec_present "$m")" "true"                        "AC-1b dir form → spec_present:true"
  _chk "$(_field spec_path    "$m")" "specs/widget-cache/spec.md"  "AC-1b …normalised to spec.md" )
rm -rf "$T"

# AC-1c — a path that does NOT resolve is a description, not a spec. Fail-closed the honest way:
# claiming a spec is present when it is not would skip Phase A over nothing.
T="$(mktemp -d)"; ( cd "$T"; git init -q; git config user.email a@b.c; git config user.name t
  git commit -q --allow-empty -m base
  m="$(_arm '/deliver specs/does-not-exist/spec.md')"
  _chk "$(_field spec_present "$m")" "false" "AC-1c non-existent path → spec_present:false" )
rm -rf "$T"

# AC-1d — a prose description containing a slash must not be mistaken for a spec path.
T="$(mktemp -d)"; ( cd "$T"; git init -q; git config user.email a@b.c; git config user.name t
  git commit -q --allow-empty -m base
  m="$(_arm '/deliver mvp "add a retry/backoff wrapper to the client"')"
  _chk "$(_field spec_present "$m")" "false" "AC-1d description with a slash → spec_present:false" )
rm -rf "$T"

echo
echo "WS-1 — the tier stops being decided by substring luck (AC-8, latent):"

# The hook greps the WHOLE payload for `full`/`mvp` (delivery-marker-init.sh:46-48). A slug that
# CONTAINS one of those words therefore sets the tier. `specs/full-text-search` is not a request for
# the 20-role pipeline.
T="$(mktemp -d)"; ( cd "$T"; git init -q; git config user.email a@b.c; git config user.name t
  git commit -q --allow-empty -m base
  _mkspec specs/full-text-search '- [ ] T010 Do it.
  - file: bin/search.sh · (feat · P10) — AC-1'
  m="$(_arm '/deliver specs/full-text-search/spec.md')"
  got="$(_field pipeline "$m")"
  _chk "$([ "$got" = "full" ] && echo tier-from-slug || echo ok)" "ok" \
       "AC-8 a slug containing 'full' does not select the full tier (got pipeline=$got)" )
rm -rf "$T"

# AC-8 — an unrecognised first token must mean "harness decides", not "take the heaviest".
T="$(mktemp -d)"; ( cd "$T"; git init -q; git config user.email a@b.c; git config user.name t
  git commit -q --allow-empty -m base
  _mkspec specs/widget-cache '- [ ] T010 Do it.
  - file: bin/widget.sh · (feat · P10) — AC-1'
  m="$(_arm '/deliver specs/widget-cache/spec.md')"
  _chk "$(_field tier_source "$m")" "harness" "AC-8 no explicit tier → tier_source:harness"
  got="$(_field pipeline "$m")"
  _chk "$([ "$got" = "full" ] && echo fallback-full || echo computed)" "computed" \
       "AC-8 …and the tier is computed, not the 'full' fallback (got $got)" )
rm -rf "$T"

# AC-8 — an EXPLICIT tier still pins. The operator decides (P1).
T="$(mktemp -d)"; ( cd "$T"; git init -q; git config user.email a@b.c; git config user.name t
  git commit -q --allow-empty -m base
  _mkspec specs/widget-cache '- [ ] T010 Do it.
  - file: bin/widget.sh · (feat · P10) — AC-1'
  m="$(_arm '/deliver full specs/widget-cache/spec.md')"
  _chk "$(_field pipeline    "$m")" "full"     "AC-8 explicit full still pins the tier"
  _chk "$(_field tier_source "$m")" "operator" "AC-8 …recorded as operator-chosen" )
rm -rf "$T"

echo
echo "WS-2 — the spec is the sizing input (AC-2, AC-3):"

# AC-2 — a milestone whose tasks touch ONE non-risk file is not a 20-role job.
T="$(mktemp -d)"; ( cd "$T"
  _mkspec specs/widget-cache '- [ ] T010 Do it.
  - file: bin/widget.sh · (feat · P10) — AC-1'
  out="$("$here/bin/size-from-spec.sh" specs/widget-cache 2>/dev/null || true)"
  tier="$(printf '%s\n' "$out" | sed -n 's/^tier=//p')"
  _chk "$([ "$tier" = "full" ] || [ -z "$tier" ] && echo bad || echo light)" "light" \
       "AC-2 one non-risk file → tier below full (got '${tier:-<no output>}')" )
rm -rf "$T"

# AC-3 — the five risk categories must fire from TEXT (paths named by tasks), not from a diff.
# NOTE: expectations follow select-pipeline's SHIPPED classification (its --self-test is the contract):
# auth/schema/infra/api lift to full; a dependency manifest lifts to mvp. This milestone reuses that
# classifier verbatim — it must not silently reclassify anything as a side effect.
for cat in "auth:src/auth/login.ts:full" "schema:db/migrations/001.sql:full" \
           "infra:.github/workflows/ci.yml:full" "api:src/api/routes.ts:full" "deps:package.json:mvp"; do
  name="${cat%%:*}"; rest="${cat#*:}"; path="${rest%:*}"; want="${rest##*:}"
  T="$(mktemp -d)"; ( cd "$T"
    _mkspec specs/risky "- [ ] T010 Touch it.
  - file: ${path} · (feat · P10) — AC-1"
    out="$("$here/bin/size-from-spec.sh" specs/risky 2>/dev/null || true)"
    tier="$(printf '%s\n' "$out" | sed -n 's/^tier=//p')"
    _chk "${tier:-<none>}" "$want" "AC-3 risk '${name}' (${path}) → ${want}, from text" )
  rm -rf "$T"
done

# AC-3 — a broken/absent tasks.md must DEGRADE, never crash. This script is called from the
# UserPromptSubmit hook; a non-zero exit there would take the run's fail-closed posture with it.
T="$(mktemp -d)"; ( cd "$T"
  mkdir -p specs/broken; printf 'not a spec\n' > specs/broken/spec.md
  rc=0; "$here/bin/size-from-spec.sh" specs/broken >/dev/null 2>&1 || rc=$?
  _chk "$rc" "0" "AC-3 absent tasks.md → exit 0 (degrade, never crash the hook)" )
rm -rf "$T"

T="$(mktemp -d)"; ( cd "$T"
  rc=0; "$here/bin/size-from-spec.sh" specs/nothing-here >/dev/null 2>&1 || rc=$?
  _chk "$rc" "0" "AC-3 missing spec dir → exit 0 (degrade)" )
rm -rf "$T"

echo
echo "WS-2 — root-anchored risk paths escalate (regression, found while wiring AC-3):"

# `*/api/*` cannot match `api/routes.ts` at the repo root — there is no parent segment. Three of the
# five categories carried only the nested form, so a root-level api/, models/ or .github/workflows/
# change silently declined to escalate. This is DIFF-sourced sizing too: git diff --numstat emits the
# root form. Pinned here because sizing correctness is this milestone's subject.
for f in ".github/workflows/ci.yml:full:infra" "api/routes.ts:full:api" "models/user.py:full:data" \
         "src/api/routes.ts:full:api-nested" "package.json:mvp:deps-root"; do
  path="${f%%:*}"; rest="${f#*:}"; want="${rest%%:*}"; label="${rest#*:}"
  got="$(printf '3\t0\t%s\n' "$path" | "$here/bin/select-pipeline.sh" --from-stdin 2>/dev/null \
         | sed -n 's/.*RECOMMENDED pipeline: \([a-z-]*\).*/\1/p' | head -1)"
  _chk "${got:-<none>}" "$want" "AC-3 root-anchored '${label}' (${path}) → ${want}"
done

echo
echo "WS-1 — an unresolved tier must ENFORCE, not exempt (R4):"

# `auto` is a new token downstream. The whole design rests on every reader exempting ONLY
# single-thread and failing closed on anything else (check-review-ack:131, check-role-dispatch:47,
# delivery-stop-hook:105). If any reader ever exempts an unknown token instead, `auto` becomes a
# silent bypass of the reviewer floor — the worst possible regression from this milestone.
T="$(mktemp -d)"; ( cd "$T"; git init -q; git config user.email a@b.c; git config user.name t
  git commit -q --allow-empty -m base; printf 'x\n' > c.js; git add -A; git commit -q -m work
  mkdir -p .runs/r
  printf '{"run":"r","pipeline":"auto","source":"harness","intends_code":true,"baseline_sha":"%s"}\n' \
    "$(git rev-parse HEAD~1)" > .runs/r/RUN
  printf '{"id":"B1","kind":"code","status":"announced"}\n' > .runs/r/batches.jsonl
  rc=0; TEAM_BOOTSTRAP_RUN=r "$here/bin/delivery-stop-hook.sh" <<<'{}' >/dev/null 2>&1 || rc=$?
  _chk "$rc" "2" "R4 pipeline=auto still blocks an undelivered code batch (fails closed, not open)" )
rm -rf "$T"

fail="$(cat "$FAILF")"; rm -f "$FAILF"
[ "$fail" -eq 0 ] && { echo "spec-sourced-sizing.test.sh: OK"; exit 0; }
echo "spec-sourced-sizing.test.sh: $fail failure(s)"; exit 1
