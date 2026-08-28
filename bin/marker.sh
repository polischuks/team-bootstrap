#!/usr/bin/env bash
# marker.sh — the single sanctioned CLI for editing the machine-owned .runs/<run>/RUN marker (issue #72).
#
# Recording an ack or a waiver used to mean hand-editing the run marker's JSON by hand, against a shape
# contract nothing stated: a trailing comma, a wrong field name, or a non-date `expires` produced a
# marker that fails silently or clears nothing at the gate. This command is the ONE owner of that
# contract. It writes the correct shape through delivery-lib's atomic marker writers, refuses any input
# the reading gate would reject, and then RE-VALIDATES the marker it wrote — the operator never edits the
# machine JSON, and a malformed edit is impossible to record.
#
# Every sub-edit targets the SINGLE active run (resolved from TEAM_BOOTSTRAP_RUN / the lone .runs/*/RUN),
# and must be run from the project root (the marker path is `.runs/<run>/RUN`, resolved relative to CWD).
#
# Commands:
#   marker.sh set precond.ack <true|false>
#       Acknowledge (or un-acknowledge) the Phase-A deliverability advisory (precond.exit==2), so
#       check-delivery lets Phase B proceed. Needs an existing precond verdict in the marker.
#
#   marker.sh waive preflight       <by> <reason> <expires>
#       Governed Phase-0 setup-readiness waiver — clears a failing check-preflight (preflight.exit!=0).
#   marker.sh waive gate-integrity  <by> <reason> <expires>
#       Governed gate-integrity waiver — clears pre-existing green-by-skip / can't-fail findings.
#   marker.sh waive role-verdict    <by> <reason> <expires>
#       Governed role-verdict waiver — clears a batch whose reviewer verdict could not be captured.
#   marker.sh waive enforcement     <by> <reason> <expires> <host_structural|deferred>
#       Governed test-quality enforcement waiver — clears a red-first/coverage/mutation gap.
#
#   <expires> is YYYY-MM-DD and must be in the future (a bare, undated ack is not a governed waiver).
#   The finding a waiver clears is still PRINTED by its gate — a waiver dates and attributes the escape,
#   it does not hide it. Standard for a good <reason>: references/enforcement.md.
#
# Exit: 0 recorded (and re-validated) · 1 refused by the writer (bad/expired waiver, no active run,
#       nothing to ack) · 64 usage error (unknown command/target, wrong arity, non-bool value).
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/delivery-lib.sh
. "$here/delivery-lib.sh"

prog="$(basename "$0")"

usage() {
  sed -n '2,44p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# _revalidate KIND KEY → confirm the just-written marker still parses AND the field the gate reads is
# present in the accepted shape. This is belt-and-suspenders over the writers' own pre-write validation:
# the CLI is the contract owner, so it proves the contract held rather than trusting it. A failure here
# is a writer bug, reported loudly (never a silent success).
_revalidate() {
  local kind="$1" key="$2" marker mk
  marker="$(resolve_marker 2>/dev/null || true)"
  [ -n "$marker" ] && [ -f "$marker" ] || { echo "$prog: recorded, but the run marker could not be re-read to validate." >&2; return 1; }
  mk="$(cat "$marker" 2>/dev/null || true)"
  _marker_json_ok "$mk" || { echo "$prog: BUG — the write produced a marker that does not parse; refusing to claim success." >&2; return 1; }
  case "$kind" in
    precond-ack)
      [ -n "$(field_in_obj "$mk" precond ack)" ] || { echo "$prog: BUG — precond.ack not readable after write." >&2; return 1; } ;;
    obj-waiver)   # governed waiver nested in "$key":{ack,by,reason,expires}
      governed_waiver_ok "$(field_in_obj "$mk" "$key" ack)" "$(field_in_obj "$mk" "$key" by)" \
                         "$(field_in_obj "$mk" "$key" reason)" "$(field_in_obj "$mk" "$key" expires)" \
        || { echo "$prog: BUG — $key does not read back as a valid governed waiver." >&2; return 1; } ;;
    enforcement)
      [ "$(field_bool "$mk" enforcement_ack)" = "true" ] \
        || { echo "$prog: BUG — enforcement_ack not readable after write." >&2; return 1; } ;;
  esac
  return 0
}

cmd="${1:-}"; [ "$#" -gt 0 ] && shift

case "$cmd" in
  set)
    key="${1:-}"; val="${2:-}"
    if [ "$#" -ne 2 ]; then echo "usage: $prog set precond.ack <true|false>" >&2; exit 64; fi
    case "$key" in
      precond.ack)
        case "$val" in true|false) : ;; *) echo "$prog: precond.ack takes true or false, not '$val'." >&2; exit 64 ;; esac
        record_precond_ack "$val" || { echo "$prog: REFUSED to set precond.ack — no unambiguous active run, or no precond advisory recorded in the marker to acknowledge." >&2; exit 1; }
        _revalidate precond-ack precond || exit 1
        echo "$prog: precond.ack=$val recorded and validated." ;;
      *) echo "$prog: unknown field '$key' (only precond.ack is settable; waivers use '$prog waive …')." >&2; exit 64 ;;
    esac
    ;;
  waive)
    target="${1:-}"; [ "$#" -gt 0 ] && shift
    case "$target" in
      preflight|gate-integrity|role-verdict)
        if [ "$#" -ne 3 ]; then echo "usage: $prog waive $target <by> <reason> <expires:YYYY-MM-DD>" >&2; exit 64; fi
        by="$1"; reason="$2"; expires="$3"
        case "$target" in
          preflight)      record_preflight_waiver "$by" "$reason" "$expires" && _revalidate obj-waiver preflight ;;
          gate-integrity) record_governed_waiver gate_integrity_waiver "$by" "$reason" "$expires" && _revalidate obj-waiver gate_integrity_waiver ;;
          role-verdict)   record_governed_waiver role_verdict_waiver "$by" "$reason" "$expires" && _revalidate obj-waiver role_verdict_waiver ;;
        esac || { echo "$prog: REFUSED to record the $target waiver — needs a non-empty by and reason, a future YYYY-MM-DD expires, and an unambiguous active run." >&2; exit 1; }
        echo "$prog: $target waiver recorded and validated (by=$by, expires=$expires)." ;;
      enforcement)
        if [ "$#" -ne 4 ]; then echo "usage: $prog waive enforcement <by> <reason> <expires:YYYY-MM-DD> <host_structural|deferred>" >&2; exit 64; fi
        by="$1"; reason="$2"; expires="$3"; category="$4"
        record_enforcement_waiver "$by" "$reason" "$expires" "$category" || { echo "$prog: REFUSED to record the enforcement waiver — needs a non-empty by and reason, a future YYYY-MM-DD expires, a category of host_structural|deferred, and an unambiguous active run." >&2; exit 1; }
        _revalidate enforcement enforcement_ack || exit 1
        echo "$prog: enforcement waiver recorded and validated (by=$by, expires=$expires, category=$category)." ;;
      ""|-h|--help) usage; exit 64 ;;
      *) echo "$prog: unknown waive target '$target' (preflight|gate-integrity|role-verdict|enforcement)." >&2; exit 64 ;;
    esac
    ;;
  ""|-h|--help|help) usage; [ "$cmd" = "" ] && exit 64 || exit 0 ;;
  *) echo "$prog: unknown command '$cmd' (set|waive)." >&2; exit 64 ;;
esac
