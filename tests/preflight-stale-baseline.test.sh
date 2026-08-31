#!/usr/bin/env bash
# tests/preflight-stale-baseline.test.sh — issue #102: Phase-0 stale-baseline preflight WARNING.
#
# A branch forked from an out-of-date base fail-closes at every downstream step (missing run-rate
# CapabilityOptOut #66, ADR/constitution drift, doc-commit-in-commit_shas #93) with NO single signal
# naming the common cause. check-preflight.sh must surface the root ONCE: when the run's baseline_sha is
# an ancestor of origin/<default> and behind by >=1 commit, emit a VISIBLE, NON-BLOCKING warning naming
# the rebase remedy (and, where cheaply detectable, the run-rate CapabilityOptOut present on the default
# tip but missing from the baseline). It is a WARNING — it must NOT change preflight's pass/fail verdict.
#
# Fixtures build a real remote-tracking ref without a network: refs/remotes/origin/main is set with
# `git update-ref` and refs/remotes/origin/HEAD points at it — exactly the local refs a cloned repo has.
#
# Cases:
#   A (stale)  — baseline is an ancestor of origin/main, behind by 3 → WARN present; exit UNCHANGED vs tip.
#   B (tip)    — baseline == origin/main → NO warning; exit 0.
#   C (offline)— no origin/<default> ref at all → NO warning, NO error (silent, exit unchanged).
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
PF="$here/bin/check-preflight.sh"
fail=0

# _scaffold DIR — a full, valid Phase-0 scaffold; leaves HEAD at the first commit's sha in $SCA_SHA1.
_scaffold() {
  local d="$1"
  git -C "$d" init -q
  git -C "$d" symbolic-ref HEAD refs/heads/main 2>/dev/null || true
  printf '# constitution\n' > "$d/constitution.md"
  printf '{\n  "active_spec": "specs/x",\n  "specs_dir": "specs",\n  "constitution": "constitution.md",\n  "adr_dir": "docs/adr"\n}\n' > "$d/feature.json"
  mkdir -p "$d/specs/TEMPLATE" "$d/docs/adr"
  printf 'Test: `true`\n' > "$d/AGENTS.md"
  git -C "$d" add -A >/dev/null 2>&1
  git -C "$d" -c user.email=t@t -c user.name=t commit -q -m init >/dev/null 2>&1
  SCA_SHA1="$(git -C "$d" rev-parse --short HEAD)"
}

# _advance DIR N — add N more commits on main; leaves the tip sha in $ADV_TIP. The 2nd commit introduces a
# CapabilityOptOut declaration (the run-rate opt-out #66) so the capability-drift hint is exercisable.
_advance() {
  local d="$1" n="$2" i
  for i in $(seq 1 "$n"); do
    if [ "$i" -eq 1 ]; then
      printf 'CapabilityOptOut: `mutation`\nCapabilityOptOutBy: `founder`\nCapabilityOptOutReason: `no host tool`\n' >> "$d/AGENTS.md"
    else
      printf 'line %s\n' "$i" >> "$d/constitution.md"
    fi
    git -C "$d" add -A >/dev/null 2>&1
    git -C "$d" -c user.email=t@t -c user.name=t commit -q -m "c$i" >/dev/null 2>&1
  done
  ADV_TIP="$(git -C "$d" rev-parse --short HEAD)"
}

# _set_origin DIR SHA — fake a cloned repo's remote-tracking refs (no network): origin/main → SHA,
# origin/HEAD → origin/main.
_set_origin() {
  git -C "$1" update-ref refs/remotes/origin/main "$2"
  git -C "$1" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
}

_marker() { # DIR BASELINE_SHA
  mkdir -p "$1/.runs/r"
  printf '{"run":"r","intends_code":true,"baseline_sha":"%s"}\n' "$2" > "$1/.runs/r/RUN"
}

# ---------------------------------------------------------------------------------------------------
# Case A — STALE: baseline is an ancestor of origin/main, 3 commits behind → WARN, exit unchanged.
# ---------------------------------------------------------------------------------------------------
A="$(mktemp -d)"; _scaffold "$A"; base_sha="$SCA_SHA1"; _advance "$A" 3
_set_origin "$A" "$ADV_TIP"; _marker "$A" "$base_sha"
outA="$(env -u TEAM_BOOTSTRAP_RUN "$PF" "$A" 2>&1)"; rcA=$?

if printf '%s' "$outA" | grep -qi 'stale baseline'; then
  echo "  PASS A stale baseline → warning emitted"
else
  echo "  FAIL A stale baseline → NO warning; out: $outA" >&2; fail=$((fail + 1))
fi
if printf '%s' "$outA" | grep -qi 'rebase'; then
  echo "  PASS A warning names the rebase remedy"
else
  echo "  FAIL A warning omits the rebase remedy; out: $outA" >&2; fail=$((fail + 1))
fi
if printf '%s' "$outA" | grep -q '3'; then
  echo "  PASS A warning names the commit distance (3)"
else
  echo "  FAIL A warning omits the distance; out: $outA" >&2; fail=$((fail + 1))
fi
if printf '%s' "$outA" | grep -qi 'CapabilityOptOut'; then
  echo "  PASS A warning names the missing CapabilityOptOut capability"
else
  echo "  FAIL A warning omits the CapabilityOptOut hint; out: $outA" >&2; fail=$((fail + 1))
fi

# ---------------------------------------------------------------------------------------------------
# Case B — AT TIP: baseline == origin/main → NO warning, exit 0. Also fixes the exit-parity anchor.
# ---------------------------------------------------------------------------------------------------
B="$(mktemp -d)"; _scaffold "$B"; _advance "$B" 3
_set_origin "$B" "$ADV_TIP"; _marker "$B" "$ADV_TIP"
outB="$(env -u TEAM_BOOTSTRAP_RUN "$PF" "$B" 2>&1)"; rcB=$?

if printf '%s' "$outB" | grep -qi 'stale baseline'; then
  echo "  FAIL B baseline at tip → spurious warning; out: $outB" >&2; fail=$((fail + 1))
else
  echo "  PASS B baseline at tip → no warning"
fi
if [ "$rcB" -eq 0 ]; then
  echo "  PASS B tip fixture → exit 0"
else
  echo "  FAIL B tip fixture → exit $rcB (want 0); out: $outB" >&2; fail=$((fail + 1))
fi

# exit-code parity — the warning must NOT change preflight's pass/fail verdict (same scaffold, both valid).
if [ "$rcA" -eq "$rcB" ]; then
  echo "  PASS exit parity — stale ($rcA) == tip ($rcB); the warning is non-blocking"
else
  echo "  FAIL exit parity — stale=$rcA tip=$rcB; the warning changed the verdict" >&2; fail=$((fail + 1))
fi

# ---------------------------------------------------------------------------------------------------
# Case C — OFFLINE: no origin/<default> ref → silent, no error, exit unchanged.
# ---------------------------------------------------------------------------------------------------
C="$(mktemp -d)"; _scaffold "$C"; base_c="$SCA_SHA1"; _advance "$C" 2
# deliberately DO NOT set any origin ref
_marker "$C" "$base_c"
outC="$(env -u TEAM_BOOTSTRAP_RUN "$PF" "$C" 2>&1)"; rcC=$?
if printf '%s' "$outC" | grep -qi 'stale baseline'; then
  echo "  FAIL C no origin ref → spurious warning; out: $outC" >&2; fail=$((fail + 1))
else
  echo "  PASS C no origin ref → silent (offline-safe)"
fi
if [ "$rcC" -eq 0 ]; then
  echo "  PASS C offline fixture → exit 0 (no error)"
else
  echo "  FAIL C offline fixture → exit $rcC (want 0); out: $outC" >&2; fail=$((fail + 1))
fi

[ "$fail" -eq 0 ] && { echo "preflight-stale-baseline.test: OK"; exit 0; }
echo "preflight-stale-baseline.test: $fail failure(s)" >&2; exit 1
