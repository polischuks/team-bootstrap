#!/usr/bin/env bash
# verdict-tally-durable.test.sh — issue #83: the #46 durable verdict tally must survive a marker rewrite.
#
# #46 mirrors each confirmed capture into `verdicts_captured` so that if verdicts.jsonl is wiped, the
# marker still proves what was captured (durability breach ≠ never-ran). But the tally lived ONLY as a
# RUN-marker field, and the marker is rewritten on many events. On live run 177 a rewrite between batches
# reconstructed the marker without the field: the tally held only the in-flight batch's entries while
# verdicts.jsonl kept all — the append-only contract broken across a batch boundary, silently.
#
# The exact dropping writer was not reproducible in a fixture, so the fix does not depend on identifying
# it: the durable tally now also lives in a marker-INDEPENDENT append-only sidecar
# (.runs/<run>/verdicts-captured.jsonl). No marker rewrite — known or unknown — can drop it, and it is a
# DIFFERENT file from verdicts.jsonl, so #46's wipe-detection still fires.
#
# Written to redden on the marker-only tally (a dropped field → tally resets to the in-flight batch),
# green on the sidecar (cumulative across the drop).
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
V="$here/bin/check-role-verdict.sh"
fail=0
_chk() { if [ "$1" = "$2" ]; then printf '  PASS %s\n' "$3"
  else printf '  FAIL %s (got [%s] want [%s])\n' "$3" "$1" "$2" >&2; fail=$((fail + 1)); fi; }

T="$(mktemp -d)"
( cd "$T" || exit 1; git init -q; git config user.email a@b.c; git config user.name t
  printf 'x\n' > s.txt; git add -A; git commit -q -m b; mkdir -p .runs/r
  printf '{"run":"r","pipeline":"full","intends_code":true,"source":"harness"}\n' > .runs/r/RUN
  printf '{"id":"B1","kind":"code","status":"announced"}\n' > .runs/r/batches.jsonl ) >/dev/null 2>&1

# Drive the SubagentStop capture path (the same one role-verdict.test.sh uses): a well-formed verdict
# is persisted to verdicts.jsonl AND mirrored into the durable tally.
_capture() {  # ROLE VERDICT_JSON
  local tr="$T/tr.jsonl"; printf '%s\n' "$2" > "$tr"
  ( cd "$T" || exit 1
    printf '{"agent_type":"%s","transcript_path":"%s"}' "$1" "$tr" \
      | TEAM_BOOTSTRAP_RUN=r "$V" >/dev/null 2>&1 )
}
SEC='{"role":"security-reviewer","status":"completed","severity_counts":{"critical":0,"high":0,"medium":0,"low":0},"secrets_audit_passed":true}'
INT='{"role":"integration-verifier","status":"completed","integration_verified":true,"orphans_found":false}'

# --- B1: capture a verdict, then DROP the marker's tally field (models the #83 rewrite) --------------
_capture security-reviewer "$SEC"
_chk "$(grep -c '"batch":"B1"' "$T/.runs/r/verdicts.jsonl" 2>/dev/null)" 1 "B1 verdict recorded to verdicts.jsonl"

# The unidentified rewrite: reconstruct the marker WITHOUT verdicts_captured (every other field kept).
python3 - "$T/.runs/r/RUN" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d.pop("verdicts_captured",None)
json.dump(d,open(p,"w"))
PY
_chk "$(python3 -c 'import json;print("present" if "verdicts_captured" in json.load(open("'"$T"'/.runs/r/RUN")) else "dropped")')" dropped \
  "marker rewrite dropped verdicts_captured (the #83 mechanism)"

# --- close B1, announce B2, capture a second verdict ------------------------------------------------
printf '{"id":"B1","kind":"code","status":"closed"}\n{"id":"B2","kind":"code","status":"announced"}\n' > "$T/.runs/r/batches.jsonl"
_capture integration-verifier "$INT"

# ACCEPTANCE #1 — the tally is cumulative across the drop: B1's entry survived even though the marker
# field was wiped between the two captures. The durable store is the sidecar.
SC="$T/.runs/r/verdicts-captured.jsonl"
_chk "$([ -f "$SC" ] && echo yes || echo no)" yes "durable sidecar verdicts-captured.jsonl exists"
_chk "$(grep -c 'B1/security-reviewer' "$SC" 2>/dev/null)" 1 "sidecar retains B1's entry across the marker rewrite"
_chk "$(grep -c 'B2/integration-verifier' "$SC" 2>/dev/null)" 1 "sidecar holds B2's entry too (cumulative)"

# --- ACCEPTANCE #2 / #46 preserved: wiping verdicts.jsonl (NOT the sidecar) still trips the breach ---
# Re-announce B1 as the in-flight batch so the gate checks a batch the sidecar tallied.
printf '{"id":"B1","kind":"code","status":"announced"}\n' > "$T/.runs/r/batches.jsonl"
: > "$T/.runs/r/verdicts.jsonl"   # evidence wiped after capture (the #46 scenario)
# dispatch.jsonl empty ⇒ diag would be "skipped"; but the DURABILITY BREACH line is emitted whenever
# tallied>0 regardless of diag, and that is what #46 guarantees and #83 must not lose.
BREACH="$( ( cd "$T" || exit 1; TEAM_BOOTSTRAP_RUN=r "$V" --gate . ) 2>&1 )"
_chk "$(printf '%s' "$BREACH" | grep -qi 'DURABILITY BREACH' && echo yes || echo no)" yes \
  "#46 preserved: sidecar tally still reports the breach after verdicts.jsonl is wiped"

rm -rf "$T"
if [ "$fail" -eq 0 ]; then echo "verdict-tally-durable.test.sh: OK"; exit 0; fi
echo "verdict-tally-durable.test.sh: $fail case(s) FAILED" >&2; exit 1
