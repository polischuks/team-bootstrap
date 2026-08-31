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
#   marker.sh set pipeline <full|mvp|single-thread>
#       Record the batch pipeline mode the review gates read (check-review-ack dispatch corroboration).
#       GUARDED: refuses `auto` or any string outside the vocabulary — an unguarded pipeline write is a
#       provenance-forgery surface (issue #98).
#
#   marker.sh review-ack --batch <id> --reviewer <who> --context <clean|dirty> --verdict <go|blocked> --commit <sha>
#       Append a validated review_acks entry — the independent, clean-context adversarial review
#       check-review-ack reads. `reviewer` must differ from the marker `builder` (default "orchestrator";
#       no self-review, OQ-4). Refuses a missing/malformed field, naming it (issue #98).
#
#   marker.sh seam-ack --seam <name> --commit <sha> --note "<file:line + why>"
#       Append a validated seam_acks entry — the read-in-the-shipped-code ack check-seam-ack reads. The
#       emitted shape is seam THEN commit (adjacency is load-bearing for the gate's parse). Refuses a
#       missing/malformed field, naming it (issue #98).
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
  sed -n '2,48p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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
    pipeline)     # KEY is the expected value
      [ "$(field_str "$mk" pipeline)" = "$key" ] \
        || { echo "$prog: BUG — pipeline not readable as '$key' after write." >&2; return 1; } ;;
    list)         # KEY is the appended-to array's top-level name (review_acks / seam_acks)
      case "$mk" in *"\"$key\":["*) : ;; *) echo "$prog: BUG — $key array not present after write." >&2; return 1 ;; esac ;;
  esac
  return 0
}

# _has_bad_punct VALUE → rc 0 if VALUE carries JSON/parse-hostile punctuation ( [ ] { } " \ ). These land
# inside JSON string values this file has no encoder for, and the jq-free array parsers (marker_list /
# _array_objects / _ack_commits) key on the FIRST ']' — a ']' in a value would truncate the array. So the
# writers REJECT rather than mangle (mirrors record_governed_waiver's `case … *[\\\"]*`), the safe direction.
_has_bad_punct() { printf '%s' "$1" | grep -q '[][{}"\]'; }

# _append_marker_obj KEY OBJ → append flat JSON object OBJ to the active run marker's top-level array
# "KEY" (creating it when absent), atomically. Reuses delivery-lib's marker_list (read) + record_marker_list
# (write, which strips+re-appends the key and re-validates the {…} wrapper), so the array shape stays owned
# by the lib. Callers MUST confirm an active run first — record_marker_list is a silent no-op with none.
_append_marker_obj() {
  local key="$1" obj="$2" cur body newarr
  cur="$(marker_list "$key")"
  if [ -z "$cur" ] || [ "$cur" = "[]" ]; then
    newarr="[$obj]"
  else
    body="${cur#\[}"; body="${body%\]}"
    newarr="[$body,$obj]"
  fi
  record_marker_list "$key" "$newarr"
}

# _set_pipeline VALUE → set the top-level "pipeline":"VALUE" scalar in the active run marker (insert or
# replace), validate the candidate parses, write atomically. rc 1 on no/ambiguous run or a non-parsing
# candidate. The vocabulary guard lives in the caller (set pipeline) so the refusal message can be specific.
_set_pipeline() {
  local val="$1" marker mk newmk
  marker="$(resolve_marker)"
  [ -n "$marker" ] && [ -f "$marker" ] || return 1
  mk="$(cat "$marker" 2>/dev/null || true)"
  [ -n "$mk" ] || return 1
  case "$mk" in \{*\}) : ;; *) return 1 ;; esac
  newmk="$(_json_scalar_set "$mk" pipeline "\"$val\"")" || return 1
  _marker_json_ok "$newmk" || return 1
  _marker_write "$marker" "$newmk"
}

cmd="${1:-}"; [ "$#" -gt 0 ] && shift

case "$cmd" in
  set)
    key="${1:-}"; val="${2:-}"
    if [ "$#" -ne 2 ]; then echo "usage: $prog set <precond.ack <true|false> | pipeline <full|mvp|single-thread>>" >&2; exit 64; fi
    case "$key" in
      precond.ack)
        case "$val" in true|false) : ;; *) echo "$prog: precond.ack takes true or false, not '$val'." >&2; exit 64 ;; esac
        record_precond_ack "$val" || { echo "$prog: REFUSED to set precond.ack — no unambiguous active run, or no precond advisory recorded in the marker to acknowledge." >&2; exit 1; }
        _revalidate precond-ack precond || exit 1
        echo "$prog: precond.ack=$val recorded and validated." ;;
      pipeline)
        case "$val" in full|mvp|single-thread) : ;; *) echo "$prog: pipeline takes full|mvp|single-thread, not '$val' (auto/arbitrary refused — an unguarded pipeline is a forgery surface, #98)." >&2; exit 64 ;; esac
        _set_pipeline "$val" || { echo "$prog: REFUSED to set pipeline — no unambiguous active run, or the write did not validate." >&2; exit 1; }
        _revalidate pipeline "$val" || exit 1
        echo "$prog: pipeline=$val recorded and validated." ;;
      *) echo "$prog: unknown field '$key' (settable: precond.ack, pipeline; waivers use '$prog waive …')." >&2; exit 64 ;;
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
  review-ack)
    # Append a validated review_acks entry check-review-ack reads. Flag-parsed so a missing field is named.
    batch=""; reviewer=""; context=""; verdict=""; commit=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --batch)    batch="${2:-}" ;;
        --reviewer) reviewer="${2:-}" ;;
        --context)  context="${2:-}" ;;
        --verdict)  verdict="${2:-}" ;;
        --commit)   commit="${2:-}" ;;
        *) echo "$prog: review-ack: unknown option '$1' (need --batch --reviewer --context --verdict --commit)." >&2; exit 64 ;;
      esac
      shift; [ "$#" -gt 0 ] && shift    # consume the flag, then its value if present (no shift-2 underflow loop)
    done
    missing=""
    [ -n "$batch" ]    || missing="$missing batch"
    [ -n "$reviewer" ] || missing="$missing reviewer"
    [ -n "$context" ]  || missing="$missing context"
    [ -n "$verdict" ]  || missing="$missing verdict"
    [ -n "$commit" ]   || missing="$missing commit"
    [ -z "$missing" ] || { echo "$prog: review-ack: missing required field(s):$missing (need --batch --reviewer --context --verdict --commit)." >&2; exit 64; }
    case "$context" in clean|dirty) : ;; *) echo "$prog: review-ack: --context must be clean|dirty, not '$context'." >&2; exit 64 ;; esac
    case "$verdict" in go|blocked) : ;; *) echo "$prog: review-ack: --verdict must be go|blocked, not '$verdict'." >&2; exit 64 ;; esac
    for _v in "$batch" "$reviewer" "$context" "$verdict" "$commit"; do
      _has_bad_punct "$_v" && { echo "$prog: review-ack: value '$_v' carries JSON/parse-hostile punctuation ( [ ] { } \" \\ ) — refused (keep ids/slugs/shas clean)." >&2; exit 64; }
    done
    marker="$(resolve_marker 2>/dev/null || true)"
    [ -n "$marker" ] && [ -f "$marker" ] || { echo "$prog: review-ack: no unambiguous active run to record into." >&2; exit 1; }
    mk="$(cat "$marker" 2>/dev/null || true)"
    builder="$(field_str "$mk" builder)"; [ -n "$builder" ] || builder="orchestrator"
    [ "$reviewer" = "$builder" ] && { echo "$prog: review-ack: reviewer '$reviewer' == builder '$builder' — a self-review cannot close a batch (OQ-4); refused." >&2; exit 1; }
    # Shape check-review-ack reads: flat {batch, reviewer, context, commit, verdict}.
    _append_marker_obj review_acks "{\"batch\":\"$batch\",\"reviewer\":\"$reviewer\",\"context\":\"$context\",\"commit\":\"$commit\",\"verdict\":\"$verdict\"}" \
      || { echo "$prog: review-ack: REFUSED — the marker write did not validate; left unchanged." >&2; exit 1; }
    _revalidate list review_acks || exit 1
    echo "$prog: review-ack recorded (batch=$batch, reviewer=$reviewer, verdict=$verdict) and validated." ;;
  seam-ack)
    # Append a validated seam_acks entry check-seam-ack reads. seam THEN commit is load-bearing.
    seam=""; commit=""; note=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --seam)   seam="${2:-}" ;;
        --commit) commit="${2:-}" ;;
        --note)   note="${2:-}" ;;
        *) echo "$prog: seam-ack: unknown option '$1' (need --seam --commit --note)." >&2; exit 64 ;;
      esac
      shift; [ "$#" -gt 0 ] && shift
    done
    missing=""
    [ -n "$seam" ]   || missing="$missing seam"
    [ -n "$commit" ] || missing="$missing commit"
    [ -n "$note" ]   || missing="$missing note"
    [ -z "$missing" ] || { echo "$prog: seam-ack: missing required field(s):$missing (need --seam --commit --note)." >&2; exit 64; }
    for _v in "$seam" "$commit" "$note"; do
      _has_bad_punct "$_v" && { echo "$prog: seam-ack: value '$_v' carries JSON/parse-hostile punctuation ( [ ] { } \" \\ ) — refused (keep the note bracket/brace-free)." >&2; exit 64; }
    done
    marker="$(resolve_marker 2>/dev/null || true)"
    [ -n "$marker" ] && [ -f "$marker" ] || { echo "$prog: seam-ack: no unambiguous active run to record into." >&2; exit 1; }
    _append_marker_obj seam_acks "{\"seam\":\"$seam\",\"commit\":\"$commit\",\"note\":\"$note\"}" \
      || { echo "$prog: seam-ack: REFUSED — the marker write did not validate; left unchanged." >&2; exit 1; }
    _revalidate list seam_acks || exit 1
    echo "$prog: seam-ack recorded (seam=$seam, commit=$commit) and validated." ;;
  ""|-h|--help|help) usage; [ "$cmd" = "" ] && exit 64 || exit 0 ;;
  *) echo "$prog: unknown command '$cmd' (set|waive|review-ack|seam-ack)." >&2; exit 64 ;;
esac
