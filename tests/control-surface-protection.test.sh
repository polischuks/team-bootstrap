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

# mk_repo TMP → init a git repo with a baseline commit; echo the baseline short sha. The repo declares
# its OWN control surface by shipping references/control-surface.txt (copied from the real list), because
# the standing seam is read TARGET-relative (F2) — a repo without this file is not subject to it.
mk_repo() {
  local t="$1"
  ( cd "$t" && git init -q && git config user.email t@t && git config user.name t \
    && echo seed > seed && mkdir -p references && cp "$here/references/control-surface.txt" references/control-surface.txt \
    && git add . && git commit -qm base ) >/dev/null 2>&1
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

# --- F1 (review fix) — cross-batch ack reuse: an EARLIER batch's control-surface ack must NOT satisfy a
# LATER batch's surface edit. The ack must fall within the CURRENT batch window (current_batch_base..HEAD),
# not merely post-baseline. Batch 1 makes a benign, acked AGENTS.md edit and CLOSES at c1; Batch 2 tampers
# bin/check-x.sh with NO new ack → its window base is c1, so the c1 ack no longer covers it → FAIL.
T="$(mktemp -d)"; base="$(mk_repo "$T")"
c1="$(commit_change "$T" AGENTS.md)"
mkdir -p "$T/.runs/r"
printf '{"id":"B1","kind":"code","status":"closed","commit_shas":["%s"],"code_delta":1}\n' "$c1" > "$T/.runs/r/batches.jsonl"
commit_change "$T" bin/check-x.sh >/dev/null
printf '{"id":"B2","kind":"code","status":"announced","files":["bin/check-x.sh"]}\n' >> "$T/.runs/r/batches.jsonl"
marker "$T" "{\"run\":\"r\",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$base\",\"seam_acks\":[{\"seam\":\"control-surface\",\"commit\":\"$c1\",\"note\":\"AGENTS.md:1 batch 1\"}]}"
_chk "F1 batch-1 ack does NOT cover batch-2 surface edit → FAIL (window-scoped)" "$(_run "$T")" 1
rm -rf "$T"

# --- F2 (review fix) — a TARGET repo that does not ship references/control-surface.txt is NOT subject to
# the plugin's standing seam: editing its own generically-named AGENTS.md → skip (PASS), not a false FAIL.
# (The control surface is a property of the repo being delivered; the plugin's own list is not imposed on
# unrelated targets.) Uses a bare init WITHOUT the list file.
T="$(mktemp -d)"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t \
  && echo seed > seed && git add . && git commit -qm base ) >/dev/null 2>&1
base="$(cd "$T" && git rev-parse --short HEAD)"
commit_change "$T" AGENTS.md >/dev/null
marker "$T" "{\"run\":\"r\",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$base\"}"; ledger_code "$T"
_chk "F2 target without control-surface.txt edits AGENTS.md → PASS (not the plugin's surface)" "$(_run "$T")" 0
rm -rf "$T"

[ "$fail" -eq 0 ] && { echo "control-surface-protection.test.sh: OK"; exit 0; }
echo "control-surface-protection.test.sh: $fail failure(s)" >&2; exit 1
