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
#     parsed natively — one contract, no per-tool parsers. The gate EXPORTS `TB_MUTATION_BASE` and
#     `TB_MUTATION_TIP` (this batch's OWN window: prev-closed-tip..HEAD, #113) so the command can scope
#     to `git diff $TB_MUTATION_BASE..$TB_MUTATION_TIP` instead of the run baseline; ignoring them keeps
#     the pre-#113 behaviour (whole-run diff).
#   - `MutationMode:` — `enforce` (hard gate) or `advisory` (report only). Default: advisory.
#   - `MutationThreshold:` — minimum score to pass under enforce (default 60).
#
# Graceful skips (exit 0): no active marker; no `Mutation:` command (skip+WARN); MutationMode advisory
# or absent (runs if present, reports, never blocks); score unparseable (WARN); no mutable changed code
# (`total:0` → pass-with-note — never a divide-by-zero false block).
#
# GOVERNED WAIVER (issue #66). Under enforce, a batch whose diff-scoped mutation run is infeasible (a
# 3-line change dragging a 15k-line file into mutation) has a sanctioned escape matching the other enforce
# gates: `bin/check-mutation.sh --waive BY REASON EXPIRES(YYYY-MM-DD)` records a governed `mutation_waiver`
# in the active run marker, which _evaluate consults AFTER printing the finding. A bare/expired waiver is
# not a waiver (governed_waiver_ok). This does not silence the finding and it expires — see enforcement.md.
#
# Usage: bin/check-mutation.sh [project-dir]  ·  --self-test  ·  --waive BY REASON EXPIRES
# Exit:  0 pass / skip / advisory / waived · 1 enforce + score below threshold (unwaived) · 64 bad usage
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/delivery-lib.sh
. "$here/delivery-lib.sh"

DEFAULT_MUTATION_THRESHOLD=60

# `--waive BY REASON EXPIRES` records the governed `mutation_waiver` this gate reads — the same door the
# other enforce gates already carry (check-role-verdict → role_verdict_waiver, check-gate-integrity →
# gate_integrity_waiver). It exists because diff-scoped mutation on a large-file change (a 3-line refactor
# in a 15k-line file drags the whole file into mutation) can be infeasible with no sanctioned escape but
# reverting the good change (issue #66 comment). Validation is record_governed_waiver's, which is
# governed_waiver_ok's, which is this gate's below: ONE definition, so a waiver that records always works
# and one that would not is refused here with a reason, not later at the gate. Procedure: references/enforcement.md.
if [ "${1:-}" = "--waive" ]; then
  shift
  if [ "$#" -ne 3 ]; then
    echo "usage: $(basename "$0") --waive BY REASON EXPIRES(YYYY-MM-DD)" >&2
    echo "  records mutation_waiver in the active run marker. Expiry is mandatory and must be in the future." >&2
    exit 64
  fi
  record_governed_waiver mutation_waiver "$1" "$2" "$3" || {
    echo "$(basename "$0"): REFUSED to record mutation_waiver — needs a non-empty by and reason, and a future YYYY-MM-DD expires, under an unambiguous active run." >&2
    exit 1
  }
  exit 0
fi

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

  # #113 — SCOPE THE MUTATION WINDOW TO THIS BATCH'S OWN COMMITS. The gate delegates "scoped to changed
  # files" to the project's Mutation: command, which, left to itself, diffs against the run baseline —
  # so a late batch is scored over the ACCUMULATED diff of B1+B2+…+Bn, and a big legacy file touched in an
  # early batch keeps depressing every LATER batch's score. Export the per-batch window (the SAME window
  # check-diff-coverage / verify-batch's code_delta take from current_batch_base: prev-closed-tip..HEAD,
  # falling back to baseline for the first batch) so the Mutation: command can diff `TB_MUTATION_BASE..
  # TB_MUTATION_TIP` instead of baseline..HEAD. Adapters that ignore the vars behave exactly as before.
  local mbase mtip
  mbase="$(resolve_sha "$(current_batch_base 2>/dev/null || true)")" || mbase=""
  mtip="$(git rev-parse HEAD 2>/dev/null || true)"

  # Mutation runs the test suite ONCE PER MUTANT — by far the most expensive gate. verify-batch re-runs
  # every gate on every attempt, so a retry that changed nothing (the first attempt usually fails on some
  # OTHER gate) used to pay for Stryker again. Reuse this gate's own previous OUTPUT only when the key —
  # command string + committed window + uncommitted tracked changes — is identical; an empty key (no
  # marker, no repo, no baseline) means execute (issue #23 item 1). The cached payload is the RAW OUTPUT,
  # so the score parsing and threshold verdict below are re-derived every time and cannot drift.
  ck="$(gate_cache_key mutation "$mut")"
  if out="$(gate_cache_get "$ck")"; then
    echo "check-mutation: reusing the cached verdict — the diff and the Mutation: command are unchanged since the last run (issue #23; any code change re-executes)."
  else
    out="$(TB_MUTATION_BASE="$mbase" TB_MUTATION_TIP="$mtip" eval "$mut" 2>&1 || true)"
    gate_cache_put "$ck" "$out"
  fi

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
    # Print the finding BEFORE consulting the waiver — a governed escape that silences its own finding is
    # an invisible one (parity with check-role-verdict/check-gate-integrity). Then a valid governed
    # mutation_waiver (ack+by+reason+unexpired-YYYY-MM-DD) relieves the enforce fail; a bare/expired one
    # does not. Routed through the SAME governed_waiver_ok that backs the peer gates — one definition.
    echo "  FAIL: mutation score ${score} < threshold ${thr} (MutationMode:enforce) — strengthen assertions so tests kill the surviving mutants (F3)." >&2
    if governed_waiver_ok \
         "$(field_in_obj "$mk" mutation_waiver ack)" \
         "$(field_in_obj "$mk" mutation_waiver by)" \
         "$(field_in_obj "$mk" mutation_waiver reason)" \
         "$(field_in_obj "$mk" mutation_waiver expires)"; then
      echo "check-mutation: WAIVED by a governed mutation_waiver (finding surfaced above; by/reason/expires recorded, expiry forces re-review) — exit 0. See references/enforcement.md for the procedure." >&2
      return 0
    fi
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
  # --waive (issue #66): enforce + low score + a governed mutation_waiver → WAIVED → pass.
  _agents enforce 60; printf 'mutation_score: 40\n' > "$T/mut.txt"
  printf '{"run":"r","intends_code":true,"source":"harness","baseline_sha":"x","mutation_waiver":{"ack":true,"by":"x","reason":"r","expires":"2999-01-01"}}\n' > "$T/.runs/r/RUN"
  _chk "enforce, score 40 < 60, valid mutation_waiver → pass" "$(_run)" 0
  # expired mutation_waiver → not a waiver → fail
  printf '{"run":"r","intends_code":true,"source":"harness","baseline_sha":"x","mutation_waiver":{"ack":true,"by":"x","reason":"r","expires":"2000-01-01"}}\n' > "$T/.runs/r/RUN"
  _chk "enforce, score 40 < 60, EXPIRED mutation_waiver → fail" "$( ( cd "$T" && TEAM_BOOTSTRAP_RUN=r TEAM_BOOTSTRAP_NOW=2026-08-28 "$here/check-mutation.sh" . >/dev/null 2>&1 ); echo $? )" 1
  # `--waive` writer records the governed waiver, then the enforce run passes on it.
  printf '{"run":"r","intends_code":true,"source":"harness","baseline_sha":"x"}\n' > "$T/.runs/r/RUN"
  ( cd "$T" && TEAM_BOOTSTRAP_RUN=r "$here/check-mutation.sh" --waive x r 2999-01-01 >/dev/null 2>&1 )
  case "$(cat "$T/.runs/r/RUN")" in *'"mutation_waiver":{'*'"by":"x"'*) echo "  PASS --waive wrote mutation_waiver" ;;
    *) echo "  FAIL --waive did not write mutation_waiver: $(cat "$T/.runs/r/RUN")" >&2; fail=$((fail + 1)) ;; esac
  _chk "after --waive, enforce + low score → pass" "$(_run)" 0
  # `--waive` with a past expiry is REFUSED (exit 1), writes nothing.
  printf '{"run":"r","intends_code":true,"source":"harness","baseline_sha":"x"}\n' > "$T/.runs/r/RUN"
  _chk "--waive past expiry → refused (exit 1)" "$( ( cd "$T" && TEAM_BOOTSTRAP_RUN=r "$here/check-mutation.sh" --waive x r 2000-01-01 >/dev/null 2>&1 ); echo $? )" 1
  # restore the plain armed marker for the remaining cases
  printf '{"run":"r","intends_code":true,"source":"harness","baseline_sha":"x"}\n' > "$T/.runs/r/RUN"

  # no Mutation: command → skip+WARN
  ( cd "$T" && printf '# AGENTS\n\n- Lint: `true`\n' > AGENTS.md )
  _chk "no Mutation: command → skip (exit 0)" "$(_run)" 0
  # marker-less → skip
  ( cd "$T" && printf '# AGENTS\n\n- Mutation: `cat mut.txt`\n- MutationMode: enforce\n' > AGENTS.md; rm -f .runs/r/RUN )
  _chk "no active marker → skip (exit 0)" "$(_run)" 0
  rm -rf "$T"

  # #113 — the gate exports the batch's OWN window (prev-closed-tip..HEAD) so the Mutation: command can
  # scope to it instead of the run baseline. Build a repo with a CLOSED batch B1 (tip c1) and a later
  # HEAD; current_batch_base must be c1's tip, and TB_MUTATION_BASE must equal that, NOT the run baseline.
  W="$(mktemp -d)"
  ( cd "$W" && git init -q && git config user.email t@t && git config user.name t
    echo a > a.txt && git add . && git commit -qm c0
    echo b >> a.txt && git add . && git commit -qm "B1 code" ) >/dev/null 2>&1
  wbase="$( cd "$W" && git rev-parse --short HEAD~1 )"     # run baseline (c0)
  wtip1="$( cd "$W" && git rev-parse --short HEAD )"        # B1's tip (c1) — the last closure
  wtip1_full="$( cd "$W" && git rev-parse HEAD )"
  ( cd "$W" && echo c >> a.txt && git add . && git commit -qm "B2 code" ) >/dev/null 2>&1
  mkdir -p "$W/.runs/r"
  printf '{"run":"r","intends_code":true,"source":"harness","baseline_sha":"%s"}\n' "$wbase" > "$W/.runs/r/RUN"
  printf '%s\n' "{\"id\":\"B1\",\"kind\":\"code\",\"status\":\"closed\",\"commit_shas\":[\"$wtip1\"],\"code_delta\":1}" > "$W/.runs/r/batches.jsonl"
  # Mutation: command records the window base it was handed, then reports a passing score.
  printf '# AGENTS\n\n- Mutation: `echo "$TB_MUTATION_BASE" > mbase.txt; printf %%s\\n "mutation_score: 100"`\n- MutationMode: enforce\n' > "$W/AGENTS.md"
  ( cd "$W" && TEAM_BOOTSTRAP_RUN=r "$here/check-mutation.sh" . >/dev/null 2>&1 )
  got_base="$( cd "$W" && cat mbase.txt 2>/dev/null | tr -d '[:space:]' )"
  if [ "$got_base" = "$wtip1_full" ]; then
    echo "  PASS TB_MUTATION_BASE is B1's tip (the per-batch window), not the run baseline (#113)"
  else echo "  FAIL TB_MUTATION_BASE=$got_base (want B1 tip $wtip1_full, NOT baseline $wbase)" >&2; fail=$((fail + 1)); fi
  rm -rf "$W"

  if [ "$fail" -eq 0 ]; then echo "check-mutation --self-test: OK"; exit 0; fi
  echo "check-mutation --self-test: $fail case(s) FAILED" >&2; exit 1
fi

root="${1:-.}"
cd "$root" 2>/dev/null || { echo "check-mutation: bad dir '$root'" >&2; exit 64; }
if _evaluate; then exit 0; else exit 1; fi
