#!/usr/bin/env bash
# check-delivery.sh — the delivery-occurred gate (fail-closed on unearned/FORGED closure).
#
# The other gates (quality-gate, orphans, architecture, gate-integrity) verify the
# delivered CODE is clean. NONE verifies that delivery actually HAPPENED, or that a
# "closed" line is BACKED BY REAL COMMITS. v2.11.0 moved closure from English prose to
# a JSON line — but the line was trusted: a hand-written
#   {"id":"B1","kind":"code","status":"closed","commit_shas":["deadbeef"],"code_delta":137}
# passed with exit 0 (a SHA git rejects, a number nobody checked). This gate closes that:
# closure is now a function of REPOSITORY STATE GIT CAN PROVE, not a self-declared field.
#
# Per closed kind:code entry:
#   - every commit_sha must resolve to a real commit          (AC-1; forged SHA -> fail)
#   - stamped code_delta must NOT exceed the git-RECOMPUTED    (AC-2; inflation -> fail)
#     non-doc delta over those commits (recompute uses the SAME shared function
#     verify-batch.sh stamps with — delivery-lib.sh nondoc_delta_of_shas — so an honest
#     stamp always passes; only an inflated one fails). "exceeds", not "differs":
#     honest history can recompute slightly ABOVE its range-diff stamp (see --self-test AC-3).
#   - code_delta > 0                                           (a code batch that changed no code)
# Announced-but-abandoned kind:code (a later batch exists, this never closed) -> fail.
# first-batch-must-be-code: a run delivering code must open with code, not docs.
# kind:doc entries earn no delivery credit and are never required to close.
#
# Ledger + SHA resolution + the non-doc delta come from bin/delivery-lib.sh (one
# definition, shared with verify-batch.sh — spec R1).
#
# Usage: bin/check-delivery.sh [project-dir]   # default: current dir
#        bin/check-delivery.sh --self-test     # AC-1/AC-2/AC-3 fixtures
# Exit:  0 clean / no ledger (not machine-checkable) · 1 unearned/forged closure · 64 bad usage
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/delivery-lib.sh
. "$here/delivery-lib.sh"

# --- self-test ---------------------------------------------------------------
if [ "${1:-}" = "--self-test" ]; then
  st_root="$(pwd)"; fail=0
  # dynamic, resolvable SHAs from the CURRENT repo — decoupled from history so the self-test survives
  # a history rewrite / shallow clone (previously hardcoded real SHAs, which a filter-repo purge invalidated).
  # Anchor the delta-BEARING fixtures to the most recent NON-DOC commit reachable from HEAD, NOT raw HEAD:
  # a doc-final batch (docs/agents-only) makes HEAD's recomputed non-doc delta 0, which would read the
  # code_delta:1 fixtures below as FORGED (the doc-final-delivery self-test break). Non-doc boundary mirrors
  # _is_doc_path (delivery-lib.sh). Falls back to HEAD when no non-doc commit exists.
  _nondoc_rev() { git rev-list -1 "$1" -- . ':(exclude)*.md' ':(exclude)*.mdx' ':(exclude)*.txt' ':(exclude)docs' ':(exclude)references' ':(exclude)LICENSE' ':(exclude)CHANGELOG*' 2>/dev/null; }
  _c="$(_nondoc_rev HEAD)"
  if [ -n "$_c" ]; then _c="$(git rev-parse --short "$_c" 2>/dev/null)"; else _c="$(git rev-parse --short HEAD 2>/dev/null)"; fi
  _c1="$(_nondoc_rev "${_c}~1")"
  if [ -n "$_c1" ]; then _c1="$(git rev-parse --short "$_c1" 2>/dev/null)"; else _c1="$(git rev-parse --short HEAD~1 2>/dev/null)"; fi
  _root="$(git rev-parse --short "$(git rev-list --max-parents=0 HEAD 2>/dev/null | tail -1)" 2>/dev/null)"
  # AC-2 needs a commit whose non-doc delta is provably BELOW the inflated stamp (137). Reusing $_c
  # (=HEAD) is fragile: when HEAD is a large code commit the recompute exceeds 137 and the inflation
  # is (correctly) NOT flagged, flipping AC-2 red for reasons unrelated to the gate (the
  # exec-role-integrity batch surfaced exactly this). Synthesize a DOC-ONLY dangling commit instead
  # (parent HEAD, tree = HEAD's tree + one .md file), so its recomputed non-doc delta is 0 regardless
  # of HEAD — decoupled the same way the historical-SHA coupling was (baseline 49a8b89).
  _docblob="$(printf 'doc fixture\n' | git hash-object -w --stdin 2>/dev/null || true)"
  _doctree=""; [ -n "$_docblob" ] && _doctree="$( { git ls-tree HEAD 2>/dev/null; printf '100644 blob %s\t__ac2_docfix.md\n' "$_docblob"; } | git mktree 2>/dev/null || true)"
  _docfix=""; [ -n "$_doctree" ] && _docfix="$(git commit-tree "$_doctree" -p HEAD -m 'doc-only fixture (AC-2)' 2>/dev/null || true)"
  [ -n "$_docfix" ] || _docfix="$_c"   # fallback: old behavior if object plumbing is unavailable
  _expect() { # runname expected_exit desc
    local rn="$1" exp="$2" desc="$3" got
    TEAM_BOOTSTRAP_RUN="$rn" "$0" "$st_root" >/dev/null 2>&1; got=$?
    if [ "$got" -eq "$exp" ]; then echo "  PASS (exit $got) $desc"
    else echo "  FAIL (exit $got, want $exp) $desc" >&2; fail=$((fail + 1)); fi
  }
  _dirs="_st_ac1 _st_ac2 _st_ac4a _st_ac4b _st_ac5 _st_f2i _st_f2ii _st_ac7 _st_ac9 _st_ws"
  for d in $_dirs; do mkdir -p ".runs/$d"; done
  # F-A recompute (no marker → binding off) -----------------------------------
  printf '%s\n' '{"id":"F1","kind":"code","status":"closed","commit_shas":["deadbeef"],"code_delta":137}' > .runs/_st_ac1/batches.jsonl
  _expect _st_ac1 1 "AC-1 — forged deadbeef SHA rejected"
  printf '%s\n' '{"id":"F2","kind":"code","status":"closed","commit_shas":["'"$_docfix"'"],"code_delta":137}' > .runs/_st_ac2/batches.jsonl
  _expect _st_ac2 1 "AC-2 — inflated code_delta over a doc-only commit rejected"
  if [ -f ".runs/deliver-delivery-guard/batches.jsonl" ]; then
    _expect deliver-delivery-guard 0 "AC-3 — historical honest ledger (B1-B5) still passes"
  else
    echo "  SKIP  AC-3 — historical ledger absent (gate-integrity: sanctioned — fixture not present in this checkout)"
  fi
  # F-B fail-closed under an active marker -------------------------------------
  printf '%s\n' '{"run":"_st_ac4a","intends_code":true,"source":"harness"}' > .runs/_st_ac4a/RUN
  _expect _st_ac4a 1 "AC-4 — active run (intends_code) + no ledger → fail-closed"
  # whitespace-tolerant marker parse: a SPACED marker (json.dumps' `": "`) must still read
  # intends_code:true → fail-closed. Before the delivery-lib fix it parsed EMPTY and silently skipped.
  printf '%s\n' '{"run": "_st_ws", "intends_code": true, "source": "harness"}' > .runs/_st_ws/RUN
  _expect _st_ws 1 "WS — spaced marker still parses intends_code → fail-closed (not silently skipped)"
  printf '%s\n' '{"run":"_st_ac4b","intends_code":true,"source":"harness"}' > .runs/_st_ac4b/RUN
  printf '%s\n' '{"id":"D1","kind":"doc","status":"closed"}' > .runs/_st_ac4b/batches.jsonl
  _expect _st_ac4b 1 "AC-4 — active run + only kind:doc closures → fail-closed"
  # AC-5 — no marker + no ledger → skip (isolated run dir, empty) --------------
  _expect _st_ac5 0 "AC-5 — no marker + no ledger → exit 0 (not a delivery run)"
  # F-2 commit-to-batch binding (active marker) -------------------------------
  printf '%s\n' '{"run":"_st_f2i","intends_code":true,"source":"harness"}' > .runs/_st_f2i/RUN
  printf '%s\n%s\n' \
    '{"id":"C1","kind":"code","status":"closed","commit_shas":["'"$_c"'"],"code_delta":5}' \
    '{"id":"C2","kind":"code","status":"closed","commit_shas":["'"$_c"'"],"code_delta":5}' > .runs/_st_f2i/batches.jsonl
  _expect _st_f2i 1 "F-2 — a commit reused across two closed batches → rejected"
  printf '%s\n' '{"run":"_st_f2ii","intends_code":true,"source":"harness","baseline_sha":"'"$_c"'"}' > .runs/_st_f2ii/RUN
  printf '%s\n' '{"id":"C1","kind":"code","status":"closed","commit_shas":["'"$_root"'"],"code_delta":5}' > .runs/_st_f2ii/batches.jsonl
  _expect _st_f2ii 1 "F-2 — a commit predating the run baseline → rejected"
  # F-D recorded-ack + F-E risk_rank ordering -----------------------------------
  printf '%s\n' '{"run":"_st_ac7","intends_code":true,"source":"harness","precond":{"exit":2,"items":[],"ack":false}}' > .runs/_st_ac7/RUN
  printf '%s\n' '{"id":"B1","kind":"code","status":"announced"}' > .runs/_st_ac7/batches.jsonl
  _expect _st_ac7 1 "AC-7 — unacknowledged Phase-A advisory + announced batch → blocked"
  printf '%s\n' '{"run":"_st_ac9","intends_code":true,"source":"harness"}' > .runs/_st_ac9/RUN
  printf '%s\n%s\n' \
    '{"id":"C1","kind":"code","status":"closed","commit_shas":["'"$_c"'"],"code_delta":5,"risk_rank":"feature"}' \
    '{"id":"C2","kind":"code","status":"closed","commit_shas":["'"$_c1"'"],"code_delta":5,"risk_rank":"irreversible"}' > .runs/_st_ac9/batches.jsonl
  _expect _st_ac9 1 "AC-9 — a higher-rank code batch closing after a lower-rank one → rejected"
  # R-2 — a resolvable but UNREACHABLE-from-HEAD commit (dangling / sibling) must not close
  dangling="$(git commit-tree "HEAD^{tree}" -m "dangling probe" 2>/dev/null || true)"
  if [ -n "$dangling" ]; then
    mkdir -p .runs/_st_r2
    printf '%s\n' '{"run":"_st_r2","intends_code":true,"source":"harness","baseline_sha":"'"$_c"'"}' > .runs/_st_r2/RUN
    printf '%s\n' "{\"id\":\"C1\",\"kind\":\"code\",\"status\":\"closed\",\"commit_shas\":[\"$dangling\"],\"code_delta\":1}" > .runs/_st_r2/batches.jsonl
    _expect _st_r2 1 "R-2 — commit unreachable from HEAD rejected (sibling/discarded)"
    rm -rf .runs/_st_r2
  else
    echo "  SKIP  R-2 — could not create a dangling commit (gate-integrity: sanctioned — git commit-tree unavailable)"
  fi
  # R-1 — a marker-less run must report WEAK (marker=absent), not "git-verified"
  mkdir -p .runs/_st_r1
  printf '%s\n' '{"id":"C1","kind":"code","status":"closed","commit_shas":["'"$_c"'"],"code_delta":1}' > .runs/_st_r1/batches.jsonl
  case "$(TEAM_BOOTSTRAP_RUN=_st_r1 "$0" "$st_root" 2>/dev/null || true)" in
    *"marker=absent"*) echo "  PASS (msg) R-1 — marker-less run reports WEAK [marker=absent], not git-verified" ;;
    *) echo "  FAIL R-1 — marker-less success did not enumerate marker=absent" >&2; fail=$((fail + 1)) ;;
  esac
  rm -rf .runs/_st_r1
  # N-1 — active marker with NO baseline: must pass (reachable-from-HEAD) but the success
  # line must enumerate predate=OFF — never claim full F-2 when the predate anchor did not run.
  mkdir -p .runs/_st_n1
  printf '%s\n' '{"run":"_st_n1","intends_code":true,"source":"harness"}' > .runs/_st_n1/RUN
  printf '%s\n' '{"id":"C1","kind":"code","status":"closed","commit_shas":["'"$_c"'"],"code_delta":1,"risk_rank":"feature"}' > .runs/_st_n1/batches.jsonl
  case "$(TEAM_BOOTSTRAP_RUN=_st_n1 "$0" "$st_root" 2>/dev/null || true)" in
    *"predate=OFF"*) echo "  PASS (msg) N-1 — active-marker-no-baseline reports predate=OFF (not full F-2)" ;;
    *) echo "  FAIL N-1 — success line claimed more than was enforced" >&2; fail=$((fail + 1)) ;;
  esac
  rm -rf .runs/_st_n1
  # Direct-pipeline delivery: an armed run with NO ledger but real code committed since a
  # resolvable baseline is delivery (git-grounded), not fail-closed — this makes the guard fire
  # uniformly for `/team-bootstrap single-thread …`, which writes no batch ledger.
  mkdir -p .runs/_st_dr1
  printf '%s\n' '{"run":"_st_dr1","intends_code":true,"source":"harness","baseline_sha":"'"$_root"'"}' > .runs/_st_dr1/RUN
  _expect _st_dr1 0 "direct-run — armed, no ledger, code since baseline → delivered (exit 0)"
  rm -rf .runs/_st_dr1
  mkdir -p .runs/_st_dr2
  printf '%s\n' "{\"run\":\"_st_dr2\",\"intends_code\":true,\"source\":\"harness\",\"baseline_sha\":\"$(git rev-parse --short HEAD 2>/dev/null)\"}" > .runs/_st_dr2/RUN
  _expect _st_dr2 1 "direct-run — armed, no ledger, no code since baseline → fail-closed (exit 1)"
  rm -rf .runs/_st_dr2
  for d in $_dirs; do rm -rf ".runs/$d"; done
  if [ "$fail" -eq 0 ]; then echo "check-delivery --self-test: OK"; exit 0; fi
  echo "check-delivery --self-test: $fail case(s) FAILED" >&2; exit 1
fi

root="${1:-.}"
cd "$root" 2>/dev/null || { echo "check-delivery: bad dir '$root'" >&2; exit 64; }

# --- resolve the harness run marker (the machine fact "delivery active") ------
# Present + intends_code:true  => an ACTIVE delivery run; the gate becomes
# fail-closed (absent/empty delivery is a FAILURE, not a skip) and commit-to-batch
# binding (F-2) is enforced. Absent => not a governed delivery run; keep the exit-0
# skip so non-delivery / docs-only sessions are never nagged (AC-5).
marker="$(resolve_marker)"
intends=""; baseline=""; precond_exit=""; precond_ack=""
if [ -n "$marker" ] && [ -f "$marker" ]; then
  mk="$(cat "$marker" 2>/dev/null || true)"
  intends="$(field_bool "$mk" intends_code)"
  baseline="$(field_str "$mk" baseline_sha)"
  precond_exit="$(field_num "$mk" exit)"     # precond.exit (only "exit" key in the marker)
  precond_ack="$(field_bool "$mk" ack)"      # precond.ack  (only "ack" key in the marker)
  # R-3 + N-1: an active run whose baseline does not resolve — whether ABSENT or a bogus
  # value — has its predate check silently disarmed. Flag it loudly for BOTH cases (the
  # success line also enumerates predate=OFF; reachable-from-HEAD still holds regardless).
  if [ "$intends" = "true" ] && [ -z "$(resolve_sha "${baseline:-}")" ]; then
    echo "check-delivery: WARN — active run has no resolvable baseline_sha (predate protection F-2 iii OFF; reachable-from-HEAD still enforced)." >&2
  fi
fi

# direct-pipeline delivery signal — a run may deliver without the /deliver batch ledger
# (deliver.md recommends `/team-bootstrap single-thread` directly for small changes). Such a
# run writes no ledger but commits real code; code_since_baseline proves it, git-grounded.
csb=0
[ "$intends" = "true" ] && code_since_baseline "${baseline:-}" && csb=1

ledger="$(resolve_ledger)"
if [ -z "$ledger" ] || [ ! -f "$ledger" ]; then
  if [ "$intends" = "true" ]; then
    if [ "$csb" -eq 1 ]; then
      echo "check-delivery: no batch ledger, but real non-doc code was committed since baseline '${baseline}' — direct-pipeline delivery (git-verified), allowed."
      exit 0
    fi
    echo "  FAIL-CLOSED: active delivery run (intends_code:true) with NO batch ledger AND no code committed since baseline — no delivery occurred (AC-4)." >&2
    echo "check-delivery: fail-closed under an active run — no delivery." >&2
    exit 1
  fi
  echo "check-delivery: no batch ledger — delivery not machine-checkable, skipping."
  exit 0
fi

total="$(grep -c . "$ledger" 2>/dev/null || echo 0)"
n=0
viol=0
first_kind=""
any_code=0
closed_code=0      # count of earned kind:code closures (AC-4 second case)
inflight_code=0    # a kind:code batch legitimately in flight (bootstrap-safe)
seen_shas=""       # F-2: a commit_sha may be credited to at most one closed batch
prev_rank=""       # F-E: rank-int of the previously-closed kind:code batch (non-increasing)
while IFS= read -r line; do
  [ -n "$line" ] || continue
  n=$((n + 1))
  kind="$(field_str "$line" kind)"
  [ "$n" -eq 1 ] && first_kind="$kind"
  [ "$kind" = "code" ] || continue   # doc batches: no delivery credit
  any_code=1
  id="$(field_str "$line" id)"; [ -n "$id" ] || id="#$n"
  status="$(field_str "$line" status)"
  if [ "$status" = "closed" ]; then
    delta="$(field_num "$line" code_delta)"; case "$delta" in ''|*[!0-9-]*) delta=0 ;; esac
    shas="$(shas_of_line "$line")"
    # AC-1 — closure must be tied to commits git can prove.
    if [ -z "$shas" ]; then
      echo "  FORGED: batch '$id' closed kind:code with no commit_shas — closure tied to no commit." >&2
      viol=$((viol + 1)); continue
    fi
    missing=""
    for s in $shas; do
      [ -n "$s" ] || continue
      [ -z "$(resolve_sha "$s")" ] && missing="$missing $s"
    done
    if [ -n "$missing" ]; then
      echo "  FORGED: batch '$id' cites commit_sha(s) git cannot resolve:$missing — closure not backed by real commits (AC-1)." >&2
      viol=$((viol + 1)); continue
    fi
    # a code batch that changed no code is unearned (P0.3, preserved).
    if [ "$delta" -le 0 ]; then
      echo "  UNEARNED: batch '$id' closed with code_delta=$delta — a code batch that changed no code." >&2
      viol=$((viol + 1)); continue
    fi
    # AC-2 — stamped delta may not EXCEED the git-recomputed non-doc delta (inflation).
    recomputed="$(nondoc_delta_of_shas "$shas")"
    if [ "$delta" -gt "$recomputed" ]; then
      echo "  FORGED: batch '$id' stamped code_delta=$delta EXCEEDS git-recomputed non-doc delta=$recomputed over [${shas}] — inflated closure (AC-2)." >&2
      viol=$((viol + 1)); continue
    fi
    # F-2 commit-to-batch binding — enforced ONLY under an active harness marker.
    # Marker-less replay (the historical ledger, AC-3) skips this: that history
    # legitimately reuses e6bba5d across B1+B2 (a pre-P2 cumulative-range artifact).
    if [ -n "$marker" ]; then
      for s in $shas; do
        [ -n "$s" ] || continue
        sfull="$(resolve_sha "$s")"
        # (i) no commit may be credited to more than one closed batch
        case " $seen_shas " in
          *" $sfull "*)
            echo "  FORGED: batch '$id' reuses commit $s already credited to an earlier closed batch — one commit cannot earn N closures (F-2)." >&2
            viol=$((viol + 1)) ;;
        esac
        seen_shas="$seen_shas $sfull"
        # (ii) commits must be REACHABLE FROM HEAD — on this run's delivered history,
        # not a sibling/discarded/cherry-pick-source branch (R-2). This is the primary
        # "earned by THIS run's commits" guarantee; it holds even if baseline is unknown.
        if [ -n "$sfull" ] && ! git merge-base --is-ancestor "$sfull" HEAD 2>/dev/null; then
          echo "  FORGED: batch '$id' cites commit $s not reachable from HEAD — closure must be earned by commits on this run's delivered history, not a sibling or discarded branch (F-2/R-2)." >&2
          viol=$((viol + 1))
        fi
        # (iii) and must post-date the run baseline (secondary anchor)
        if [ -n "$baseline" ]; then
          bfull="$(resolve_sha "$baseline")"
          if [ -n "$bfull" ] && git merge-base --is-ancestor "$sfull" "$bfull" 2>/dev/null; then
            echo "  FORGED: batch '$id' cites commit $s that predates the run baseline ($baseline) — closure must be earned by this run's commits, not pre-existing history (F-2)." >&2
            viol=$((viol + 1))
          fi
        fi
      done
    fi
    # F-E risk_rank ordering: over closed kind:code batches THAT DECLARE risk_rank, the
    # rank-int must be non-increasing in close order — a higher-risk (bleeding-stopper)
    # batch must not close AFTER a lower-risk one. Entries without risk_rank are
    # unconstrained (so the historical ledger, which has none, still passes — AC-3).
    rr="$(field_str "$line" risk_rank)"
    if [ -n "$rr" ]; then
      ri="$(risk_rank_int "$rr")"
      if [ -n "$ri" ]; then
        if [ -n "$prev_rank" ] && [ "$ri" -gt "$prev_rank" ]; then
          echo "  ORDERING: batch '$id' risk_rank=$rr($ri) closed after a lower-rank batch($prev_rank) — a higher-risk batch must not close after a lower-risk one; order by load-bearing risk (AC-9)." >&2
          viol=$((viol + 1))
        fi
        prev_rank="$ri"
      fi
    fi
    closed_code=$((closed_code + 1))
  elif [ "$n" -eq "$total" ]; then
    inflight_code=1
    echo "check-delivery: batch '$id' in flight (status=$status) — not yet closed, allowed."
  else
    echo "  UNEARNED: batch '$id' is kind:code status='$status' — announced then abandoned (a later batch exists, this one never closed)." >&2
    viol=$((viol + 1))
  fi
done < "$ledger"

# first-batch-must-be-code: a run that delivers ANY code must open with code, not
# docs — the load-bearing code leads, documentation does not front-run it.
if [ "$any_code" -eq 1 ] && [ "$first_kind" = "doc" ]; then
  echo "  ORDERING: first batch is kind:doc while the run delivers code later — a delivery run must open with the load-bearing code, not documentation." >&2
  viol=$((viol + 1))
fi

# fail-closed, second case (AC-4): an active delivery run whose ledger carries NO
# earned code closure and nothing in flight — e.g. only kind:doc closures. A run that
# intends code but delivered none is a failure, not a pass. Bootstrap-safe: a single
# code batch legitimately in flight (inflight_code) is NOT penalised.
if [ "$intends" = "true" ] && [ "$closed_code" -eq 0 ] && [ "$inflight_code" -eq 0 ] && [ "$csb" -eq 0 ]; then
  echo "  FAIL-CLOSED: active delivery run (intends_code:true) with zero earned kind:code closures, nothing in flight, and no code committed since baseline — no delivery occurred (AC-4)." >&2
  viol=$((viol + 1))
fi

# F-D — a recorded, BLOCKING deliverability ack. If Phase A's precondition probe raised
# an advisory (precond.exit==2) and it was never acknowledged (precond.ack!=true), Phase B
# may not proceed: a ledger with any announced batch while the ack is pending fails. This
# makes "resolve publication at the Phase-A gate, not after the files" a machine fact, not
# prose (AC-7). Honesty of the ack is out of scope (parity with risk_rank) — see spec.
if [ "${precond_exit:-0}" = "2" ] && [ "${precond_ack:-false}" != "true" ] && [ "$total" -ge 1 ]; then
  echo "  BLOCKED: Phase-A deliverability advisory (precond.exit=2) is unacknowledged (precond.ack=false) but $total batch(es) already announced — record the ack in the run marker before Phase B (AC-7)." >&2
  viol=$((viol + 1))
fi

if [ "$viol" -gt 0 ]; then
  echo "check-delivery: $viol unearned/forged closure(s) in $ledger — closure is earned by real commits + a git-verified delta, not by assertion." >&2
  exit 1
fi
# Report truth by ENUMERATING which anchors actually fired — never claim more than ran.
# F-B (no ledger), R-1 (no marker) and N-1 (no baseline) are one class: a protection that
# silently disables on absent input while the summary still reads "verified". The cure is a
# single invariant — the success line lists each anchor's real state (marker / reuse /
# reachability / predate / fail-closed), so "GIT-VERIFIED" can never mean more than enforced.
if [ -n "$marker" ]; then
  if [ -n "$baseline" ] && [ -n "$(resolve_sha "$baseline")" ]; then predate="predate=ON"; else predate="predate=OFF(no-baseline)"; fi
  if [ "$intends" = "true" ]; then fc="fail-closed=ON"; else fc="fail-closed=OFF(intends!=true)"; fi
  echo "check-delivery: closures GIT-VERIFIED [marker=active reuse=ON reachability=ON $predate $fc] ($ledger)."
else
  echo "check-delivery: closures pass basic SHA-exists+delta only — WEAK [marker=absent: reuse/reachability/predate/fail-closed ALL OFF; not a governed delivery run] ($ledger)."
fi
exit 0
