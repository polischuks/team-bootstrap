#!/usr/bin/env bash
# check-disposition.sh — verify-batch gate B (milestone closed-loop-fidelity, batch B1): a fired review
# finding of severity ≥ MEDIUM cannot be SELF-dispositioned to non-blocking. Closes retro F4 — the
# architecture-review MEDIUM that the shipping actor quietly downgraded to a comment.
#
# A finding recorded in the marker as `review_findings:[{id,severity,disposition}]` with severity ∈
# {MEDIUM,HIGH,CRITICAL} and disposition ∈ {downgraded,suppressed,wont_fix,moot} is UNRESOLVED unless a
# matching `disposition_waivers` entry governs it (GitLab MR-approval / SAST-waiver model):
#   {finding, approver, category ∈ {false_positive,accepted_risk,wont_fix}, reason, commit, expires}
#   - approver present AND ≠ the batch builder identity (`builder` marker field, default "orchestrator";
#     OQ-4 — a dispatched independent reviewer, not the inline actor being policed);
#   - category valid, reason present;
#   - expires is YYYY-MM-DD and ≥ now (TEAM_BOOTSTRAP_NOW, default system date) — no perpetual waiver;
#   - commit resolves and is the batch's CURRENT newest commit (HEAD) — a later commit VOIDS the waiver
#     (re-open on change; the GitLab remove_approvals_with_new_commit analogue, AC-5).
# Any failing condition ⇒ the finding is unresolved ⇒ fail-closed. No qualifying finding ⇒ pass.
#
# Marker parse is jq-free, field-order tolerant per object (like check-seam-ack). Graceful skips (exit 0):
# no active marker / not intends_code / no review_findings / no MEDIUM+ downgraded finding.
#
# Usage: bin/check-disposition.sh [project-dir]  ·  bin/check-disposition.sh --self-test
# Exit:  0 governed / skip · 1 an ungoverned MEDIUM+ disposition · 64 bad usage
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/delivery-lib.sh
. "$here/delivery-lib.sh"

# _array_objects MK KEY → one flat {...} object per line for the JSON array at "KEY":[...].
_array_objects() {
  local mk="$1" key="$2" arr
  arr="$(printf '%s' "$mk" | grep -oE "\"$key\":[[:space:]]*\[[^]]*\]" | head -1)"
  [ -n "$arr" ] || return 0
  printf '%s' "$arr" | grep -oE '\{[^}]*\}'
}
# _waiver_for MK FINDING_ID → the disposition_waivers object whose "finding" == FINDING_ID (rc 1 if none).
_waiver_for() {
  local mk="$1" fid="$2" obj
  while IFS= read -r obj; do
    [ -n "$obj" ] || continue
    [ "$(field_str "$obj" finding)" = "$fid" ] && { printf '%s' "$obj"; return 0; }
  done <<EOF
$(_array_objects "$mk" disposition_waivers)
EOF
  return 1
}
_qual_sev()  { case "$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')" in MEDIUM|HIGH|CRITICAL) return 0 ;; esac; return 1; }
_qual_disp() { case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in downgraded|suppressed|wont_fix|moot) return 0 ;; esac; return 1; }

_evaluate() {
  local marker mk builder now head_full findings
  marker="$(resolve_marker)"
  [ -n "$marker" ] && [ -f "$marker" ] || { echo "check-disposition: no active delivery run — skipping."; return 0; }
  mk="$(cat "$marker" 2>/dev/null || true)"
  [ "$(field_bool "$mk" intends_code)" = "true" ] || { echo "check-disposition: marker not intends_code — skipping."; return 0; }

  findings="$(_array_objects "$mk" review_findings)"
  [ -n "$findings" ] || { echo "check-disposition: no review_findings recorded — nothing to govern."; return 0; }

  builder="$(field_str "$mk" builder)"; [ -n "$builder" ] || builder="orchestrator"
  now="${TEAM_BOOTSTRAP_NOW:-$(date +%Y-%m-%d)}"
  head_full="$(git rev-parse HEAD 2>/dev/null || true)"

  local fobj fid sev disp w wapprover wcat wreason wcommit wexp wc_full viol=0 qualifying=0
  while IFS= read -r fobj; do
    [ -n "$fobj" ] || continue
    fid="$(field_str "$fobj" id)"; sev="$(field_str "$fobj" severity)"; disp="$(field_str "$fobj" disposition)"
    _qual_sev "$sev" || continue
    _qual_disp "$disp" || continue
    qualifying=$((qualifying + 1))

    if ! w="$(_waiver_for "$mk" "$fid")"; then
      echo "  FAIL: finding $fid (severity=$sev, disposition=$disp) has NO disposition_waiver — a fired MEDIUM+ finding cannot be self-dropped (F4)." >&2; viol=$((viol + 1)); continue
    fi
    wapprover="$(field_str "$w" approver)"; wcat="$(field_str "$w" category)"; wreason="$(field_str "$w" reason)"
    wcommit="$(field_str "$w" commit)"; wexp="$(field_str "$w" expires)"

    if [ -z "$wapprover" ] || [ "$wapprover" = "$builder" ]; then
      echo "  FAIL: finding $fid waiver approver='$wapprover' empty or == builder '$builder' — self-approval rejected; the approver must be an independent reviewer (OQ-4)." >&2; viol=$((viol + 1)); continue
    fi
    case "$wcat" in false_positive|accepted_risk|wont_fix) : ;; *)
      echo "  FAIL: finding $fid waiver category='$wcat' invalid (false_positive|accepted_risk|wont_fix)." >&2; viol=$((viol + 1)); continue ;; esac
    [ -n "$wreason" ] || { echo "  FAIL: finding $fid waiver missing reason (file:line + why)." >&2; viol=$((viol + 1)); continue; }
    case "$wexp" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) : ;; *)
      echo "  FAIL: finding $fid waiver expires='$wexp' is not YYYY-MM-DD." >&2; viol=$((viol + 1)); continue ;; esac
    if [[ "$wexp" < "$now" ]]; then
      echo "  FAIL: finding $fid waiver EXPIRED ($wexp < $now) — re-acknowledge (ADR-000Y)." >&2; viol=$((viol + 1)); continue
    fi
    wc_full="$(resolve_sha "$wcommit" 2>/dev/null || true)"
    if [ -z "$wc_full" ]; then
      echo "  FAIL: finding $fid waiver commit '$wcommit' does not resolve." >&2; viol=$((viol + 1)); continue
    fi
    if [ -n "$head_full" ] && [ "$wc_full" != "$head_full" ]; then
      if git merge-base --is-ancestor "$wc_full" "$head_full" 2>/dev/null; then
        echo "  FAIL: finding $fid waiver commit $wcommit predates the batch's newest commit (HEAD) — a later commit voided it; re-acknowledge on the current commit (AC-5)." >&2
      else
        echo "  FAIL: finding $fid waiver commit $wcommit is not reachable from HEAD." >&2
      fi
      viol=$((viol + 1)); continue
    fi
    echo "check-disposition: finding $fid governed — approver=$wapprover (≠builder), category=$wcat, expires=$wexp, commit=$wcommit."
  done <<EOF
$findings
EOF

  if [ "$qualifying" -eq 0 ]; then echo "check-disposition: no MEDIUM+ downgraded/suppressed findings — nothing to govern."; return 0; fi
  if [ "$viol" -gt 0 ]; then echo "  FAIL-CLOSED: $viol MEDIUM+ finding(s) dispositioned without a valid independent waiver — unresolved (F4)." >&2; return 1; fi
  echo "check-disposition: all MEDIUM+ dispositioned findings carry a valid, independent, unexpired, current waiver. OK."
  return 0
}

# --- self-test ---------------------------------------------------------------
if [ "${1:-}" = "--self-test" ]; then
  fail=0; T="$(mktemp -d)"; mkdir -p "$T/.runs/r"
  ( cd "$T" && git init -q && git config user.email t@t && git config user.name t
    echo a > f.txt && git add . && git commit -qm c0
    echo b >> f.txt && git add . && git commit -qm c1 ) >/dev/null 2>&1
  C0="$(cd "$T" && git rev-parse --short HEAD~1)"; C1="$(cd "$T" && git rev-parse --short HEAD)"
  _marker() { printf '%s\n' "$1" > "$T/.runs/r/RUN"; }
  printf '{"id":"B1","kind":"code","status":"announced"}\n' > "$T/.runs/r/batches.jsonl"
  _run() { ( cd "$T" && TEAM_BOOTSTRAP_RUN=r TEAM_BOOTSTRAP_NOW=2026-08-18 "$here/check-disposition.sh" . >/dev/null 2>&1 ); echo $?; }
  _chk() { if [ "$2" = "$3" ]; then echo "  PASS (exit $2) $1"; else echo "  FAIL (exit $2 want $3) $1" >&2; fail=$((fail + 1)); fi; }

  F='"review_findings":[{"id":"F1","severity":"MEDIUM","disposition":"downgraded"}]'
  # valid independent waiver on the current commit (C1=HEAD)
  WOK='"disposition_waivers":[{"finding":"F1","approver":"code-reviewer","category":"accepted_risk","reason":"bin/x.sh:10 bounded by caller","commit":"'"$C1"'","expires":"2999-01-01"}]'

  # AC-4 — MEDIUM downgraded, NO waiver → fail
  _marker '{"run":"r","intends_code":true,"builder":"orchestrator",'"$F"'}'
  _chk "AC-4 MEDIUM downgraded + no waiver → fail" "$(_run)" 1
  # AC-4 — waiver approver == builder (self-approval) → fail
  _marker '{"run":"r","intends_code":true,"builder":"orchestrator",'"$F"',"disposition_waivers":[{"finding":"F1","approver":"orchestrator","category":"accepted_risk","reason":"x","commit":"'"$C1"'","expires":"2999-01-01"}]}'
  _chk "AC-4 self-approved waiver (approver==builder) → fail" "$(_run)" 1
  # AC-4 — valid independent waiver on current commit → pass
  _marker '{"run":"r","intends_code":true,"builder":"orchestrator",'"$F"','"$WOK"'}'
  _chk "AC-4 independent valid waiver (current commit) → pass" "$(_run)" 0
  # AC-4 — invalid category → fail
  _marker '{"run":"r","intends_code":true,"builder":"orchestrator",'"$F"',"disposition_waivers":[{"finding":"F1","approver":"code-reviewer","category":"because","reason":"x","commit":"'"$C1"'","expires":"2999-01-01"}]}'
  _chk "AC-4 invalid category → fail" "$(_run)" 1
  # AC-4 — expired waiver → fail
  _marker '{"run":"r","intends_code":true,"builder":"orchestrator",'"$F"',"disposition_waivers":[{"finding":"F1","approver":"code-reviewer","category":"accepted_risk","reason":"x","commit":"'"$C1"'","expires":"2000-01-01"}]}'
  _chk "AC-4 expired waiver → fail" "$(_run)" 1
  # AC-5 — waiver commit predates newest (C0, an ancestor of HEAD) → voided → fail
  _marker '{"run":"r","intends_code":true,"builder":"orchestrator",'"$F"',"disposition_waivers":[{"finding":"F1","approver":"code-reviewer","category":"accepted_risk","reason":"x","commit":"'"$C0"'","expires":"2999-01-01"}]}'
  _chk "AC-5 waiver commit predates HEAD → voided → fail" "$(_run)" 1
  # AC-5 — waiver commit unresolvable → fail
  _marker '{"run":"r","intends_code":true,"builder":"orchestrator",'"$F"',"disposition_waivers":[{"finding":"F1","approver":"code-reviewer","category":"accepted_risk","reason":"x","commit":"deadbeef","expires":"2999-01-01"}]}'
  _chk "AC-5 waiver commit unresolvable → fail" "$(_run)" 1

  # skip: LOW severity finding (not qualifying) → pass
  _marker '{"run":"r","intends_code":true,"builder":"orchestrator","review_findings":[{"id":"F1","severity":"LOW","disposition":"downgraded"}]}'
  _chk "skip: LOW finding → pass" "$(_run)" 0
  # skip: MEDIUM but disposition 'promoted' (kept) → not qualifying → pass
  _marker '{"run":"r","intends_code":true,"builder":"orchestrator","review_findings":[{"id":"F1","severity":"MEDIUM","disposition":"promoted"}]}'
  _chk "skip: MEDIUM promoted (kept) → pass" "$(_run)" 0
  # skip: no review_findings → pass
  _marker '{"run":"r","intends_code":true,"builder":"orchestrator"}'
  _chk "skip: no review_findings → pass" "$(_run)" 0
  # AC-8 — no active marker → skip
  rm -f "$T/.runs/r/RUN"
  _chk "AC-8 no active marker → skip" "$(_run)" 0

  rm -rf "$T"
  if [ "$fail" -eq 0 ]; then echo "check-disposition --self-test: OK"; exit 0; fi
  echo "check-disposition --self-test: $fail case(s) FAILED" >&2; exit 1
fi

root="${1:-.}"
cd "$root" 2>/dev/null || { echo "check-disposition: bad dir '$root'" >&2; exit 64; }
if _evaluate; then exit 0; else exit 1; fi
