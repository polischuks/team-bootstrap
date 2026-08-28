#!/usr/bin/env bash
# mid-turn-resize.test.sh — issue #48: the degraded-sizing recompute must fire INSIDE one agentic turn.
#
# THE BUG. The re-size that recovers a run from its first (always-degraded, no-tasks-md) sizing lives
# in delivery-marker-init.sh, registered on UserPromptSubmit only — it fires on the next PROMPT. But
# Phase A -> Phase B routinely happens inside a SINGLE agentic turn: artefacts land, preflight runs,
# batches are announced, subagents are dispatched, all with no new user prompt. No prompt, no hook, no
# re-size — so the run stays `pipeline=auto degraded=no-tasks-md` with a fully sizable tasks.md beside
# it (observed on run 176-withgauge-platform-integration).
#
# THE FIX. Route the recompute onto a mid-turn event too. PostToolBatch fires after a tool batch
# resolves and before the model's next turn — the first moment the harness observes tasks.md land,
# with no prompt required — and this repo already relies on it (check-review-batch.sh). bin/delivery-
# resize.sh is that hook; it shares resize_degraded_marker() with the UserPromptSubmit path (one
# definition), resolves the active run from .runs/current (no prompt to parse), and is idempotent: a
# successful re-size clears sizing_degraded, so a later batch in the same turn is a no-op.
#
# Written BEFORE the fix -> red (no mid-turn hook exists, so the marker stays stuck at auto), then green.
set -uo pipefail
# Hermetic run resolution: an outer session may pin TEAM_BOOTSTRAP_RUN (this repo's own delivery run
# does), which resolve_marker honours OVER a fixture's .runs/current. Clear it so the mid-turn hook
# resolves the run under test from disk — the exact prompt-less path issue #48 is about.
unset TEAM_BOOTSTRAP_RUN
here="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
_chk() { if [ "$1" = "$2" ]; then printf '  PASS %s\n' "$3"
  else printf '  FAIL %s (got [%s] want [%s])\n' "$3" "$1" "$2" >&2; fail=$((fail + 1)); fi; }
PY() { python3 -c "$1" "${@:2}"; }
_ctx_of() { PY 'import json,sys
try: print(json.loads(sys.stdin.read()).get("hookSpecificOutput",{}).get("additionalContext",""))
except Exception: print("")'; }
_pipe_of() { PY "import json;print(json.load(open('$1'))['pipeline'])"; }
_degr_of() { PY "import json;print(json.load(open('$1')).get('sizing_degraded',''))"; }

# ---------------------------------------------------------------------------
# A degraded run whose artefacts have since landed is recomputed mid-turn — with NO new prompt.
# ---------------------------------------------------------------------------
E="$(mktemp -d)"; mkdir -p "$E/specs/mt"
printf '# Spec\n\nAn auth change touching src/auth/login.ts.\n' > "$E/specs/mt/spec.md"
( cd "$E" || exit 1; git init -q; git config user.email a@b.c; git config user.name t
  printf 'x\n' > seed.txt; git add -A; git commit -q -m base ) >/dev/null 2>&1

# First arm (UserPromptSubmit), no tasks.md yet — exactly Phase A's starting state. This is the ONLY
# prompt in the scenario; everything after happens inside the same turn.
( cd "$E" || exit 1; printf '%s' '/team-bootstrap:deliver specs/mt' | "$here/bin/delivery-marker-init.sh" >/dev/null 2>&1 )
_chk "$(_pipe_of "$E/.runs/mt/RUN")" auto        "first arm, no tasks.md => pipeline=auto (degraded)"
_chk "$(_degr_of "$E/.runs/mt/RUN")" no-tasks-md "  …and the degradation is recorded"
# .runs/current must point at this run, so a prompt-less hook can resolve it.
_chk "$(cat "$E/.runs/current" 2>/dev/null)" mt  "  …and .runs/current names the run"

# Phase A produces the artefacts — mid-turn, no prompt. Another gate has also written to the marker.
printf '# Tasks\n\n## WS-A\n\n- [ ] T1 a `src/auth/x.ts`\n' > "$E/specs/mt/tasks.md"
PY "import json
p='$E/.runs/mt/RUN'; m=json.load(open(p))
m['preflight']={'exit':0,'gaps':[],'ack':True}; m['repro_env']=['container:docker']
json.dump(m, open(p,'w'))"

# THE MID-TURN EVENT. A PostToolBatch fires after the Write batch that produced tasks.md — no prompt.
# The hook must recompute the degraded sizing here, not wait for the next UserPromptSubmit.
CTXM="$( cd "$E" || exit 1; printf '{}' | "$here/bin/delivery-resize.sh" 2>/dev/null | _ctx_of )"

_chk "$(_pipe_of "$E/.runs/mt/RUN")" full \
  "the mid-turn hook RE-SIZES the degraded run — no prompt needed (issue #48)"
_chk "$(_degr_of "$E/.runs/mt/RUN")" "" \
  "  …and the degradation is cleared"
_chk "$(printf '%s' "$CTXM" | grep -qiF 're-sized' && echo yes || echo no)" yes \
  "  …and the mid-turn context says the run was re-sized"

# Fields the hook does not own survive the mid-turn splice (same guarantee as the prompt path).
_chk "$(PY "import json;print(json.load(open('$E/.runs/mt/RUN')).get('preflight',{}).get('ack'))")" True \
  "  …and another gate's preflight ack survives"

# IDEMPOTENCY. A second PostToolBatch in the same turn must NOT re-fire — sizing_degraded is now empty,
# so it is a no-op that emits nothing and leaves the settled verdict untouched (no thrash).
CTXM2="$( cd "$E" || exit 1; printf '{}' | "$here/bin/delivery-resize.sh" 2>/dev/null | _ctx_of )"
_chk "$(_pipe_of "$E/.runs/mt/RUN")" full \
  "a second mid-turn hook leaves the settled verdict alone (idempotent)"
_chk "$([ -z "$CTXM2" ] && echo empty || echo nonempty)" empty \
  "  …and emits no context the second time"

# A non-degraded run is never touched mid-turn — the hook only recovers a DEGRADED verdict.
N="$(mktemp -d)"; mkdir -p "$N/specs/ok"
printf '# Spec\n\nAn auth change touching src/auth/login.ts.\n' > "$N/specs/ok/spec.md"
printf '# Tasks\n\n## WS-A\n\n- [ ] T1 a `src/auth/x.ts`\n' > "$N/specs/ok/tasks.md"
( cd "$N" || exit 1; git init -q; git config user.email a@b.c; git config user.name t
  printf 'x\n' > seed.txt; git add -A; git commit -q -m base
  printf '%s' '/team-bootstrap:deliver specs/ok' | "$here/bin/delivery-marker-init.sh" >/dev/null 2>&1 )
_before="$(cat "$N/.runs/ok/RUN")"
CTXN="$( cd "$N" || exit 1; printf '{}' | "$here/bin/delivery-resize.sh" 2>/dev/null | _ctx_of )"
_chk "$(cat "$N/.runs/ok/RUN")" "$_before" \
  "a run that sized cleanly is left byte-for-byte alone by the mid-turn hook"
_chk "$([ -z "$CTXN" ] && echo empty || echo nonempty)" empty \
  "  …and emits nothing for it"

# INTEGRATION GUARD (issues #47 + #48 together). A DEGRADED run whose tier the OPERATOR declared must
# NOT be re-sized mid-turn — recomputing would overrule the human. The prompt path returns on its
# operator branch before the recompute, but this hook calls resize_degraded_marker DIRECTLY, so the
# guard lives inside that function keyed on the marker's stored tier_source. Without it, #48's mid-turn
# hook silently reintroduces the exact overrule #47 fixed on the prompt path.
OP="$(mktemp -d)"; mkdir -p "$OP/specs/op"
printf '# Spec\n\nAn auth change touching src/auth/login.ts.\n' > "$OP/specs/op/spec.md"
printf '# Tasks\n\n## WS-A\n\n- [ ] T1 a `src/auth/x.ts`\n' > "$OP/specs/op/tasks.md"
( cd "$OP" || exit 1; git init -q; git config user.email a@b.c; git config user.name t
  printf 'x\n' > seed.txt; git add -A; git commit -q -m base ) >/dev/null 2>&1
# A degraded marker the operator hand-tiered to single-thread (tier_source=operator), artefacts now present.
PY_MK() { python3 -c "import json;json.dump($1, open('$OP/.runs/op/RUN','w'))"; }
mkdir -p "$OP/.runs/op"; printf 'op\n' > "$OP/.runs/current"
PY_MK "{'run':'op','intends_code':True,'pipeline':'single-thread','tier_source':'operator','sizing_degraded':'no-tasks-md','spec_path':'$OP/specs/op/spec.md'}"
CTXO="$( cd "$OP" || exit 1; printf '{}' | "$here/bin/delivery-resize.sh" 2>/dev/null | _ctx_of )"
_chk "$(_pipe_of "$OP/.runs/op/RUN")" single-thread   "the mid-turn hook does NOT overrule an operator-declared tier (issues #47+#48)"
_chk "$([ -z "$CTXO" ] && echo empty || echo nonempty)" empty   "  …and emits nothing for it"
rm -rf "$OP"

rm -rf "$E" "$N"
if [ "$fail" -eq 0 ]; then echo "mid-turn-resize.test.sh: OK"; exit 0; fi
echo "mid-turn-resize.test.sh: $fail case(s) FAILED" >&2; exit 1
