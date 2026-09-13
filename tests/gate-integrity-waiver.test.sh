#!/usr/bin/env bash
# gate-integrity-waiver.test.sh — #59 governed waiver. A CI `continue-on-error: true` that carries an
# inline `# gate-integrity-waiver: <reason>` annotation is a DEFERRED, TRACKED, auditable exception —
# check-gate-integrity reports it as INFO (not a blocking violation), mirroring the preflight/enforcement
# governed-waiver pattern. A continue-on-error WITHOUT a waiver (or with an EMPTY reason) is still flagged.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
G="$here/bin/check-gate-integrity.sh"
fail=0
_c(){ if [ "$1" = "$2" ]; then printf '  PASS %s\n' "$3"; else printf '  FAIL %s (got [%s] want [%s])\n' "$3" "$1" "$2" >&2; fail=$((fail+1)); fi; }
# Capture output first (the gate exits non-zero on a violation; a piped grep under pipefail would
# propagate that exit and corrupt the check — capture-then-grep, the pipefail-class lesson).
_out(){ ( cd "$1" && bash "$G" --audit . 2>&1 ); }
# _flagged ROOT → "yes" if the continue-on-error violation line is emitted, else "no"
_flagged(){ printf '%s' "$(_out "$1")" | grep -q 'gate cannot fail (continue-on-error)' && echo yes || echo no; }
# _waived ROOT → "yes" if a waived continue-on-error is reported as INFO/tracked
_waived(){ printf '%s' "$(_out "$1")" | grep -qiE 'continue-on-error.*(waiv|tracked|deferred)' && echo yes || echo no; }

_mk(){ local T; T="$(mktemp -d)"; mkdir -p "$T/.github/workflows"; printf '%s' "$T"; }

# no waiver → flagged
T="$(_mk)"; printf 'jobs:\n  a:\n    continue-on-error: true\n' > "$T/.github/workflows/ci.yml"
_c "$(_flagged "$T")" yes "un-waived continue-on-error is flagged"; rm -rf "$T"

# waiver with a reason → NOT flagged (tracked/informational)
T="$(_mk)"; printf 'jobs:\n  a:\n    continue-on-error: true  # gate-integrity-waiver: #59 — suite not yet portable on CI runners\n' > "$T/.github/workflows/ci.yml"
_c "$(_flagged "$T")" no "waived continue-on-error is NOT flagged as a violation"; rm -rf "$T"

T="$(_mk)"; printf 'jobs:\n  a:\n    continue-on-error: true  # gate-integrity-waiver: #59 — suite not yet portable on CI runners\n' > "$T/.github/workflows/ci.yml"
_c "$(_waived "$T")" yes "waived continue-on-error is reported as tracked/INFO"; rm -rf "$T"

# waiver marker with EMPTY reason → still flagged (a bare bypass is not a governed waiver)
T="$(_mk)"; printf 'jobs:\n  a:\n    continue-on-error: true  # gate-integrity-waiver:\n' > "$T/.github/workflows/ci.yml"
_c "$(_flagged "$T")" yes "empty-reason waiver is rejected (still flagged)"; rm -rf "$T"

if [ "$fail" -eq 0 ]; then echo "gate-integrity-waiver.test.sh: OK"; exit 0; fi
echo "gate-integrity-waiver.test.sh: $fail case(s) FAILED" >&2; exit 1
