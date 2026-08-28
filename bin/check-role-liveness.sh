#!/usr/bin/env bash
# check-role-liveness.sh — P12 as a gate: a role is alive only if an eval reddens when it is removed.
#
# WHY THIS EXISTS AND IS NOT JUST A CALL TO `eval-role.sh --liveness`.
#
# The liveness eval is a mutation test: for each routed role it deletes the mapping, re-sizes, and
# requires the role to disappear. That is the right measurement. But a mutation test is itself code,
# and code that always passes is indistinguishable from code that always passes for the right reason —
# `check-gate-integrity.sh` was written because that distinction stops being visible the moment nobody
# checks it. This gate closes the loop by mutating the MUTATION TEST:
#
#   1. the eval passes on the shipped profile;
#   2. the eval FAILS on a profile carrying a binding that cannot be load-bearing — if it does not, the
#      eval is a rubber stamp and every "N/N alive" it has ever printed means nothing;
#   3. the count the constitution declares matches the count the eval measures.
#
# (3) is the enumeration invariant made enforceable. constitution.md carries "Live role bindings | N |"
# and an invariant nothing checks is a comment. A role added without a routing signal, or a category
# quietly dropped, changes the real number while the declared one keeps saying what used to be true.
#
# Usage: bin/check-role-liveness.sh [project-dir]  ·  bin/check-role-liveness.sh --self-test
# Exit:  0 every binding alive (or the repo carries no role registry — not applicable, stated) ·
#        1 a binding is not load-bearing, the eval cannot fail, or the declared count is untrue ·
#        64 bad usage
set -uo pipefail

# _measured ROOT [PROFILE] → "alive/total" as the eval reports it (empty if it could not run).
_measured() {
  local root="$1" prof="${2:-}"
  ( [ -n "$prof" ] && export TEAM_BOOTSTRAP_PROFILE="$prof"
    "$root/bin/eval-role.sh" --liveness 2>&1 ) \
    | sed -n 's/.*: \([0-9]*\)\/\([0-9]*\) assignable.*/\1\/\2/p' | tail -1
}

# _eval_ok ROOT [PROFILE] → 0 when the eval exits clean.
_eval_ok() {
  local root="$1" prof="${2:-}"
  ( [ -n "$prof" ] && export TEAM_BOOTSTRAP_PROFILE="$prof"
    "$root/bin/eval-role.sh" --liveness >/dev/null 2>&1 )
}

# _declared ROOT → the live-binding count constitution.md claims (empty when the row is absent).
_declared() {
  sed -n 's/^| Live role bindings .* | \([0-9][0-9]*\) |.*/\1/p' "$1/constitution.md" 2>/dev/null | head -1
}

# _dead_profile ROOT → a temp profile whose LAST line adds a binding that cannot possibly be
# load-bearing: a category the classifier never emits. A role mapped there is required neither with the
# mapping nor without it, so a working eval must call it DEAD.
_dead_profile() {
  local root="$1" t; t="$(mktemp)"
  cat "${TEAM_BOOTSTRAP_PROFILE:-$root/profiles/default.map}" > "$t" 2>/dev/null
  printf 'never-emitted-category\tsecurity-reviewer\n' >> "$t"
  printf '%s' "$t"
}

_run() {
  local root="$1" n=0 m d dp
  if ! _eval_ok "$root"; then
    echo "  the liveness eval does not pass on the shipped profile — a binding is not load-bearing" >&2
    "$root/bin/eval-role.sh" --liveness 2>&1 | sed -n 's/^  DEAD/  DEAD/p' >&2
    n=$((n + 1))
  fi

  dp="$(_dead_profile "$root")"
  if _eval_ok "$root" "$dp"; then
    echo "  the liveness eval PASSES on a profile with a provably dead binding — it is a rubber stamp," >&2
    echo "  and every 'N/N alive' it has printed is unverified (this is check-gate-integrity's rule," >&2
    echo "  applied to the eval itself)." >&2
    n=$((n + 1))
  fi
  rm -f "$dp"

  m="$(_measured "$root")"; d="$(_declared "$root")"
  if [ -z "$m" ]; then
    echo "  the liveness eval produced no count — it could not run, which is not the same as passing" >&2
    n=$((n + 1))
  elif [ -n "$d" ] && [ "${m%%/*}" != "$d" ]; then
    echo "  constitution.md declares $d live role binding(s); the eval measures ${m%%/*}." >&2
    echo "  An enumeration invariant nothing checks is a comment (P12, P11)." >&2
    n=$((n + 1))
  fi
  printf '%s' "$n"
}

# --- self-test ---------------------------------------------------------------
if [ "${1:-}" = "--self-test" ]; then
  fail=0
  _c() { if [ "$1" = "$2" ]; then printf '  PASS %s\n' "$3"
    else printf '  FAIL %s (got [%s] want [%s])\n' "$3" "$1" "$2" >&2; fail=$((fail + 1)); fi; }
  here="$(cd "$(dirname "$0")/.." && pwd)"

  _c "$(_run "$here")" 0 "the shipped tree passes all three checks"

  # The declared-count check must actually be able to fail — otherwise this gate has the very defect
  # it was written to detect in the eval.
  T="$(mktemp -d)"; mkdir -p "$T/bin"
  cp "$here/bin/eval-role.sh" "$T/bin/"
  printf '| Live role bindings (`bin/eval-role.sh --liveness`) | 999 | x |\n' > "$T/constitution.md"
  ln -s "$here/profiles" "$T/profiles" 2>/dev/null || cp -R "$here/profiles" "$T/profiles"
  ln -s "$here/references" "$T/references" 2>/dev/null || cp -R "$here/references" "$T/references"
  ln -s "$here/agents" "$T/agents" 2>/dev/null || cp -R "$here/agents" "$T/agents"
  for b in delivery-lib.sh select-pipeline.sh; do cp "$here/bin/$b" "$T/bin/"; done
  _c "$([ "$(_run "$T")" -ge 1 ] && echo caught || echo missed)" caught \
    "a declared count that disagrees with the measured one is caught"
  rm -rf "$T"

  _c "$([ -n "$(_declared "$here")" ] && echo yes || echo no)" yes \
    "constitution.md actually carries the live-binding row this gate reads"

  if [ "$fail" -eq 0 ]; then echo "check-role-liveness --self-test: OK"; exit 0; fi
  echo "check-role-liveness --self-test: $fail case(s) FAILED" >&2; exit 1
fi

# --- main --------------------------------------------------------------------
case "${1:-}" in -*) echo "usage: check-role-liveness.sh [project-dir] | --self-test" >&2; exit 64 ;; esac
root="${1:-.}"
# NOT APPLICABLE ⇒ SKIP, NEVER BLOCK (issue #45). This gate governs team-bootstrap's OWN role
# registry, and it is wired into verify-batch.sh, which runs in every TARGET repository. An
# application repository has no role registry and should not acquire one to satisfy a gate — that
# would be fitting the repo to the tool.
#
# Without this branch the gate exited 64 in every foreign repo and blocked every batch of every
# delivery, with no waiver path. Reported from a real delivery where 18 of 19 gates were green and
# five independent reviews had run, one of which found and fixed a real bug: the batch still could not
# close, and would not have closed on any later batch either.
#
# The distinction this draws is the one check-version-sync already draws: "cannot check because there
# is nothing here to check" is not "cannot check because something is wrong", and only the second is
# a reason to refuse. The skip is STATED, never silent, so it cannot be mistaken for a pass — and it
# is narrow: a repo that HAS the subject and fails the claim still blocks.
if [ ! -x "$root/bin/eval-role.sh" ]; then
  echo "check-role-liveness: NOT APPLICABLE — '$root' has no bin/eval-role.sh, so it carries no team-bootstrap role registry to measure. This gate governs the plugin's own roles (P12); an application repository has none by design. Skipping."
  exit 0
fi

n="$(_run "$root")"
if [ "${n:-0}" -eq 0 ]; then
  echo "check-role-liveness: OK — $(_measured "$root") binding(s) alive, the eval can fail, and the declared count is true."
  exit 0
fi
echo "check-role-liveness: FAIL — $n problem(s) with the liveness claim (P12)." >&2
exit 1
