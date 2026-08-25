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

echo
echo "WS-3 — the role plan is PER WORK-STREAM, not per milestone (AC-4):"

# The floor must not be the milestone's overall tier. This very milestone sizes to `full` (28 files,
# 5 layers) — applying that as a blanket floor would give every batch the four-role fan-out again,
# which is precisely the uniform-cost failure #27 existed to end. So the plan is keyed by work-stream:
# a doc-only stream earns no reviewers, an auth stream earns all four, in the SAME milestone.
_mkspec2() {
  mkdir -p "$1"
  printf '# Spec — fixture\n\n## Acceptance criteria\n- **AC-1** — a thing.\n' > "$1/spec.md"
  printf '# Plan — fixture\n' > "$1/plan.md"
  cat > "$1/tasks.md" <<'EOT'
# Tasks — fixture

- Total tasks: 4

## Phase 1 — WS-1: docs only
- [ ] T010 Write the guide.
  - file: docs/guide.md · (docs · P10) — AC-1
- [ ] T011 Note it in the changelog.
  - file: CHANGELOG.md · (docs · P10) — AC-1

## Phase 2 — WS-2: the auth path
- [ ] T020 Harden the login flow.
  - file: src/auth/login.ts · (feat · P5) — AC-1
- [ ] T021 Test it.
  - file: tests/auth.test.ts · (test · P9) — AC-1
EOT
}

# AC-4a — the evaluator emits one entry per work-stream, each sized on ITS OWN paths.
T="$(mktemp -d)"; ( cd "$T"
  _mkspec2 specs/two-streams
  out="$("$here/bin/size-from-spec.sh" --per-batch specs/two-streams 2>/dev/null || true)"
  n="$(printf '%s\n' "$out" | grep -c '^ws=' || true)"
  _chk "$n" "2" "AC-4a --per-batch emits one entry per work-stream"
  t1="$(printf '%s\n' "$out" | sed -n '1s/.*[[:space:]]tier=\([a-z-]*\).*/\1/p')"
  t2="$(printf '%s\n' "$out" | sed -n '2s/.*[[:space:]]tier=\([a-z-]*\).*/\1/p')"
  _chk "${t1:-<none>}" "single-thread" "AC-4a docs-only stream sizes light"
  _chk "${t2:-<none>}" "full"          "AC-4a auth stream sizes full — same milestone, different tier" )
rm -rf "$T"

# AC-4b — the plan reaches the marker as a machine fact, written by the hook.
T="$(mktemp -d)"; ( cd "$T"; git init -q; git config user.email a@b.c; git config user.name t
  git commit -q --allow-empty -m base
  _mkspec2 specs/two-streams
  m="$(_arm '/deliver specs/two-streams/spec.md')"
  got="$(python3 -c "
import json,sys
try: d=json.load(open('$m'))
except Exception: print('<unreadable>'); sys.exit()
rp=d.get('role_plan')
print('<absent>' if rp is None else len(rp))" 2>/dev/null || echo '<err>')"
  _chk "$got" "2" "AC-4b role_plan lands in the marker, one entry per work-stream" )
rm -rf "$T"

# AC-4c — THE POINT, isolated: the batch touches ONE benign file, so the diff alone sizes it light.
# The risk lives in a DIFFERENT file of the same work-stream, which only the spec knows about. If the
# full set still comes back, it came from the plan and nowhere else.
T="$(mktemp -d)"; ( cd "$T"; git init -q; git config user.email a@b.c; git config user.name t
  git commit -q --allow-empty -m base
  mkdir -p .runs/two-streams lib
  printf '{"run":"two-streams","pipeline":"mvp","source":"harness","intends_code":true,"spec_present":true,"role_plan":[{"ws":"WS-2","tier":"full","paths":"db/migrations/002.sql lib/helper.ts"}]}\n' > .runs/two-streams/RUN
  printf 'two-streams\n' > .runs/current
  printf 'x\n' > lib/helper.ts; git add -A; git commit -q -m b1
  printf '{"id":"B1","kind":"code","status":"announced","base":"%s"}\n' "$(git rev-parse HEAD~1)" > .runs/two-streams/batches.jsonl
  # sanity: the diff on its own is light — otherwise this test proves nothing
  diffonly="$(printf '1\t0\tlib/helper.ts\n' | "$here/bin/select-pipeline.sh" --from-stdin 2>/dev/null \
              | sed -n 's/.*RECOMMENDED pipeline: \([a-z-]*\).*/\1/p' | head -1)"
  _chk "$diffonly" "single-thread" "AC-4c (setup) the batch diff alone sizes light"
  got="$( . "$here/bin/delivery-lib.sh"; TEAM_BOOTSTRAP_RUN=two-streams required_roles_for_batch B1 )"
  _chk "$(printf '%s' "$got" | grep -cw architecture-reviewer)" "1" \
       "AC-4c a light diff in a risky work-stream still earns the full set (plan is a floor)" )
rm -rf "$T"

# AC-4d — one-directional. A HEAVY diff in a light work-stream still escalates: the diff may LIFT the
# planned floor, never lower it. Text-sourced sizing can under-state (R2); the diff is the backstop.
T="$(mktemp -d)"; ( cd "$T"; git init -q; git config user.email a@b.c; git config user.name t
  git commit -q --allow-empty -m base
  _mkspec2 specs/two-streams
  mkdir -p .runs/two-streams db/migrations
  printf '{"run":"two-streams","pipeline":"mvp","source":"harness","intends_code":true,"spec_present":true,"spec_path":"specs/two-streams/spec.md","role_plan":[{"ws":"WS-1","tier":"single-thread","paths":"docs/guide.md"}]}\n' > .runs/two-streams/RUN
  printf 'two-streams\n' > .runs/current
  printf 'x\n' > db/migrations/001.sql; git add -A; git commit -q -m b1
  printf '{"id":"B1","kind":"code","status":"announced","base":"%s"}\n' "$(git rev-parse HEAD~1)" > .runs/two-streams/batches.jsonl
  got="$( . "$here/bin/delivery-lib.sh"; TEAM_BOOTSTRAP_RUN=two-streams required_roles_for_batch B1 )"
  _chk "$(printf '%s' "$got" | grep -cw regression-guardian)" "1" \
       "AC-4d a migration in a light work-stream still escalates (diff lifts, never lowers)" )
rm -rf "$T"

# AC-5 (INVARIANT) — whatever the plan says, a kind:code batch never drops below one reviewer, and a
# doc batch never gains one. The anti-collapse floor is not sizeable.
T="$(mktemp -d)"; ( cd "$T"; git init -q; git config user.email a@b.c; git config user.name t
  git commit -q --allow-empty -m base
  mkdir -p .runs/r
  printf '{"run":"r","pipeline":"single-thread","source":"harness","intends_code":true,"role_plan":[{"ws":"WS-1","tier":"single-thread","paths":"docs/x.md"}]}\n' > .runs/r/RUN
  printf 'r\n' > .runs/current
  printf 'x\n' > c.js; git add -A; git commit -q -m b1
  printf '{"id":"B1","kind":"code","status":"announced","base":"%s"}\n{"id":"B2","kind":"doc","status":"announced"}\n' "$(git rev-parse HEAD~1)" > .runs/r/batches.jsonl
  c="$( . "$here/bin/delivery-lib.sh"; TEAM_BOOTSTRAP_RUN=r required_roles_for_batch B1 )"
  d="$( . "$here/bin/delivery-lib.sh"; TEAM_BOOTSTRAP_RUN=r required_roles_for_batch B2 )"
  _chk "$(printf '%s' "$c" | grep -cw code-reviewer)" "1" "AC-5 the lightest plan still keeps one reviewer on a code batch"
  _chk "$(printf '%s' "$d" | tr -d ' \n')" ""            "AC-5 …and a doc batch still earns none" )
rm -rf "$T"

echo
echo "WS-5 — the Phase A skip is OBSERVED, not asserted (AC-7):"

# Mode 2 tells the orchestrator to CHECK the artifacts rather than re-draft them — but deliver.md is
# prose, and prose lands ~70% of the time (references/enforcement.md). There is no way to watch the
# skip directly: record-dispatch matches Agent|Task, and speckit-specify is a Skill, so its invocation
# is invisible to the harness. So the ARTIFACT is watched instead: hashed at run start, compared here.
# WARN, not HARD, for one release (OQ-3) — mid-flight spec revision is legitimate and common, and
# shipping a block on an unvalidated heuristic reproduces the false-block class ADR-0015 removed.
_pf() { TEAM_BOOTSTRAP_RUN=r "$here/bin/check-preflight.sh" "$1" 2>&1 || true; }

_setup_drift() {   # $1 = dir
  ( cd "$1"; git init -q; git config user.email a@b.c; git config user.name t
    printf 'x\n' > f.txt; git add -A; git commit -q -m base
    mkdir -p specs/m docs .runs/r
    printf '# Spec\n' > specs/m/spec.md; printf '# Plan\n' > specs/m/plan.md; printf '# Tasks\n' > specs/m/tasks.md
    printf '{"active_spec":"specs/m","specs_dir":"specs","constitution":"constitution.md","adr_dir":"docs/adr"}\n' > feature.json
    printf '# C\n' > constitution.md; mkdir -p docs/adr
    printf 'Test: `bash t.sh`\n' > AGENTS.md
    h="$( { shasum -a 256 specs/m/spec.md 2>/dev/null || sha256sum specs/m/spec.md; } | cut -d' ' -f1 )"
    printf '{"run":"r","pipeline":"mvp","source":"harness","feature":"specs/m/spec.md","intends_code":true,"baseline_sha":"%s","spec_present":true,"spec_path":"specs/m/spec.md","spec_artifacts":[{"file":"spec.md","sha256":"%s"}]}\n' \
      "$(git rev-parse HEAD)" "$h" > .runs/r/RUN
    printf 'r\n' > .runs/current )
}

# AC-7a — untouched artifacts say nothing.
T="$(mktemp -d)"; _setup_drift "$T"
_chk "$(_pf "$T" | grep -c 'spec artifact')" "0" "AC-7a untouched artifacts → no drift report"
rm -rf "$T"

# AC-7b — a SILENT rewrite is reported.
T="$(mktemp -d)"; _setup_drift "$T"
printf '# Spec\n\nrewritten by a producing step\n' > "$T/specs/m/spec.md"
_chk "$(_pf "$T" | grep -c 'spec artifact')" "1" "AC-7b a silent mid-flight rewrite is reported"
rm -rf "$T"

# AC-7c — …but it is advisory this release: a drift alone must not fail the gate.
T="$(mktemp -d)"; _setup_drift "$T"
printf '# Spec\n\nrewritten\n' > "$T/specs/m/spec.md"
rc=0; TEAM_BOOTSTRAP_RUN=r "$here/bin/check-preflight.sh" "$T" >/dev/null 2>&1 || rc=$?
_chk "$rc" "0" "AC-7c drift is WARN, not HARD, for one release (OQ-3)"
rm -rf "$T"

# AC-7d — a run with no spec on disk has nothing to drift, and must not gain a spurious report.
T="$(mktemp -d)"; ( cd "$T"; git init -q; git config user.email a@b.c; git config user.name t
  printf 'x\n' > f.txt; git add -A; git commit -q -m base
  mkdir -p specs .runs/r docs/adr
  printf '{"active_spec":null,"specs_dir":"specs","constitution":"constitution.md","adr_dir":"docs/adr"}\n' > feature.json
  printf '# C\n' > constitution.md; printf 'Test: `bash t.sh`\n' > AGENTS.md
  printf '{"run":"r","pipeline":"auto","source":"harness","intends_code":true,"baseline_sha":"%s","spec_present":false}\n' \
    "$(git rev-parse HEAD)" > .runs/r/RUN; printf 'r\n' > .runs/current )
_chk "$(_pf "$T" | grep -c 'spec artifact')" "0" "AC-7d description-form run → no drift report (AC-10 shape)"
rm -rf "$T"

echo
echo "WS-6 — the description form does not regress (AC-10):"

# The milestone changes what happens when a spec EXISTS. A description-form run must be untouched:
# no spec fields invented, and every gate that enforced before still enforces. The one intentional
# difference is the tier token (full -> auto), and it must not weaken anything — AC-8/R4 pin that.
T="$(mktemp -d)"; ( cd "$T"; git init -q; git config user.email a@b.c; git config user.name t
  git commit -q --allow-empty -m base
  m="$(_arm '/deliver "add a retry wrapper to the http client"')"
  _chk "$(_field spec_present "$m")" "false"   "AC-10 description form → spec_present:false"
  _chk "$(_field spec_path    "$m")" "<absent>" "AC-10 …no spec_path invented"
  _chk "$(_field role_plan    "$m")" "<absent>" "AC-10 …no role_plan invented"
  _chk "$(_field feature      "$m")" "unknown"  "AC-10 …feature stays the no-spec sentinel" )
rm -rf "$T"

# AC-10 — check-role-dispatch must NOT treat the new token as an exemption. Only single-thread is
# exempt; if `auto` ever fell into that branch, the reviewer-independence check would go silent.
T="$(mktemp -d)"; ( cd "$T"; git init -q; git config user.email a@b.c; git config user.name t
  git commit -q --allow-empty -m base; printf 'x\n' > c.js; git add -A; git commit -q -m work
  mkdir -p .runs/r
  printf '{"run":"r","pipeline":"auto","source":"harness","intends_code":true,"baseline_sha":"%s"}\n' "$(git rev-parse HEAD~1)" > .runs/r/RUN
  printf 'r\n' > .runs/current
  printf '{"id":"B1","kind":"code","status":"announced","base":"%s"}\n' "$(git rev-parse HEAD~1)" > .runs/r/batches.jsonl
  out="$(TEAM_BOOTSTRAP_RUN=r "$here/bin/check-role-dispatch.sh" 2>&1 || true)"
  _chk "$(printf '%s' "$out" | grep -c 'sanctioned contract')" "0" \
       "AC-10 pipeline=auto is not treated as the single-thread exemption" )
rm -rf "$T"

echo
echo "WS-1 — hostile tasks.md content cannot corrupt the marker (adversarial):"

# tasks.md is authored content, and its paths are spliced into the marker JSON. A path containing a
# quote or a backslash produced an INVALID marker. That marker is the machine fact every gate reads,
# and an unparseable one is exactly the state atomic-marker.test.sh AC-A1 pins as a fail-OPEN.
T="$(mktemp -d)"; ( cd "$T"; git init -q; git config user.email a@b.c; git config user.name t
  git commit -q --allow-empty -m base
  mkdir -p specs/evil
  printf '# Spec\n' > specs/evil/spec.md; printf '# Plan\n' > specs/evil/plan.md
  printf '# Tasks\n\n## Phase 1 — WS-1: hostile\n- [ ] T010 Do it.\n  - file: bin/we"ird.sh, bin/back\\slash.sh, bin/ok.sh · (feat · P10) — AC-1\n' > specs/evil/tasks.md
  m="$(_arm '/deliver specs/evil/spec.md')"
  ok="$(python3 -c "import json;json.load(open('$m'));print('valid')" 2>/dev/null || echo invalid)"
  _chk "$ok" "valid" "hostile path characters in tasks.md still yield a parseable marker"
  # and the sane path survives — sanitising must not silently drop everything
  _chk "$(grep -c 'bin/ok.sh' "$m" || true)" "1" "…and the well-formed path in the same task is kept" )
rm -rf "$T"

fail="$(cat "$FAILF")"; rm -f "$FAILF"
[ "$fail" -eq 0 ] && { echo "spec-sourced-sizing.test.sh: OK"; exit 0; }
echo "spec-sourced-sizing.test.sh: $fail failure(s)"; exit 1
