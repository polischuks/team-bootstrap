#!/usr/bin/env bash
# retro-115-119.test.sh — behavioural spec for the #115/#116/#117/#119 retro batch.
#   #115 resolve_base_branch — the run's intended base is the target/baseline branch (declared
#        BaseBranch:/base_branch), not whatever main happens to be.
#   #116 _build_cmd — a declared Build: step is readable so Phase 0 can run it after Prepare:.
#   #117 RUN.bak durability — every machine marker update writes a sibling RUN.bak, and a lost RUN
#        is restored by a HARNESS op (marker.sh restore / marker_restore), never hand-authored.
#   #119 label-failures — a failure is labelled new-this-run vs pre-existing against a declared
#        KnownRed: allowlist, so standing-red/flaky CI is not confused with a real regression.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
FAILF="$(mktemp)"; printf '0' > "$FAILF"
_chk() { # ACTUAL EXPECTED MSG
  if [ "$1" = "$2" ]; then printf '  PASS %s\n' "$3"
  else printf '  FAIL %s (got [%s] want [%s])\n' "$3" "$1" "$2"
       printf '%s' "$(( $(cat "$FAILF") + 1 ))" > "$FAILF"; fi
}

# ---------------------------------------------------------------------------
# #115 — resolve_base_branch: declared BaseBranch: / feature.json base_branch wins,
# else origin/HEAD default, else empty. This is the branch /deliver must cut the
# delivery worktree from, so a stale ambient main never starts the fail-closed cascade.
# ---------------------------------------------------------------------------
r115() {
  local T; T="$(mktemp -d)"
  ( cd "$T" || exit 1
    git init -q; git config user.email a@b.c; git config user.name t
    . "$here/bin/delivery-lib.sh"

    # (a) feature.json base_branch is authoritative.
    printf '{"base_branch":"develop"}\n' > feature.json
    _chk "$(resolve_base_branch .)" "develop" "#115 feature.json base_branch resolves"

    # (b) AGENTS.md BaseBranch: when feature.json is silent.
    printf '{}\n' > feature.json
    printf '# agents\n\n- BaseBranch: `release/2.x`\n' > AGENTS.md
    _chk "$(resolve_base_branch .)" "release/2.x" "#115 AGENTS.md BaseBranch: resolves"

    # (c) feature.json wins over AGENTS.md when both are present (single source of truth).
    printf '{"base_branch":"develop"}\n' > feature.json
    _chk "$(resolve_base_branch .)" "develop" "#115 feature.json base_branch beats AGENTS.md"

    # (d) neither declared, no origin → empty (surfaceable, not a silent wrong guess).
    rm -f feature.json AGENTS.md
    _chk "$(resolve_base_branch .)" "" "#115 nothing declared, no origin → empty"
  )
  rm -rf "$T"
}

# ---------------------------------------------------------------------------
# #116 — _build_cmd: a declared Build: is read from AGENTS.md/CLAUDE.md so the
# orchestrator can run it in Phase 0 after Prepare:. N/A|none → empty; absent → empty.
# ---------------------------------------------------------------------------
r116() {
  local T; T="$(mktemp -d)"
  ( cd "$T" || exit 1
    . "$here/bin/delivery-lib.sh"
    printf '# agents\n\n- Build: `pnpm -r build`\n- Test: `pnpm test`\n' > AGENTS.md
    _chk "$(_build_cmd)" "pnpm -r build" "#116 Build: command extracted from AGENTS.md"
    printf '# agents\n\n- Build: N/A\n' > AGENTS.md
    _chk "$(_build_cmd)" "" "#116 Build: N/A → empty"
    rm -f AGENTS.md
    _chk "$(_build_cmd)" "" "#116 no Build: declared → empty"
  )
  rm -rf "$T"
}

# ---------------------------------------------------------------------------
# #117 — RUN.bak durability. A machine marker update writes a sibling RUN.bak, and a lost
# RUN is restored by a HARNESS operation (marker.sh restore), NOT by the orchestrator
# hand-authoring intends_code/baseline_sha/pipeline.
# ---------------------------------------------------------------------------
r117_backup_on_write() {
  local T; T="$(mktemp -d)"
  ( unset TEAM_BOOTSTRAP_RUN; cd "$T" || exit 1   # hermetic: resolve the scaffolded run, not an outer delivery
    . "$here/bin/delivery-lib.sh"
    mkdir -p .runs/r
    printf '{"run":"r","intends_code":true,"baseline_sha":"abc","pipeline":"full"}\n' > .runs/r/RUN
    printf 'r\n' > .runs/current
    # A machine marker update through the sanctioned writer must drop a RUN.bak sibling.
    record_marker_list enforcement_findings '["red-first"]'
    _chk "$([ -f .runs/r/RUN.bak ] && echo yes || echo no)" "yes" \
      "#117 _marker_write drops a sibling RUN.bak on a machine marker update"
    # The backup mirrors the marker it backs up (the current, updated content — recoverable state).
    _chk "$(cat .runs/r/RUN.bak)" "$(cat .runs/r/RUN)" "#117 RUN.bak content mirrors the live RUN"
  )
  rm -rf "$T"
}

r117_restore_is_harness_op() {
  local T; T="$(mktemp -d)"
  ( unset TEAM_BOOTSTRAP_RUN; cd "$T" || exit 1   # hermetic: resolve the scaffolded run, not an outer delivery
    . "$here/bin/delivery-lib.sh"
    mkdir -p .runs/r
    local orig='{"run":"r","intends_code":true,"baseline_sha":"abc","pipeline":"full"}'
    printf '%s\n' "$orig" > .runs/r/RUN
    printf 'r\n' > .runs/current
    record_marker_list enforcement_findings '["red-first"]'   # produces RUN.bak
    local backed; backed="$(cat .runs/r/RUN)"
    # External .runs cleanup deletes RUN mid-session (the #117 failure): RUN gone, RUN.bak present.
    rm -f .runs/r/RUN
    _chk "$([ -f .runs/r/RUN ] && echo yes || echo no)" "no" "#117 precondition: RUN is gone"
    # Recovery is a HARNESS op: `marker.sh restore` copies RUN.bak → RUN. The orchestrator authors nothing.
    "$here/bin/marker.sh" restore >/dev/null 2>&1
    _chk "$([ -f .runs/r/RUN ] && echo yes || echo no)" "yes" "#117 marker.sh restore recreates RUN"
    _chk "$(cat .runs/r/RUN)" "$backed" "#117 restored RUN is byte-identical to the backup (not re-authored)"
  )
  rm -rf "$T"
}

r117_restore_noop_when_present() {
  local T; T="$(mktemp -d)"
  ( unset TEAM_BOOTSTRAP_RUN; cd "$T" || exit 1   # hermetic: resolve the scaffolded run, not an outer delivery
    . "$here/bin/delivery-lib.sh"
    mkdir -p .runs/r
    printf '{"run":"r","intends_code":true}\n' > .runs/r/RUN
    printf 'r\n' > .runs/current
    # No RUN.bak, RUN present → restore is a no-op that refuses (nothing to restore), never fabricates.
    "$here/bin/marker.sh" restore >/dev/null 2>&1; local rc=$?
    _chk "$rc" "1" "#117 restore with a healthy RUN and no backup → refuses (rc 1), no fabrication"
    _chk "$([ -f .runs/r/RUN.bak ] && echo yes || echo no)" "no" "#117 restore never invents a RUN.bak"
  )
  rm -rf "$T"
}

# ---------------------------------------------------------------------------
# #119 — label-failures: classify each failing check as new-this-run vs pre-existing,
# using a declared KnownRed: allowlist. A pre-existing/flaky check must NOT read as a
# regression; a genuinely new failure must (fail-closed exit 1).
# ---------------------------------------------------------------------------
r119() {
  local T; T="$(mktemp -d)"
  ( cd "$T" || exit 1
    printf '# agents\n\n- KnownRed: `lint`, `adr-042-dfy-guard`, `mcp-esm-imports`\n' > AGENTS.md
    local out rc
    # All three failures are on the allowlist → none new, exit 0.
    out="$("$here/bin/label-failures.sh" --dir . lint adr-042-dfy-guard mcp-esm-imports 2>&1)"; rc=$?
    _chk "$rc" "0" "#119 all failures known-red → exit 0 (no regression)"
    _chk "$(printf '%s\n' "$out" | grep -c 'pre-existing')" "3" "#119 three failures labelled pre-existing"
    _chk "$(printf '%s\n' "$out" | grep -c 'new-this-run')" "0" "#119 none labelled new-this-run"
    # A failure NOT on the allowlist is the run's own regression → labelled new, exit 1.
    out="$("$here/bin/label-failures.sh" --dir . lint backend-typecheck 2>&1)"; rc=$?
    _chk "$rc" "1" "#119 an off-allowlist failure → exit 1 (real regression)"
    _chk "$(printf '%s\n' "$out" | grep -c 'new-this-run.*backend-typecheck')" "1" "#119 the new failure is named new-this-run"
    _chk "$(printf '%s\n' "$out" | grep -c 'pre-existing.*lint')" "1" "#119 the known-red failure stays pre-existing"
  )
  rm -rf "$T"
}

echo "#115 resolve_base_branch:"; r115
echo "#116 _build_cmd:"; r116
echo "#117 RUN.bak durability:"; r117_backup_on_write; r117_restore_is_harness_op; r117_restore_noop_when_present
echo "#119 label-failures:"; r119

fail="$(cat "$FAILF")"; rm -f "$FAILF"
if [ "$fail" -eq 0 ]; then echo "retro-115-119.test.sh: OK"; exit 0; fi
echo "retro-115-119.test.sh: $fail failure(s)"; exit 1
