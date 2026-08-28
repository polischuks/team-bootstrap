#!/usr/bin/env bash
# tests/enforcement-capability.test.sh — issue #66. Two related gaps in the enforcement layer:
#
#   PART 1 (check-enforcement.sh) — a repo with NO mutation/coverage toolchain had no honest way to
#   close a run-rate/irreversible batch: the only category exempt from the risk-tier hard-require is
#   `host_structural` ("the tool provably cannot exist on host"), which is a LIE for most repos (Stryker
#   /coverage runners CAN exist), so an honest team was forced to DOWNGRADE risk_rank — the exact
#   launder the gate exists to prevent. This adds a repo-level, governed CAPABILITY opt-out
#   (`CapabilityOptOut:` in AGENTS.md/CLAUDE.md, with By/Reason and optional Expires): when present the
#   named dimensions close on the gates the repo CAN run, the missing dimension stays a recorded, visible
#   gap, and NO risk_rank downgrade is coerced — BUT only where the dimension's tool does NOT resolve
#   (where it does, the gate stays fail-closed exactly as today).
#
#   PART 2 (check-mutation.sh) — under `MutationMode: enforce` the gate had no governed `--waive`, unlike
#   the other enforce gates (check-role-verdict/check-gate-integrity). A 3-line change in a 15k-line file
#   that drags the whole file into mutation had no sanctioned escape but reverting the good change. This
#   adds `--waive BY REASON EXPIRES`, recording a governed `mutation_waiver` the gate reads AFTER printing
#   the finding.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
enf="$here/bin/check-enforcement.sh"
mut="$here/bin/check-mutation.sh"
fail=0
_chk() { if [ "$2" = "$3" ]; then echo "  PASS $1"; else echo "  FAIL $1 (got $2 want $3)" >&2; fail=$((fail + 1)); fi; }

# ---------------------------------------------------------------------------------------------------
# PART 1 — check-enforcement capability opt-out
# ---------------------------------------------------------------------------------------------------

# (a) capability declaration present, run-rate, NO cov/mut tool → closes (exit 0) + gaps still recorded.
T="$(mktemp -d)"; mkdir -p "$T/.runs/r"
printf '{"run":"r","intends_code":true,"source":"harness","baseline_sha":"x"}\n' > "$T/.runs/r/RUN"
printf '%s\n' '# AGENTS' '' '- Test: `true`' \
  '- CapabilityOptOut: `mutation diff-coverage`' \
  '- CapabilityOptOutBy: `alice`' \
  '- CapabilityOptOutReason: `bash repo — no mutation/coverage toolchain; standing decision`' > "$T/AGENTS.md"
printf '{"id":"B1","kind":"code","risk_rank":"run-rate","status":"announced"}\n' > "$T/.runs/r/batches.jsonl"
( cd "$T" && TEAM_BOOTSTRAP_RUN=r TEAM_BOOTSTRAP_NOW=2026-08-28 "$enf" . >/dev/null 2>&1 ); rc=$?
_chk "(a) capability opt-out + run-rate + no tool → closes (exit 0), no downgrade" "$rc" 0
got="$(cat "$T/.runs/r/RUN")"
case "$got" in
  *'"enforcement_gaps":['*'diff-coverage'*'mutation'*']'*) echo "  PASS (a) missing dims still recorded as a visible gap" ;;
  *) echo "  FAIL (a) enforcement_gaps not recorded: $got" >&2; fail=$((fail + 1)) ;;
esac
# risk_rank in the ledger is untouched by the gate (it never rewrites the batch line).
case "$(cat "$T/.runs/r/batches.jsonl")" in *'"risk_rank":"run-rate"'*) echo "  PASS (a) risk_rank left run-rate (no laundering)" ;;
  *) echo "  FAIL (a) risk_rank was altered" >&2; fail=$((fail + 1)) ;; esac
rm -rf "$T"

# (a') irreversible closes the same way.
T="$(mktemp -d)"; mkdir -p "$T/.runs/r"
printf '{"run":"r","intends_code":true,"source":"harness","baseline_sha":"x"}\n' > "$T/.runs/r/RUN"
printf '%s\n' '# AGENTS' '' '- Test: `true`' \
  '- CapabilityOptOut: `mutation diff-coverage`' '- CapabilityOptOutBy: `alice`' '- CapabilityOptOutReason: `no toolchain`' > "$T/AGENTS.md"
printf '{"id":"B1","kind":"code","risk_rank":"irreversible","status":"announced"}\n' > "$T/.runs/r/batches.jsonl"
( cd "$T" && TEAM_BOOTSTRAP_RUN=r "$enf" . >/dev/null 2>&1 ); rc=$?
_chk "(a') capability opt-out + irreversible + no tool → closes (exit 0)" "$rc" 0
rm -rf "$T"

# (b) WITHOUT the declaration, same run-rate + gaps + no waiver → still hard-blocks (exit 1), as today.
T="$(mktemp -d)"; mkdir -p "$T/.runs/r"
printf '{"run":"r","intends_code":true,"source":"harness","baseline_sha":"x"}\n' > "$T/.runs/r/RUN"
printf '%s\n' '# AGENTS' '' '- Test: `true`' > "$T/AGENTS.md"
printf '{"id":"B1","kind":"code","risk_rank":"run-rate","status":"announced"}\n' > "$T/.runs/r/batches.jsonl"
( cd "$T" && TEAM_BOOTSTRAP_RUN=r "$enf" . >/dev/null 2>&1 ); rc=$?
_chk "(b) no declaration + run-rate + gaps → hard-block (exit 1)" "$rc" 1
rm -rf "$T"

# (b2) DON'T WEAKEN WHERE TOOLING EXISTS: capability lists `mutation`, but Mutation: resolves (advisory) →
#      the mutation gap is deferrable, NOT capability-exempt → run-rate still hard-blocks (exit 1).
T="$(mktemp -d)"; mkdir -p "$T/.runs/r"
printf '{"run":"r","intends_code":true,"source":"harness","baseline_sha":"x"}\n' > "$T/.runs/r/RUN"
printf '%s\n' '# AGENTS' '' '- Test: `true`' '- Coverage: `true`' '- Mutation: `true`' '- MutationMode: advisory' \
  '- CapabilityOptOut: `mutation`' '- CapabilityOptOutBy: `alice`' '- CapabilityOptOutReason: `x`' > "$T/AGENTS.md"
printf '{"id":"B1","kind":"code","risk_rank":"run-rate","status":"announced"}\n' > "$T/.runs/r/batches.jsonl"
( cd "$T" && TEAM_BOOTSTRAP_RUN=r "$enf" . >/dev/null 2>&1 ); rc=$?
_chk "(b2) capability names a dim whose tool RESOLVES → not exempt → hard-block (exit 1)" "$rc" 1
rm -rf "$T"

# (b3) INCOMPLETE GOVERNANCE: CapabilityOptOut present but no By/Reason → invalid declaration → no
#      exemption → run-rate hard-blocks (exit 1). The opt-out must be attributable and justified.
T="$(mktemp -d)"; mkdir -p "$T/.runs/r"
printf '{"run":"r","intends_code":true,"source":"harness","baseline_sha":"x"}\n' > "$T/.runs/r/RUN"
printf '%s\n' '# AGENTS' '' '- Test: `true`' '- CapabilityOptOut: `mutation diff-coverage`' > "$T/AGENTS.md"
printf '{"id":"B1","kind":"code","risk_rank":"run-rate","status":"announced"}\n' > "$T/.runs/r/batches.jsonl"
( cd "$T" && TEAM_BOOTSTRAP_RUN=r "$enf" . >/dev/null 2>&1 ); rc=$?
_chk "(b3) capability opt-out without By/Reason → invalid → hard-block (exit 1)" "$rc" 1
rm -rf "$T"

# (b4) EXPIRED capability opt-out (optional expiry, but if present must be in the future) → invalid → block.
T="$(mktemp -d)"; mkdir -p "$T/.runs/r"
printf '{"run":"r","intends_code":true,"source":"harness","baseline_sha":"x"}\n' > "$T/.runs/r/RUN"
printf '%s\n' '# AGENTS' '' '- Test: `true`' '- CapabilityOptOut: `mutation diff-coverage`' \
  '- CapabilityOptOutBy: `alice`' '- CapabilityOptOutReason: `x`' '- CapabilityOptOutExpires: `2000-01-01`' > "$T/AGENTS.md"
printf '{"id":"B1","kind":"code","risk_rank":"run-rate","status":"announced"}\n' > "$T/.runs/r/batches.jsonl"
( cd "$T" && TEAM_BOOTSTRAP_RUN=r TEAM_BOOTSTRAP_NOW=2026-08-28 "$enf" . >/dev/null 2>&1 ); rc=$?
_chk "(b4) expired capability opt-out → invalid → hard-block (exit 1)" "$rc" 1
rm -rf "$T"

# ---------------------------------------------------------------------------------------------------
# PART 2 — check-mutation --waive
# ---------------------------------------------------------------------------------------------------
_mutfix() {  # $1=marker-extra-json → a fixture dir with a git repo, armed marker, enforce Mutation gate
  local extra="$1" d; d="$(mktemp -d)"
  ( cd "$d" && git init -q && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m base ) >/dev/null 2>&1
  mkdir -p "$d/.runs/r"
  printf '{"run":"r","intends_code":true,"source":"harness","baseline_sha":"x"%s}\n' "$extra" > "$d/.runs/r/RUN"
  printf '# AGENTS\n\n- Mutation: `cat mut.txt`\n- MutationMode: enforce\n- MutationThreshold: 60\n' > "$d/AGENTS.md"
  printf 'mutation_score: 40\n' > "$d/mut.txt"
  printf '%s' "$d"
}

# (c1) enforce + score below threshold + valid governed mutation_waiver → WAIVED → exit 0.
T="$(_mutfix ',"mutation_waiver":{"ack":true,"by":"alice","reason":"3-line refactor drags a 15k-line file","expires":"2999-01-01"}')"
( cd "$T" && TEAM_BOOTSTRAP_RUN=r "$mut" . >/dev/null 2>&1 ); rc=$?
_chk "(c1) enforce + low score + valid mutation_waiver → exit 0" "$rc" 0
rm -rf "$T"

# (c2) enforce + score below threshold + NO waiver → still fails (exit 1), unchanged.
T="$(_mutfix '')"
( cd "$T" && TEAM_BOOTSTRAP_RUN=r "$mut" . >/dev/null 2>&1 ); rc=$?
_chk "(c2) enforce + low score + no waiver → exit 1 (fail-closed)" "$rc" 1
rm -rf "$T"

# (c3) enforce + EXPIRED waiver → not a waiver → fail (exit 1).
T="$(_mutfix ',"mutation_waiver":{"ack":true,"by":"alice","reason":"x","expires":"2000-01-01"}')"
( cd "$T" && TEAM_BOOTSTRAP_RUN=r TEAM_BOOTSTRAP_NOW=2026-08-28 "$mut" . >/dev/null 2>&1 ); rc=$?
_chk "(c3) enforce + expired mutation_waiver → exit 1" "$rc" 1
rm -rf "$T"

# (c4) `--waive` WRITES the governed waiver, and a subsequent enforce run then passes.
T="$(_mutfix '')"
( cd "$T" && TEAM_BOOTSTRAP_RUN=r "$mut" --waive alice "large-file infeasible" 2999-01-01 >/dev/null 2>&1 ); rc=$?
_chk "(c4) --waive records the waiver → exit 0" "$rc" 0
case "$(cat "$T/.runs/r/RUN")" in *'"mutation_waiver":{'*'"by":"alice"'*) echo "  PASS (c4) mutation_waiver written to marker" ;;
  *) echo "  FAIL (c4) mutation_waiver not in marker: $(cat "$T/.runs/r/RUN")" >&2; fail=$((fail + 1)) ;; esac
( cd "$T" && TEAM_BOOTSTRAP_RUN=r "$mut" . >/dev/null 2>&1 ); rc=$?
_chk "(c4) after --waive, enforce + low score → exit 0" "$rc" 0
rm -rf "$T"

# (c5) `--waive` with a PAST expiry is REFUSED (exit 1) and writes nothing.
T="$(_mutfix '')"
( cd "$T" && TEAM_BOOTSTRAP_RUN=r "$mut" --waive alice "x" 2000-01-01 >/dev/null 2>&1 ); rc=$?
_chk "(c5) --waive with past expiry → refused (exit 1)" "$rc" 1
case "$(cat "$T/.runs/r/RUN")" in *mutation_waiver*) echo "  FAIL (c5) refused waiver was written" >&2; fail=$((fail + 1)) ;;
  *) echo "  PASS (c5) refused waiver not written" ;; esac
rm -rf "$T"

[ "$fail" -eq 0 ] && { echo "enforcement-capability.test.sh: OK"; exit 0; }
echo "enforcement-capability.test.sh: $fail failure(s)" >&2; exit 1
