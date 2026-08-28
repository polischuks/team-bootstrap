#!/usr/bin/env bash
# hook-behaviour.test.sh — BEHAVIOUR tests for the three hooks that were wired but never exercised.
#
# The spec-020 audit found AC-38 (guard-git `if` filter), AC-41/42 (session-context on
# SessionStart/PreCompact/PostCompact) and AC-43 (check-review-batch on PostToolBatch) satisfied
# STRUCTURALLY — the hook registered, no test referencing its behaviour. A registered hook whose
# behaviour nothing asserts is exactly the "green by wiring" class check-gate-integrity exists to
# reject, one layer up. This suite closes that gap: every check here runs the hook body against a
# fixture and asserts what it DOES.
#
# RECORDED DIVERGENCE (AC-43, spec wrong — not the code). Spec 020 AC-43 reads "PostToolBatch
# используется как гейт … (событие может блокировать)" with the check "веер с одним неотвеченным
# ревью не проходит". The shipped contract is INFORM-ONLY (exit 0 always), and that is the correct
# design: blocking the model's turn over a missing dispatch makes inline review the cheapest way out —
# the spec-169 collapse this pipeline exists to prevent — which the milestone's own Out-of-scope and
# the hook's header both state. The hard floor lives where it can be satisfied without that pressure:
# check-role-dispatch at closure. This suite PINS the inform-only contract (a3); if someone "fixes"
# the hook to match the spec's letter, that check reds and points here.
#
# HONEST LIMIT (AC-38): whether the harness actually skips the spawn on a non-git Bash call is vendor
# behaviour, not observable from this repo. What IS testable: the filter is registered (c1), and the
# guard does not DEPEND on it — its verdict is correct on whatever reaches it, filtered or not
# (c5/c6). If the filter were the only thing between a non-git payload and a wrong verdict, a filter
# miss would be an incident; c5 proves it is a cost control, not the boundary.
#
# Fixture discipline (four false positives in the first draft of this audit, each from asserting a
# mechanism unread — P11): hooks DRAIN STDIN (feed them a payload or they wedge); guard-git gates only
# an ARMED run (a fixture without a marker tests nothing); PreCompact is SILENT BY DESIGN ("persist,
# do not speak" — assert the file, not stdout); delivery-lib needs bash, not zsh (BASH_SOURCE).
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
_chk() { if [ "$1" = "$2" ]; then printf '  PASS %s\n' "$3"
  else printf '  FAIL %s (got [%s] want [%s])\n' "$3" "$1" "$2" >&2; fail=$((fail + 1)); fi; }
PY() { python3 -c "$1" "${@:2}"; }
# _has NEEDLE HAYSTACK → yes/no substring test (a multiline `case` inside $(…) trips the parser)
_has() { case "$2" in *"$1"*) echo yes ;; *) echo no ;; esac; }

# _ctx_of JSON → the additionalContext string, or "" when stdout was empty/not an envelope
_ctx_of() { PY 'import json,sys
raw=sys.stdin.read().strip()
if not raw: print(""); raise SystemExit
try: print(json.loads(raw)["hookSpecificOutput"].get("additionalContext",""))
except Exception: print("<invalid>")' ; }

# _event_of JSON → hookEventName, or "" when silent
_event_of() { PY 'import json,sys
raw=sys.stdin.read().strip()
if not raw: print(""); raise SystemExit
try: print(json.loads(raw)["hookSpecificOutput"].get("hookEventName","<absent>"))
except Exception: print("<invalid>")' ; }

# _arm DIR [BATCH_STATUS] → git repo + armed full/code marker; optional code batch in that status with
# a RECORDED required set [integration-verifier code-reviewer] and ONE recorded code-reviewer dispatch,
# so required-vs-covered is deterministic: missing = integration-verifier.
_arm() {
  local d="$1" st="${2:-}"
  ( cd "$d" || exit 1
    git init -q -b main 2>/dev/null || { git init -q; git checkout -q -b main; }
    git config user.email a@b.c; git config user.name t
    printf 'x\n' > seed.txt; git add -A; git commit -q -m base
    mkdir -p .runs/r
    printf '{"run":"r","pipeline":"full","intends_code":true,"source":"harness","baseline_sha":"%s"}\n' \
      "$(git rev-parse --short HEAD)" > .runs/r/RUN
    if [ -n "$st" ]; then
      printf '{"id":"B1","kind":"code","status":"%s","risk_rank":"feature","required_roles":["integration-verifier","code-reviewer"]}\n' \
        "$st" > .runs/r/batches.jsonl
      printf '{"batch":"B1","subagent_type":"team-bootstrap:tb-code-reviewer"}\n' > .runs/r/dispatch.jsonl
    fi
  ) >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Block A — check-review-batch.sh (PostToolBatch, AC-43)
# ---------------------------------------------------------------------------
CRB="$here/bin/check-review-batch.sh"
_crb()    { ( cd "$1" || exit 1; printf '{}' | TEAM_BOOTSTRAP_RUN=r "$CRB" 2>/dev/null ); }
_crb_rc() { ( cd "$1" || exit 1; printf '{}' | TEAM_BOOTSTRAP_RUN=r "$CRB" >/dev/null 2>&1 ); echo $?; }

echo "a1 — no armed run: silent, exit 0:"
T="$(mktemp -d)"; ( cd "$T" && git init -q ) >/dev/null 2>&1
_chk "$(_crb "$T")" "" "no marker ⇒ says nothing"
_chk "$(_crb_rc "$T")" 0 "  …and exits 0"
rm -rf "$T"

echo "a2 — announced code batch short of its recorded set: the gap is REPORTED on the channel:"
T="$(mktemp -d)"; _arm "$T" announced
AOUT="$(_crb "$T")"
_chk "$(_event_of <<<"$AOUT")" PostToolBatch "stdout is the sanctioned PostToolBatch envelope"
ACTX="$(_ctx_of <<<"$AOUT")"
_chk "$(_has "batch B1" "$ACTX")" yes "  …naming the batch"
_chk "$(_has "missing [integration-verifier]" "$ACTX")" yes "  …and naming exactly the missing role"

echo "a3 — AC-43 divergence PIN: the hook INFORMS and never blocks (exit 0 even with a gap):"
_chk "$(_crb_rc "$T")" 0 \
  "missing role ⇒ still exit 0 — the hard floor is check-role-dispatch at closure, not this event"
rm -rf "$T"

echo "a4 — every required role covered: the pass is the silence:"
T="$(mktemp -d)"; _arm "$T" announced
( cd "$T" && printf '{"batch":"B1","subagent_type":"team-bootstrap:integration-verifier"}\n' >> .runs/r/dispatch.jsonl )
_chk "$(_crb "$T")" "" "full coverage ⇒ says nothing"
rm -rf "$T"

echo "a5 — a doc batch earns no review fan-out:"
T="$(mktemp -d)"; _arm "$T" announced
( cd "$T" && printf '{"id":"B1","kind":"doc","status":"announced"}\n' > .runs/r/batches.jsonl )
_chk "$(_crb "$T")" "" "kind:doc ⇒ says nothing"
rm -rf "$T"

echo "a6 — a CLOSED batch is a record, not an obligation (inflight_batch's last-line fallback):"
# inflight_batch falls back to the LAST ledger line when nothing is announced — so after a batch
# closes, this hook kept announcing its role gap as "still missing … fails closed at closure" on every
# PostToolBatch of every later session: a duty closure already discharged, re-stated as pending (P6).
T="$(mktemp -d)"; _arm "$T" closed
_chk "$(_crb "$T")" "" "only a closed batch in the ledger ⇒ says nothing"
rm -rf "$T"

# ---------------------------------------------------------------------------
# Block B — session-context.sh (SessionStart/PreCompact/PostCompact, AC-41/AC-42)
# ---------------------------------------------------------------------------
SC="$here/bin/session-context.sh"
_sc() { ( cd "$1" || exit 1; printf '{}' | TEAM_BOOTSTRAP_RUN=r "$SC" "$2" 2>/dev/null ); }

echo "b1 — SessionStart delivers the invariants even with no armed run:"
T="$(mktemp -d)"; ( cd "$T" && git init -q ) >/dev/null 2>&1
BOUT="$(_sc "$T" SessionStart)"
_chk "$(_event_of <<<"$BOUT")" SessionStart "stdout is the sanctioned SessionStart envelope"
B1CTX="$(_ctx_of <<<"$BOUT")"
_chk "$(_has "P3" "$B1CTX")$(_has "P9" "$B1CTX")" yesyes "  …carrying the constitution's invariants"
rm -rf "$T"

echo "b2 — with an armed run and an ANNOUNCED batch, the live state rides along:"
T="$(mktemp -d)"; _arm "$T" announced
BCTX="$(_ctx_of <<<"$(_sc "$T" SessionStart)")"
_chk "$(_has "Active delivery run r" "$BCTX")" yes "context states the active run"
_chk "$(_has "In-flight batch B1 (status=announced" "$BCTX")" yes "  …and the announced batch as in-flight"
rm -rf "$T"

echo "b3 — PreCompact persists and does not speak (the durable copy is the point):"
T="$(mktemp -d)"; _arm "$T" announced
_chk "$(_sc "$T" PreCompact)" "" "stdout is EMPTY — the window is about to be discarded"
_chk "$(_has "Active delivery run r" "$(cat "$T/.runs/r/precompact-state" 2>/dev/null)")" yes \
  "  …and the run state landed in .runs/r/precompact-state"
rm -rf "$T"

echo "b4 — PostCompact restates a live run, and says nothing when nothing is live:"
T="$(mktemp -d)"; _arm "$T" announced
_chk "$(_has "Active delivery run r" "$(_ctx_of <<<"$(_sc "$T" PostCompact)")")" yes \
  "armed run survives the compaction in words, not just on disk"
rm -rf "$T"
T="$(mktemp -d)"; ( cd "$T" && git init -q ) >/dev/null 2>&1
_chk "$(_sc "$T" PostCompact)" "" "no armed run ⇒ PostCompact is silent"
rm -rf "$T"

echo "b5 — a CLOSED batch is never presented as in-flight:"
# The same last-line fallback printed the oxymoron "In-flight batch RL-1 (status=closed)" at the top
# of every session on this repo. Truthful state for a closed-only ledger: the run, without a batch.
T="$(mktemp -d)"; _arm "$T" closed
BCTX="$(_ctx_of <<<"$(_sc "$T" SessionStart)")"
_chk "$(_has "In-flight" "$BCTX")" no "closed-only ledger ⇒ no in-flight claim in the session context"
_chk "$(_has "Active delivery run r" "$BCTX")" yes "  …while the armed run itself is still stated"
rm -rf "$T"

# ---------------------------------------------------------------------------
# Block C — guard-git.sh (PreToolUse[Bash] with `if: "Bash(git *)"`, AC-38)
# ---------------------------------------------------------------------------
GG="$here/bin/guard-git.sh"
_gg_rc() { ( cd "$1" || exit 1; printf '%s' "$2" | TEAM_BOOTSTRAP_RUN=r "$GG" >/dev/null 2>&1 ); echo $?; }
_commit_payload='{"tool_name":"Bash","tool_input":{"command":"git commit -m x"}}'

echo "c1 — the spawn filter is registered with permission-rule syntax:"
_chk "$(PY 'import json,sys
h=json.load(open(sys.argv[1]))["hooks"].get("PreToolUse",[])
print("yes" if any(c.get("if")=="Bash(git *)" for g in h for c in g.get("hooks",[]) if "guard-git" in c.get("command","")) else "no")' \
  "$here/hooks/hooks.json")" yes 'guard-git carries if: "Bash(git *)"'

echo "c2 — unarmed repo: the guard is a no-op (off-delivery commits are free):"
T="$(mktemp -d)"; ( cd "$T" || exit 1; git init -q -b main 2>/dev/null || { git init -q; git checkout -q -b main; }
  git config user.email a@b.c; git config user.name t; printf 'x\n' > s; git add -A; git commit -q -m base ) >/dev/null 2>&1
_chk "$(_gg_rc "$T" "$_commit_payload")" 0 "no marker ⇒ default-branch commit allowed"
rm -rf "$T"

echo "c3 — armed run: a commit on the DEFAULT branch is refused (P5, branch first):"
T="$(mktemp -d)"; _arm "$T"
_chk "$(_gg_rc "$T" "$_commit_payload")" 2 "default-branch commit under an armed run ⇒ exit 2"
BMSG="$( cd "$T" && printf '%s' "$_commit_payload" | TEAM_BOOTSTRAP_RUN=r "$GG" 2>&1 >/dev/null; : )"
_chk "$(_has "branch" "$BMSG")" yes "  …and the refusal names the branch discipline"

echo "c4 — armed run: the same commit on a feature branch passes:"
( cd "$T" && git checkout -q -b feat ) >/dev/null 2>&1
_chk "$(_gg_rc "$T" "$_commit_payload")" 0 "feature-branch commit ⇒ allowed"

echo "c5 — the verdict does not depend on the spawn filter (it is a cost control, not the boundary):"
_chk "$(_gg_rc "$T" '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}')" 0 \
  "a non-git payload that reaches the hook anyway is allowed, not mis-blocked"

echo "c6 — TOTAL on garbage: an undecodable payload never breaks the shell:"
_chk "$(_gg_rc "$T" 'not json at all')" 0 "garbage in ⇒ exit 0, fail-open by design"

echo "c7 — the kill switch is honoured even where c3 would block:"
( cd "$T" && git checkout -q main ) >/dev/null 2>&1
_chk "$( ( cd "$T" || exit 1; printf '%s' "$_commit_payload" | TEAM_BOOTSTRAP_RUN=r TEAM_BOOTSTRAP_GITGUARD=off "$GG" >/dev/null 2>&1 ); echo $? )" 0 \
  "TEAM_BOOTSTRAP_GITGUARD=off ⇒ exit 0 on the exact payload c3 refuses"
rm -rf "$T"

# ---------------------------------------------------------------------------
# Issue #45 — a gate whose SUBJECT is absent must skip, not block.
#
# check-role-liveness governs team-bootstrap's OWN role registry (P12), and is wired into
# verify-batch.sh, which runs in every TARGET repository — where no role registry exists or should.
# Exiting 64 there blocked every batch of every delivery outside this repo, with no waiver path:
# reported from a real delivery with 18 of 19 gates green and five independent reviews done.
#
# "Cannot check because there is nothing here to check" is not "cannot check because something is
# wrong". Only the second may block — the line check-version-sync already draws.
# ---------------------------------------------------------------------------
echo "#45 — role-liveness skips (not blocks) where its subject does not exist:"
F="$(mktemp -d)"; mkdir -p "$F/bin"
printf '# an application repo, not team-bootstrap\n' > "$F/constitution.md"
_rc45() { bash "$here/bin/check-role-liveness.sh" "$1" >/dev/null 2>&1; echo $?; }
_msg45() { bash "$here/bin/check-role-liveness.sh" "$1" 2>&1 | tail -1; }

_chk "$(_rc45 "$F")" 0 "no bin/eval-role.sh ⇒ exit 0, the batch is not blocked"
_chk "$(_msg45 "$F" | grep -qiE 'not applicable|nothing to check|no role registry|skipping' && echo stated || echo silent)" stated \
  "  …and the skip states WHY, rather than passing in silence"
_chk "$(bash "$here/bin/check-version-sync.sh" "$F" >/dev/null 2>&1; echo $?)" 0 "  parity: check-version-sync skips the same dir"
_chk "$(bash "$here/bin/check-context-phrasing.sh" "$F" >/dev/null 2>&1; echo $?)" 0 "  parity: check-context-phrasing skips the same dir"

# The skip is NARROW: on team-bootstrap itself the gate must still run and still pass.
_chk "$(_rc45 "$here")" 0 "on team-bootstrap itself the gate still passes"
_chk "$(bash "$here/bin/check-role-liveness.sh" "$here" 2>&1 | grep -qF 'binding(s) alive' && echo ran || echo skipped)" ran \
  "  …and it really RAN there — not the same skip path"

# MUTATION: subject PRESENT but the claim false must still block, or the fix swallowed a real failure.
M="$(mktemp -d)"; mkdir -p "$M/bin"
for f in eval-role.sh delivery-lib.sh select-pipeline.sh; do cp "$here/bin/$f" "$M/bin/" 2>/dev/null; done
for d in profiles references agents; do cp -R "$here/$d" "$M/$d" 2>/dev/null; done
printf '| Live role bindings (`bin/eval-role.sh --liveness`) | 999 | x |\n' > "$M/constitution.md"
_chk "$([ "$(_rc45 "$M")" -ne 0 ] && echo blocks || echo passes)" blocks \
  "  MUTATION: subject present but the declared count false ⇒ still blocks"
rm -rf "$F" "$M"

if [ "$fail" -eq 0 ]; then echo "hook-behaviour: OK"; exit 0; fi
echo "hook-behaviour: $fail FAILED" >&2; exit 1
