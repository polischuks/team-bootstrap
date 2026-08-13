#!/usr/bin/env bash
# check-mutation.sh — F3 verify-batch gate: mutation testing on the batch's changed code, the only
# automated judge of ASSERTION STRENGTH ("do the tests actually check anything", not just run). High
# cost, so OPT-IN / ADVISORY BY DEFAULT — it enforces only when the project declares MutationMode:
# enforce. Marker-gated ⇒ in-session, like check-tdd/check-diff-coverage.
#
# Contract (AGENTS.md / CLAUDE.md):
#   - `Mutation:` — a command that runs the project's mutation tool SCOPED TO CHANGED FILES and emits
#     a normalized final line the gate parses: `mutation_score: <float>` (0–100), OR `killed:<k>` and
#     `total:<t>` (score = 100*k/t). Adapters (Stryker/mutmut/PIT/cargo-mutants) are documented, not
#     parsed natively — one contract, no per-tool parsers.
#   - `MutationMode:` — `enforce` (hard gate) or `advisory` (report only). Default: advisory.
#   - `MutationThreshold:` — minimum score to pass under enforce (default 60).
#
# Graceful skips (exit 0): no active marker; no `Mutation:` command (skip+WARN); MutationMode advisory
# or absent (runs if present, reports, never blocks); score unparseable (WARN); no mutable changed code
# (`total:0` → pass-with-note — never a divide-by-zero false block).
#
# Usage: bin/check-mutation.sh [project-dir]  ·  bin/check-mutation.sh --self-test
# Exit:  0 pass / skip / advisory · 1 enforce + score below threshold · 64 bad usage
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/delivery-lib.sh
. "$here/delivery-lib.sh"

DEFAULT_MUTATION_THRESHOLD=60

_doc() { local f; for f in AGENTS.md CLAUDE.md; do [ -f "$f" ] && { printf '%s' "$f"; return 0; }; done; }
_cmd() { grep -iE "^[[:space:]]*[-*]?[[:space:]]*$1:" "$2" 2>/dev/null | head -1 | grep -oE '`[^`]+`' | head -1 | tr -d '`'; }
_val() { grep -iE "^[[:space:]]*[-*]?[[:space:]]*$1:" "$2" 2>/dev/null | head -1 | sed -E 's/^[^:]*://' | tr -d '`' | xargs 2>/dev/null || true; }

_evaluate() {
  local marker mk doc mut mode thr out score kk tt
  marker="$(resolve_marker)"
  [ -n "$marker" ] && [ -f "$marker" ] || { echo "check-mutation: no active delivery run — skipping (F3 governs armed runs)."; return 0; }
  mk="$(cat "$marker" 2>/dev/null || true)"
  [ "$(field_bool "$mk" intends_code)" = "true" ] || { echo "check-mutation: marker not intends_code — skipping."; return 0; }

  doc="$(_doc)"
  mut=""; [ -n "$doc" ] && mut="$(_cmd Mutation "$doc")"
  case "$mut" in ''|N/A|n/a|None|none)
    echo "check-mutation: WARN — no runnable Mutation: command in AGENTS.md; mutation testing not run (opt-in; declare Mutation: + MutationMode: enforce to enforce assertion strength)." >&2
    return 0 ;;
  esac
  mode="$(_val MutationMode "$doc")"; mode="$(printf '%s' "$mode" | tr '[:upper:]' '[:lower:]')"
  [ -n "$mode" ] || mode="advisory"
  thr="$(_val MutationThreshold "$doc")"; case "$thr" in ''|*[!0-9]*) thr="$DEFAULT_MUTATION_THRESHOLD" ;; esac

  out="$(eval "$mut" 2>&1 || true)"

  # score: prefer an explicit mutation_score: line (last one); else killed:/total: (last of each).
  score="$(printf '%s\n' "$out" | grep -oiE 'mutation_score:[[:space:]]*[0-9]+(\.[0-9]+)?' | tail -1 | grep -oE '[0-9]+(\.[0-9]+)?' | tail -1)"
  if [ -z "$score" ]; then
    kk="$(printf '%s\n' "$out" | grep -oiE 'killed:[[:space:]]*[0-9]+' | tail -1 | grep -oE '[0-9]+' | tail -1)"
    tt="$(printf '%s\n' "$out" | grep -oiE 'total:[[:space:]]*[0-9]+' | tail -1 | grep -oE '[0-9]+' | tail -1)"
    if [ -n "$tt" ]; then
      if [ "$tt" -eq 0 ]; then
        echo "check-mutation: no mutable changed code (total:0) — nothing to score, pass."
        return 0
      fi
      [ -n "$kk" ] || kk=0
      score="$(awk -v k="$kk" -v t="$tt" 'BEGIN{printf "%.2f", 100*k/t}')"
    fi
  fi

  if [ -z "$score" ]; then
    echo "check-mutation: WARN — could not parse a mutation score (expected 'mutation_score: <n>' or 'killed:/total:'); reported nothing to enforce." >&2
    return 0
  fi

  if [ "$mode" != "enforce" ]; then
    echo "check-mutation: mutation score ${score} (advisory — MutationMode:${mode}, not blocking; set MutationMode: enforce to gate)."
    return 0
  fi

  if awk -v s="$score" -v t="$thr" 'BEGIN{exit !(s+0 < t+0)}'; then
    echo "  FAIL: mutation score ${score} < threshold ${thr} (MutationMode:enforce) — strengthen assertions so tests kill the surviving mutants (F3)." >&2
    return 1
  fi
  echo "check-mutation: mutation score ${score} ≥ ${thr} (enforce) — OK."
  return 0
}

# --- self-test ---------------------------------------------------------------
if [ "${1:-}" = "--self-test" ]; then
  fail=0; T="$(mktemp -d)"
  ( cd "$T" && git init -q && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m base ) >/dev/null 2>&1
  mkdir -p "$T/.runs/r"
  printf '{"run":"r","intends_code":true,"source":"harness","baseline_sha":"x"}\n' > "$T/.runs/r/RUN"
  _agents() { printf '# AGENTS\n\n- Mutation: `cat mut.txt`\n- MutationMode: %s\n- MutationThreshold: %s\n' "$1" "$2" > "$T/AGENTS.md"; }
  _run() { ( cd "$T" && TEAM_BOOTSTRAP_RUN=r "$here/check-mutation.sh" . >/dev/null 2>&1 ); echo $?; }
  _chk() { if [ "$2" = "$3" ]; then echo "  PASS (exit $2) $1"; else echo "  FAIL (exit $2 want $3) $1" >&2; fail=$((fail + 1)); fi; }

  # enforce + score below threshold → fail
  _agents enforce 60; printf 'mutation_score: 40\n' > "$T/mut.txt"
  _chk "enforce, score 40 < 60 → fail" "$(_run)" 1
  # enforce + score at/above → pass
  printf 'mutation_score: 80\n' > "$T/mut.txt"
  _chk "enforce, score 80 ≥ 60 → pass" "$(_run)" 0
  # enforce via killed/total below → fail
  printf 'killed:1 total:5\n' > "$T/mut.txt"
  _chk "enforce, killed 1/total 5 = 20% < 60 → fail" "$(_run)" 1
  # enforce, total:0 (no mutable code) → pass, no crash
  printf 'killed:0 total:0\n' > "$T/mut.txt"
  _chk "enforce, total:0 → pass (no divide-by-zero)" "$(_run)" 0
  # advisory + low score → report, pass
  _agents advisory 60; printf 'mutation_score: 10\n' > "$T/mut.txt"
  _chk "advisory, score 10 → report, pass" "$(_run)" 0
  # enforce + unparseable score → WARN, pass
  _agents enforce 60; printf 'no score emitted\n' > "$T/mut.txt"
  _chk "enforce, unparseable → WARN, pass" "$(_run)" 0
  # no Mutation: command → skip+WARN
  ( cd "$T" && printf '# AGENTS\n\n- Lint: `true`\n' > AGENTS.md )
  _chk "no Mutation: command → skip (exit 0)" "$(_run)" 0
  # marker-less → skip
  ( cd "$T" && printf '# AGENTS\n\n- Mutation: `cat mut.txt`\n- MutationMode: enforce\n' > AGENTS.md; rm -f .runs/r/RUN )
  _chk "no active marker → skip (exit 0)" "$(_run)" 0
  rm -rf "$T"
  if [ "$fail" -eq 0 ]; then echo "check-mutation --self-test: OK"; exit 0; fi
  echo "check-mutation --self-test: $fail case(s) FAILED" >&2; exit 1
fi

root="${1:-.}"
cd "$root" 2>/dev/null || { echo "check-mutation: bad dir '$root'" >&2; exit 64; }
if _evaluate; then exit 0; else exit 1; fi
