#!/usr/bin/env bash
# tests/control-surface-protection.test.sh — behavioral test for the STANDING control-surface seam
# (milestone control-surface-protection). Black-box: drives the REAL bin/check-seam-ack.sh against
# fixture repos whose files match references/control-surface.txt globs.
#
# The standing seam makes a kind:code batch that touches the plugin's own control surface
# (bin/check-*.sh, verify-batch.sh, delivery-lib.sh, hooks/*.json, .claude/**, .mcp.json, AGENTS.md,
# commands/**, agents/**, the list file itself) REQUIRE a `control-surface` seam-ack — enforced by the
# hardened, glob-aware check-seam-ack (no new gate). Exercises AC-1/2/3/4/4b/5/Empty/Legacy.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
gate="$here/bin/check-seam-ack.sh"
fail=0
[ -x "$gate" ] || { echo "FAIL: $gate missing/not executable" >&2; exit 1; }

# _run TMP → run the gate in fixture TMP with run 'r'; echo exit code.
_run() { ( cd "$1" && TEAM_BOOTSTRAP_RUN=r "$gate" . >/dev/null 2>&1 ); echo $?; }
_chk() { if [ "$2" = "$3" ]; then echo "  PASS (exit $2) $1"; else echo "  FAIL (exit $2 want $3) $1" >&2; fail=$((fail + 1)); fi; }

# mk_repo TMP → init a git repo with a baseline commit; echo the baseline short sha.
mk_repo() {
  local t="$1"
  ( cd "$t" && git init -q && git config user.email t@t && git config user.name t \
    && echo seed > seed && git add . && git commit -qm base ) >/dev/null 2>&1
  ( cd "$t" && git rev-parse --short HEAD )
}
# commit_change TMP PATH → create/modify PATH and commit it; echo the new short sha.
commit_change() {
  local t="$1" p="$2"
  ( cd "$t" && mkdir -p "$(dirname "$p")" && echo x >> "$p" && git add -A && git commit -qm "touch $p" ) >/dev/null 2>&1
  ( cd "$t" && git rev-parse --short HEAD )
}
# marker TMP JSON ; ledger_code TMP  → write the run marker / a code-batch ledger entry.
marker()      { mkdir -p "$1/.runs/r"; printf '%s\n' "$2" > "$1/.runs/r/RUN"; }
ledger_code() { mkdir -p "$1/.runs/r"; printf '{"id":"B1","kind":"code","files":["x"],"status":"announced"}\n' > "$1/.runs/r/batches.jsonl"; }

# --- AC-4 — glob-aware: an ordinary batch edits a NEW bin/check-*.sh with NO control-surface ack → FAIL.
# This is the hardening regression: the pre-fix glob-blind _intersects did NOT catch bin/check-*.sh.
T="$(mktemp -d)"; base="$(mk_repo "$T")"; commit_change "$T" bin/check-newgate.sh >/dev/null
marker "$T" "{\"run\":\"r\",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$base\"}"; ledger_code "$T"
_chk "AC-4 bin/check-newgate.sh edit, no control-surface ack → FAIL (glob)" "$(_run "$T")" 1
rm -rf "$T"

# --- AC-4b — directory-prefix: .claude/agents/x.md edited, no ack → FAIL.
T="$(mktemp -d)"; base="$(mk_repo "$T")"; commit_change "$T" .claude/agents/x.md >/dev/null
marker "$T" "{\"run\":\"r\",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$base\"}"; ledger_code "$T"
_chk "AC-4b .claude/agents/x.md edit, no ack → FAIL (under-dir)" "$(_run "$T")" 1
rm -rf "$T"

# --- AC-4b — glob spans '/': hooks/nested/x.json edited, no ack → FAIL.
T="$(mktemp -d)"; base="$(mk_repo "$T")"; commit_change "$T" hooks/nested/x.json >/dev/null
marker "$T" "{\"run\":\"r\",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$base\"}"; ledger_code "$T"
_chk "AC-4b hooks/nested/x.json edit, no ack → FAIL (glob spans /)" "$(_run "$T")" 1
rm -rf "$T"

# --- AC-1 — concrete path: AGENTS.md edited, no ack → FAIL.
T="$(mktemp -d)"; base="$(mk_repo "$T")"; commit_change "$T" AGENTS.md >/dev/null
marker "$T" "{\"run\":\"r\",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$base\"}"; ledger_code "$T"
_chk "AC-1 AGENTS.md edit, no ack → FAIL" "$(_run "$T")" 1
rm -rf "$T"

# --- AC-2 — sanctioned: bin/check-newgate.sh edited WITH a valid control-surface seam-ack → PASS.
T="$(mktemp -d)"; base="$(mk_repo "$T")"; code="$(commit_change "$T" bin/check-newgate.sh)"
marker "$T" "{\"run\":\"r\",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$base\",\"seam_acks\":[{\"seam\":\"control-surface\",\"commit\":\"$code\",\"note\":\"bin/check-newgate.sh:1 read the gate edit\"}]}"; ledger_code "$T"
_chk "AC-2 surface edit + valid control-surface ack → PASS" "$(_run "$T")" 0
rm -rf "$T"

# --- AC-3 — non-surface path (src/app.py) → skip (PASS).
T="$(mktemp -d)"; base="$(mk_repo "$T")"; commit_change "$T" src/app.py >/dev/null
marker "$T" "{\"run\":\"r\",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$base\"}"; ledger_code "$T"
_chk "AC-3 non-surface edit → PASS (skip)" "$(_run "$T")" 0
rm -rf "$T"

# --- AC-3 — run not intends_code (doc run) → skip (PASS) even though it touches the surface.
T="$(mktemp -d)"; base="$(mk_repo "$T")"; commit_change "$T" bin/check-newgate.sh >/dev/null
marker "$T" "{\"run\":\"r\",\"intends_code\":false,\"source\":\"harness\",\"baseline_sha\":\"$base\"}"; ledger_code "$T"
_chk "AC-3 not intends_code → PASS (skip)" "$(_run "$T")" 0
rm -rf "$T"

# --- AC-5 — isolated edit to another gate (bin/check-tdd.sh), no ack → FAIL (no false self-protection claim).
T="$(mktemp -d)"; base="$(mk_repo "$T")"; commit_change "$T" bin/check-tdd.sh >/dev/null
marker "$T" "{\"run\":\"r\",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$base\"}"; ledger_code "$T"
_chk "AC-5 isolated bin/check-tdd.sh edit, no ack → FAIL" "$(_run "$T")" 1
rm -rf "$T"

# --- AC-Legacy — a non-control-surface seam-ack does NOT satisfy the standing seam.
# The marker records only a 'marker-rewrite' ack; the surface-touching batch still needs 'control-surface'.
T="$(mktemp -d)"; base="$(mk_repo "$T")"; code="$(commit_change "$T" bin/check-newgate.sh)"
marker "$T" "{\"run\":\"r\",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$base\",\"seam_acks\":[{\"seam\":\"marker-rewrite\",\"commit\":\"$code\",\"note\":\"unrelated\"}]}"; ledger_code "$T"
_chk "AC-Legacy only a marker-rewrite ack on a surface batch → FAIL" "$(_run "$T")" 1
rm -rf "$T"

# --- AC-Empty — resolvable base but ZERO git diff → fail-closed (must NOT fall back to declared "files").
T="$(mktemp -d)"; base="$(mk_repo "$T")"
( cd "$T" && git commit -q --allow-empty -m "empty batch" ) >/dev/null 2>&1
marker "$T" "{\"run\":\"r\",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$base\"}"; ledger_code "$T"
_chk "AC-Empty resolvable base + zero diff → FAIL (fail-closed)" "$(_run "$T")" 1
rm -rf "$T"

# --- AC-Empty — unresolvable base (single commit, baseline_sha == HEAD) → diagnosed fail.
T="$(mktemp -d)"; base="$(mk_repo "$T")"
marker "$T" "{\"run\":\"r\",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$base\"}"; ledger_code "$T"
_chk "AC-Empty unresolvable base → FAIL (diagnosed)" "$(_run "$T")" 1
rm -rf "$T"

[ "$fail" -eq 0 ] && { echo "control-surface-protection.test.sh: OK"; exit 0; }
echo "control-surface-protection.test.sh: $fail failure(s)" >&2; exit 1
