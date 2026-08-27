#!/usr/bin/env bash
# tests/pipefail-class.test.sh — the SIGPIPE-under-pipefail class (spec 021 D5, B6).
#
# In a file that declares `pipefail`, a pipeline whose LAST stage exits early (`head`, `grep -q`,
# `grep -m`, `sed -n …q`) makes its producer receive SIGPIPE once the consumer is satisfied. If that
# producer is STREAMING — it keeps writing after the consumer leaves — the pipeline status becomes 141,
# and every reader of that status reads a failure that never happened.
#
# Two directions, both real:
#   - fail-CLOSED: a status-consuming pipeline reports 141 → a gate refuses correct code (the spec's
#     "ложный провал").
#   - fail-OPEN: `producer | grep -q X` returns non-zero under pipefail EVEN WHEN grep matched, so the
#     caller reads "not found" for something present (plan §8.4's severity correction). Nondeterministic
#     on buffering, which is worse than a reliable bug — it passes in the small and fails at scale.
#
# AC-11 — no pipeline in a pipefail gate can end 141 from an early consumer exit.
# AC-12 — a source meta-check reddens when a NEW such pipeline appears; a printf-fed grep -q does not.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
_chk() { if [ "$1" = "$2" ]; then echo "  PASS $3"; else echo "  FAIL $3 (got '$1' want '$2')" >&2; fail=$((fail + 1)); fi; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# --- AC-11: the mechanism, and that the neutralised form is immune ----------------------------------
# A streaming producer (200k lines) feeding an early-exit consumer. The RAW form can rc-141; the
# neutralised form (|| true) never does. This is the property every hazard site must have.
_raw_rc="$(bash -c 'set -uo pipefail; seq 1 200000 | head -1 >/dev/null; echo $?')"
_chk "$([ "$_raw_rc" = "141" ] && echo hazard || echo safe)" hazard \
  "AC-11 precondition: a raw streaming|early-exit pipeline really does rc-141 (else this test proves nothing)"
_neu_rc="$(bash -c 'set -uo pipefail; { seq 1 200000 | head -1 >/dev/null; } || true; echo $?')"
_chk "$_neu_rc" 0 \
  "AC-11 the neutralised form (|| true) never surfaces 141"
_neu_rc2="$(bash -c 'set -uo pipefail; seq 1 200000 | { head -1 >/dev/null; }; echo $?' 2>/dev/null)"

# The fail-OPEN subclass, made deterministic by reading the value rather than racing it: under pipefail
# `producer | grep -q X` can return non-zero though X matched. The safe idiom captures the match into a
# variable first, so the decision is made on the value, not on a status the SIGPIPE corrupts.
_open_safe="$(bash -c '
  set -uo pipefail
  # capture, then test — the status of the capture is discarded (assignment), the value is what decides.
  hit="$(seq 1 500000 | grep -m1 "^3$" || true)"
  [ -n "$hit" ] && echo present || echo absent')"
_chk "$_open_safe" present \
  "AC-11 the fail-open idiom (capture the value, decide on the value) finds a match that is present"

# --- AC-12: the source meta-check --------------------------------------------------------------------
# check-gate-integrity gains a clause that flags a streaming-producer | early-exit-consumer pipeline in
# a pipefail file, unless it is neutralised or carries a `pipefail-safe:` sanction. Fixtures are whole
# tiny gates in a scratch tree so a finding can come from nowhere else.
_pf_fixture() { rm -rf "$T/pf"; mkdir -p "$T/pf/bin"; printf '#!/usr/bin/env bash\nset -uo pipefail\n%b\n' "$2" > "$T/pf/bin/$1"; }
_pf() { ( "$here/bin/check-gate-integrity.sh" "$T/pf" ) >/dev/null 2>&1; echo $?; }
_pf_err() { ( "$here/bin/check-gate-integrity.sh" "$T/pf" ) 2>&1 >/dev/null; }

# (a) the hazard — a git-log stream into head, status not neutralised.
_pf_fixture check-a.sh 'n="$(git log --format=%h HEAD 2>/dev/null | head -5)"\necho "$n"'
_chk "$([ "$(_pf)" -ne 0 ] && echo flagged || echo missed)" flagged \
  "AC-12 a streaming producer (git log) piped into head in a pipefail gate is a finding"
case "$(_pf_err)" in *check-a.sh*) echo "  PASS AC-12 the finding names the file" ;; *) echo "  FAIL AC-12 the finding does not name the file" >&2; fail=$((fail+1)) ;; esac

# (b) neutralised with || true — NOT a finding.
_pf_fixture check-b.sh 'n="$(git log --format=%h HEAD 2>/dev/null | head -5 || true)"\necho "$n"'
_chk "$(_pf)" 0 "AC-12 the same pipeline neutralised with || true is not a finding"

# (c) sanctioned with pipefail-safe: — NOT a finding (the convention gate-integrity already uses).
_pf_fixture check-c.sh 'n="$(git log --format=%h HEAD 2>/dev/null | head -5)"   # pipefail-safe: head of a bounded list, status unused'
_chk "$(_pf)" 0 "AC-12 an inline pipefail-safe: sanction is honoured"

# (d) a printf/echo-fed grep -q is NOT flagged — a short in-memory string cannot SIGPIPE, and its
#     status IS the decision (the check-role-verdict:90 shape a || true would break).
_pf_fixture check-d.sh 'printf "%s" "$obj" | grep -qE "\"field\":" || missing=1\necho "$missing"'
_chk "$(_pf)" 0 "AC-12 a printf-fed grep -q is not a finding — it cannot SIGPIPE and its status is load-bearing"

# (e) grep -r (streaming, recursive) into grep -q — a finding.
_pf_fixture check-e.sh 'if grep -rl "TODO" . | grep -q x; then :; fi'
_chk "$([ "$(_pf)" -ne 0 ] && echo flagged || echo missed)" flagged \
  "AC-12 a recursive grep stream into grep -q is a finding"

# (f) THE WHOLE TREE — every pipefail gate in this repo is at the rule. A green here is the standing
#     assertion that T042 left no hazard site behind.
_chk "$( ( "$here/bin/check-gate-integrity.sh" "$here" ) >/dev/null 2>&1; echo $?)" 0 \
  "AC-11 every pipefail gate in this tree is neutralised or sanctioned — no hazard site remains"

[ "$fail" -eq 0 ] && { echo "pipefail-class.test.sh: OK"; exit 0; }
echo "pipefail-class.test.sh: $fail failure(s)" >&2; exit 1
